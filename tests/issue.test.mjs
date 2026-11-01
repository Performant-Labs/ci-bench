// Renderers and the GitHub-facing logic with an in-memory fake client. No network, no gh.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { boise, renderBody, renderComment, parseBody, updateBody, summaryTable } from "../lib/render.mjs";
import { createHostIssue, appendRun, splitRepo, HOST_LABEL } from "../lib/issue.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const load = (f) => JSON.parse(readFileSync(join(root, "examples", f), "utf8"));
const ok = load("result-ok.json");
const failed = load("result-failed-probe.json");
const hostDoc = (runs) => ({ schema_version: "1", role: "host-issue", host: ok.host, runs });
const fenceOf = (text) => JSON.parse(text.match(/```json\n([\s\S]*?)\n```/)[1]);
const rows = (md) => md.split("\n").filter((l) => /^\| \d+ \|/.test(l));

function fakeGitHub() {
  const state = { issues: new Map(), comments: [], nextNumber: 1, hooks: {} };
  const octokit = { rest: { issues: {
    async create(p) { const n = state.nextNumber++; state.issues.set(n, { body: p.body, labels: p.labels, title: p.title, state: "open" }); return { data: { number: n, html_url: `https://example.test/${n}` } }; },
    async get(p) { return { data: { body: state.issues.get(p.issue_number).body } }; },
    async update(p) { state.issues.get(p.issue_number).body = p.body; if (state.hooks.afterUpdate) state.hooks.afterUpdate(state, p); return { data: {} }; },
    async createComment(p) { state.comments.push(p); return { data: {} }; },
  } } };
  return { state, octokit };
}
const target = { owner: "o", repo: "r" };

test("boise labels MST in winter and MDT in summer", () => {
  assert.equal(boise("2026-11-01T20:00:00Z"), "2026-11-01 13:00 MST");
  assert.equal(boise("2026-07-01T20:00:00Z"), "2026-07-01 14:00 MDT");
});

test("body from two run documents, one with failed probes", () => {
  const body = renderBody(hostDoc([ok, failed]), ok.labels);
  const doc = fenceOf(body);
  assert.equal(doc.role, "host-issue");
  assert.equal(doc.schema_version, "1");
  assert.deepEqual(doc.runs, [ok, failed]);
  const r = rows(body);
  assert.equal(r.length, 2);
  assert.match(r[0], /21000 \/ 21000/);
  assert.match(r[0], /MST/);
  assert.match(r[1], /— \| — \| 41\.3 s \| — \| —/);   // failed fio rows and docker cells are dashes
  assert.match(body, /- \*\*Provider:\*\* Contabo/);
  assert.match(body, /- \*\*Disk:\*\* QEMU HARDDISK \(non-rotational\)/);
});

test("an empty host issue has the header and no rows", () => {
  const body = renderBody(hostDoc([]), {});
  assert.equal(rows(body).length, 0);
  assert.match(summaryTable([]), /^\| run \| when \| steal \| sysbench 1-thread events\/sec \| sysbench all-core events\/sec \| fio 4k read\/write IOPS \| fio CI 16k read\/write IOPS \| compile median \| Docker cold median \| Docker cached \|/);
  assert.deepEqual(parseBody(body).runs, []);
});

test("comment has a metrics table, the errors, and the unchanged run JSON", () => {
  const c = renderComment(failed);
  assert.match(c, /\| compile median \| 41\.3 s \|/);
  assert.match(c, /\*\*docker:\*\* sudo docker info exited 1/);
  assert.deepEqual(fenceOf(c), failed);
  assert.match(renderComment(ok), /\*\*Errors:\*\* none/);
});

test("updateBody replaces the table and JSON but keeps the human list", () => {
  const body = renderBody(hostDoc([]), { provider: "Contabo", plan: "Core" });
  const next = updateBody(body, hostDoc([ok]));
  assert.match(next, /- \*\*Provider:\*\* Contabo/);
  assert.equal(rows(next).length, 1);
  assert.equal(parseBody(next).runs.length, 1);
});

