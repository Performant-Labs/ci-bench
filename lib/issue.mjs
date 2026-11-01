// GitHub side of the host issue. Octokit is injected so the logic is testable without GitHub.
// CLI (token comes from `gh auth token`; repo from CI_BENCH_REPO, default Performant-Labs/ci-bench):
//   node issue.mjs create --title "<title>"  < {"host": {...}, "labels": {...}}   -> {"number": N, "url": "..."}
//   node issue.mjs append --issue <n>        < run document JSON                  -> posts a comment, updates the body
import { execFileSync } from "node:child_process";
import { renderBody, renderComment, parseBody, updateBody } from "./render.mjs";

export const HOST_LABEL = "benchmark-host";
const sameRun = (a, b) => a.started_at === b.started_at && a.finished_at === b.finished_at;

export function splitRepo(repo) {
  const [owner, name, ...rest] = repo.split("/");
  if (!owner || !name || rest.length) throw new Error(`CI_BENCH_REPO must be owner/name, got '${repo}'`);
  return { owner, repo: name };
}

export async function createHostIssue(octokit, target, { title, host, labels }) {
  const doc = { schema_version: "1", role: "host-issue", host, runs: [] };
  const { data } = await octokit.rest.issues.create({
    ...target, title, labels: [HOST_LABEL], body: renderBody(doc, labels),
  });
  return { number: data.number, url: data.html_url };
}

/**
 * Comment with the run, then add the run to the body's JSON and re-render the table.
 * GitHub has no compare-and-swap on issue bodies, so after each PATCH the body is read back;
 * if the run is not in it (another writer replaced the body), GET-modify-PATCH again, up to `attempts` times.
 */
export async function appendRun(octokit, target, number, run, { attempts = 3 } = {}) {
  const ref = { ...target, issue_number: number };
  await octokit.rest.issues.createComment({ ...ref, body: renderComment(run) });
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const { data } = await octokit.rest.issues.get(ref);
    const body = data.body ?? "";
    const doc = parseBody(body);
    if (!doc.runs.some((r) => sameRun(r, run))) doc.runs.push(run);
    await octokit.rest.issues.update({ ...ref, body: updateBody(body, doc) });
    const check = await octokit.rest.issues.get(ref);
    if (parseBody(check.data.body ?? "").runs.some((r) => sameRun(r, run))) return { attempts: attempt };
  }
  throw new Error(`could not add the run to issue #${number} after ${attempts} attempts (the body kept changing)`);
}

async function readStdinJson() {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function client() {
  const token = execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();
  if (!token) throw new Error("gh auth token returned nothing; run: gh auth login");
  const { Octokit } = await import("@octokit/rest");
  return new Octokit({ auth: token });
}

async function main() {
  const [, , cmd, ...args] = process.argv;
  const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
  const target = splitRepo(process.env.CI_BENCH_REPO || "Performant-Labs/ci-bench");
  if (cmd === "create") {
    const title = flag("--title");
    if (!title) throw new Error("create needs --title");
    const input = await readStdinJson();
    console.log(JSON.stringify(await createHostIssue(await client(), target, { title, host: input.host, labels: input.labels })));
  } else if (cmd === "append") {
    const number = Number(flag("--issue"));
    if (!Number.isInteger(number) || number < 1) throw new Error("append needs --issue <number>");
    await appendRun(await client(), target, number, await readStdinJson());
  } else {
    throw new Error("usage: issue.mjs create --title T | append --issue N");
  }
}
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => { console.error(`issue.mjs: ${e.message}`); process.exit(1); });
}
