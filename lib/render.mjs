// Pure rendering for the host issue and per-run comments. No network, no Octokit.
// CLI (used by tests and by bin/benchmark:*):
//   node render.mjs body     < host-issue JSON   -> issue body
//   node render.mjs comment  < run document JSON -> comment body

export const DASH = "—";
const SUMMARY_HEADERS = [
  "run", "when", "steal", "sysbench 1-thread events/sec", "sysbench all-core events/sec",
  "fio 4k read/write IOPS", "fio CI 16k read/write IOPS", "compile median", "Docker cold median", "Docker cached",
];

export const MARKERS = {
  summaryStart: "<!-- ci-bench:summary -->",
  summaryEnd: "<!-- /ci-bench:summary -->",
  jsonStart: "<!-- ci-bench:json -->",
  jsonEnd: "<!-- /ci-bench:json -->",
};

const present = (v) => v !== undefined && v !== null;
const num = (v, digits = 1) => (present(v) ? String(Number(v.toFixed(digits))) : DASH);
const iops = (v) => (present(v) ? String(Math.round(v)) : DASH);
const secs = (v) => (present(v) ? `${num(v)} s` : DASH);
const pair = (r, w) => (present(r) && present(w) ? `${iops(r)} / ${iops(w)}` : DASH);

/** UTC RFC 3339 -> "2026-11-01 13:00 MST" in America/Boise (MST or MDT as in force). */
export function boise(utc) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Boise", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZoneName: "short",
  }).formatToParts(new Date(utc));
  const p = Object.fromEntries(parts.map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute} ${p.timeZoneName}`;
}

const esc = (s) => String(s).replace(/\|/g, "\\|").replace(/\r?\n/g, " ");
const table = (headers, rows) =>
  [`| ${headers.join(" | ")} |`, `| ${headers.map(() => "---").join(" | ")} |`, ...rows.map((r) => `| ${r.map(esc).join(" | ")} |`)].join("\n");

export function summaryRow(run, index) {
  const y = run.fio_yabs?.["4k"];
  const c = run.fio_ci;
  return [
    String(index + 1), boise(run.started_at), present(run.host?.cpu_steal_percent) ? `${num(run.host.cpu_steal_percent, 2)}%` : DASH,
    num(run.cpu?.single_thread?.events_per_sec), num(run.cpu?.multi_thread?.events_per_sec),
    pair(y?.read?.iops, y?.write?.iops), pair(c?.read?.iops, c?.write?.iops),
    secs(run.compile?.median_s), secs(run.docker?.cold?.median_s), secs(run.docker?.cached_s),
  ];
}

export function summaryTable(runs) {
  return table(SUMMARY_HEADERS, runs.map(summaryRow));
}

export function hostList(host, labels = {}) {
  const disk = host.disk_model ? `${host.disk_model} (${host.disk_rotational === true ? "rotational" : host.disk_rotational === false ? "non-rotational" : "rotation unknown"})` : DASH;
  const items = [
    ["Hostname", host.hostname], ["Provider", labels.provider || DASH], ["Plan", labels.plan || DASH],
    ["CPU", host.cpu_model], ["Cores", host.cores], ["RAM", `${num(host.ram_bytes / 1073741824)} GiB`],
    ["Disk", disk], ["Distro", host.distro], ["Kernel", host.kernel], ["Architecture", host.arch],
    ["Virtualization", host.virtualization],
  ];
  return items.map(([k, v]) => `- **${k}:** ${v}`).join("\n");
}

const fence = (obj) => "```json\n" + JSON.stringify(obj, null, 2) + "\n```";

const summarySection = (runs) => `${MARKERS.summaryStart}\n${summaryTable(runs)}\n${MARKERS.summaryEnd}`;
const jsonSection = (doc) => `${MARKERS.jsonStart}\n${fence(doc)}\n${MARKERS.jsonEnd}`;

/** Issue body from a host-issue document. `labels` only feeds the human list. */
export function renderBody(doc, labels = {}) {
  return [hostList(doc.host, labels), "", summarySection(doc.runs), "", jsonSection(doc), ""].join("\n");
}

/** Read the host-issue document back from a body: the JSON fence is the source of truth. */
export function parseBody(body) {
  const a = body.indexOf(MARKERS.jsonStart), b = body.indexOf(MARKERS.jsonEnd);
  if (a < 0 || b < a) throw new Error("issue body has no ci-bench JSON section");
  const m = body.slice(a + MARKERS.jsonStart.length, b).match(/```json\n([\s\S]*?)\n```/);
  if (!m) throw new Error("issue body JSON section has no json fence");
  return JSON.parse(m[1]);
}

/** Replace the summary table and JSON fence in an existing body; the human list is left alone. */
export function updateBody(body, doc) {
  const swap = (text, start, end, replacement) => {
    const a = text.indexOf(start), b = text.indexOf(end);
    if (a < 0 || b < a) throw new Error(`issue body is missing ${start}`);
    return text.slice(0, a) + replacement + text.slice(b + end.length);
  };
  let out = swap(body, MARKERS.summaryStart, MARKERS.summaryEnd, summarySection(doc.runs));
  out = swap(out, MARKERS.jsonStart, MARKERS.jsonEnd, jsonSection(doc));
  return out;
}

/** Comment for one run: a metrics table, any errors, then the full run document. */
export function renderComment(run) {
  const y = run.fio_yabs ?? {};
  const rows = [
    ["CPU steal", present(run.host?.cpu_steal_percent) ? `${num(run.host.cpu_steal_percent, 2)}%` : DASH],
    ["sysbench 1-thread events/sec", num(run.cpu?.single_thread?.events_per_sec)],
    ["sysbench all-core events/sec", num(run.cpu?.multi_thread?.events_per_sec)],
    ...["4k", "64k", "512k", "1m"].map((bs) => [`fio YABS ${bs} read/write IOPS`, pair(y[bs]?.read?.iops, y[bs]?.write?.iops)]),
    ["fio CI 16k read/write IOPS", pair(run.fio_ci?.read?.iops, run.fio_ci?.write?.iops)],
    ["compile median", secs(run.compile?.median_s)],
    ["Docker cold median", secs(run.docker?.cold?.median_s)],
    ["Docker cached rebuild", secs(run.docker?.cached_s)],
  ];
  const errors = (run.errors ?? []).length ? run.errors.map((e) => `- **${e.probe}:** ${e.message}`).join("\n") : "none";
  return [
    `### Run ${boise(run.started_at)}`, "", table(["metric", "value"], rows), "", `**Errors:** ${errors.includes("\n") ? "\n" + errors : errors}`, "", fence(run), "",
  ].join("\n");
}

async function main() {
  const [, , mode] = process.argv;
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (mode === "body") process.stdout.write(renderBody(input, input.labels ?? {}));
  else if (mode === "comment") process.stdout.write(renderComment(input));
  else { console.error("usage: render.mjs body|comment < json"); process.exit(2); }
}
if (import.meta.url === `file://${process.argv[1]}`) main();