test("parseBody refuses a body without the JSON section", () => {
  assert.throws(() => parseBody("hand edited"), /no ci-bench JSON section/);
});

test("createHostIssue labels the issue and starts with no runs", async () => {
  const { state, octokit } = fakeGitHub();
  const out = await createHostIssue(octokit, target, { title: "ci-bench: Contabo Core vmi", host: ok.host, labels: ok.labels });
  assert.deepEqual(out, { number: 1, url: "https://example.test/1" });
  const issue = state.issues.get(1);
  assert.deepEqual(issue.labels, [HOST_LABEL]);
  assert.deepEqual(parseBody(issue.body).runs, []);
  assert.equal(parseBody(issue.body).host.hostname, ok.host.hostname);
});

test("two runs add two comments and two summary rows, keeping the first", async () => {
  const { state, octokit } = fakeGitHub();
  await createHostIssue(octokit, target, { title: "t", host: ok.host, labels: ok.labels });
  await appendRun(octokit, target, 1, ok);
  await appendRun(octokit, target, 1, failed);
  assert.equal(state.comments.length, 2);
  const body = state.issues.get(1).body;
  assert.equal(rows(body).length, 2);
  assert.deepEqual(parseBody(body).runs, [ok, failed]);
  assert.match(rows(body)[0], /21000 \/ 21000/);
  assert.match(rows(body)[1], /—/);
});

test("appending the same run again does not duplicate its row", async () => {
  const { state, octokit } = fakeGitHub();
  await createHostIssue(octokit, target, { title: "t", host: ok.host, labels: ok.labels });
  await appendRun(octokit, target, 1, ok);
  await appendRun(octokit, target, 1, ok);
  assert.equal(parseBody(state.issues.get(1).body).runs.length, 1);
});

test("a concurrent writer that overwrites the body is retried, and no earlier row is lost", async () => {
  const { state, octokit } = fakeGitHub();
  await createHostIssue(octokit, target, { title: "t", host: ok.host, labels: ok.labels });
  await appendRun(octokit, target, 1, ok);
  // Another writer read the body before our PATCH and writes it back after: our run is lost once.
  const stale = state.issues.get(1).body;
  let clobbers = 1;
  state.hooks.afterUpdate = (s) => { if (clobbers-- > 0) s.issues.get(1).body = stale; };
  const res = await appendRun(octokit, target, 1, failed);
  assert.equal(res.attempts, 2);
  assert.deepEqual(parseBody(state.issues.get(1).body).runs.map((r) => r.started_at), [ok.started_at, failed.started_at]);
  assert.equal(rows(state.issues.get(1).body).length, 2);
});

test("it gives up after three attempts when the body keeps changing", async () => {
  const { state, octokit } = fakeGitHub();
  await createHostIssue(octokit, target, { title: "t", host: ok.host, labels: ok.labels });
  const before = state.issues.get(1).body;
  state.hooks.afterUpdate = (s) => { s.issues.get(1).body = before; };
  await assert.rejects(appendRun(octokit, target, 1, ok), /after 3 attempts/);
  assert.equal(state.comments.length, 1);
});

test("a hand-edited body is never overwritten", async () => {
  const { state, octokit } = fakeGitHub();
  await createHostIssue(octokit, target, { title: "t", host: ok.host, labels: ok.labels });
  state.issues.get(1).body = "someone rewrote this";
  await assert.rejects(appendRun(octokit, target, 1, ok), /no ci-bench JSON section/);
  assert.equal(state.issues.get(1).body, "someone rewrote this");
});

test("splitRepo", () => {
  assert.deepEqual(splitRepo("Performant-Labs/ci-bench"), { owner: "Performant-Labs", repo: "ci-bench" });
  assert.throws(() => splitRepo("nope"), /owner\/name/);
});
