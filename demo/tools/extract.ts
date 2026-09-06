#!/usr/bin/env bun
/**
 * Extracts a demo dataset from REAL Claude Code transcripts (JSONL).
 *
 * The demo is judged on real shape, so nothing here is invented: turns, tool
 * calls, durations, outcomes and diffs all come from recorded sessions.
 *
 * Two levels of detail per source:
 *   full     - prompts, assistant prose, tool activity  (own public-project session)
 *   activity - tool activity only, prose dropped        (everything else)
 *
 * Everything passes an anonymiser (home paths, identity, private-tree names)
 * plus a fail-closed scrub gate. `--verify` runs the gate alone and exits 1 on
 * any hit, so it can be used as a check without regenerating.
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { basename } from "node:path";

// ---------------------------------------------------------------- anonymiser

const HOME = process.env.HOME ?? "";
const USER = basename(HOME || "nobody");

const escapeRx = (word: string) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * Line-level deny patterns: a line matching any of these never ships.
 *
 * Structural ones are derived at runtime, so nothing identifying is written into
 * this file. Anything else — private project names, tooling you'd rather not
 * publish — goes in `deny.local.json` next to this script (a JSON array of
 * words, gitignored, never committed).
 */
const EXTRA: string[] = (() => {
  const local = new URL("./deny.local.json", import.meta.url).pathname;
  if (!existsSync(local)) return [];
  try {
    const parsed = JSON.parse(readFileSync(local, "utf8"));
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
})();

const DENY: RegExp[] = [
  /\/Users\//i,
  /\.claude\b/i,
  /\.codex\b/i,
  new RegExp(escapeRx(USER), "i"),
  /[\w.+-]+@[\w-]+\.[\w.]+/,
  ...EXTRA.map((word) => new RegExp(escapeRx(word), "i")),
];

function anonymise(input: string): string {
  let s = input;
  if (HOME) s = s.split(HOME).join("~");
  s = s.replace(/\/Users\/[^/\s"'`]+/g, "~");
  s = s.replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, "user@example.com");
  return s;
}

function clean(input: string): string {
  const kept = anonymise(input)
    .split("\n")
    .filter((line: string) => !DENY.some((rx) => rx.test(line)));
  // Trim blank edge lines only — indentation inside a diff is part of the evidence.
  while (kept.length && !kept[0]!.trim()) kept.shift();
  while (kept.length && !kept.at(-1)!.trim()) kept.pop();
  return kept.join("\n");
}

// ------------------------------------------------------------------- reading

type Entry = Record<string, any>;

function readTranscript(path: string): Entry[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line: string) => {
      try {
        return JSON.parse(line) as Entry;
      } catch {
        return null;
      }
    })
    .filter((e: Entry | null): e is Entry => e !== null);
}

const ms = (a: string, b: string) => Math.max(0, Date.parse(b) - Date.parse(a));

/** One-line label for a tool call — never the payload, only what it targeted. */
function toolTarget(name: string, input: Record<string, any>): string {
  if (typeof input?.description === "string") return input.description;
  for (const key of ["file_path", "path", "notebook_path", "pattern", "url", "query"]) {
    const value = input?.[key];
    if (typeof value === "string") return basename(value);
  }
  if (typeof input?.command === "string") return input.command.split(/\s+/)[0] ?? name;
  return name;
}

/** Result summary: shape and outcome only — tool output bodies never ship. */
function resultSummary(block: Record<string, any>, isError: boolean): string {
  if (isError) return "failed";
  const content = block?.content;
  const text = typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content.filter((c: any) => c?.type === "text").map((c: any) => c.text).join("\n")
      : "";
  if (!text) return "done";
  const lines = text.split("\n").length;
  return lines > 1 ? `${lines} lines` : `${text.length} chars`;
}

// --------------------------------------------------------------------- diff

type DiffRow = { kind: "ctx" | "add" | "del"; text: string };

function unifiedDiff(oldText: string, newText: string): DiffRow[] {
  const before = oldText.split("\n");
  const after = newText.split("\n");
  let head = 0;
  while (head < before.length && head < after.length && before[head] === after[head]) head++;
  let tail = 0;
  while (
    tail < before.length - head &&
    tail < after.length - head &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]
  ) tail++;

  const rows: DiffRow[] = [];
  const ctxBefore = before.slice(Math.max(0, head - 2), head);
  for (const text of ctxBefore) rows.push({ kind: "ctx", text });
  for (const text of before.slice(head, before.length - tail)) rows.push({ kind: "del", text });
  for (const text of after.slice(head, after.length - tail)) rows.push({ kind: "add", text });
  const ctxAfter = before.slice(before.length - tail, before.length - tail + 2);
  for (const text of ctxAfter) rows.push({ kind: "ctx", text });
  return rows;
}

// ------------------------------------------------------------------- model

type Tool = { name: string; target: string; ok: boolean; ms: number; summary: string };
type Turn = {
  index: number;
  kind: "prompt" | "agent";
  label: string;
  startedAt: string;
  ms: number;
  tools: Tool[];
  failed: boolean;
  line: number;
};
type Line = { kind: "prompt" | "text" | "tool" | "result" | "meta"; text: string; turn: number };
type Approval = {
  tool: string;
  file: string;
  question: string;
  diff: DiffRow[];
  askedAt: string;
};
type Session = {
  id: string;
  name: string;
  title: string;
  branch: string;
  cli: string;
  detail: "full" | "activity";
  state: "waits-you" | "works" | "idle";
  since: string;
  idleMinutes: number;
  turns: Turn[];
  lines: Line[];
  approval: Approval | null;
};

type Source = {
  file: string;
  id: string;
  name: string;
  detail: "full" | "activity";
  state: Session["state"];
  idleMinutes: number;
};

function buildSession(source: Source): Session {
  const entries = readTranscript(source.file);
  const results = new Map<string, { entry: Entry; block: Entry }>();
  for (const entry of entries) {
    const content = entry?.message?.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (block?.type === "tool_result" && block.tool_use_id) {
        results.set(block.tool_use_id, { entry, block });
      }
    }
  }

  const lines: Line[] = [];
  const turns: Turn[] = [];
  let approval: Approval | null = null;
  let branch = "main";
  let cli = "claude";
  let title = "";

  const push = (kind: Line["kind"], text: string, turn: number) => {
    for (const chunk of text.split("\n")) lines.push({ kind, text: chunk, turn });
  };

  for (const entry of entries) {
    if (entry.type === "ai-title" && entry.aiTitle) title = clean(String(entry.aiTitle));
    if (entry.gitBranch) branch = String(entry.gitBranch);
    if (entry.version) cli = `claude ${entry.version}`;
    const type = entry.type;
    if (type !== "user" && type !== "assistant") continue;
    const content = entry?.message?.content;

    // A typed prompt from the human.
    if (type === "user" && typeof content === "string") {
      if (source.detail !== "full") continue;
      // Harness attachments arrive shaped like a prompt; they are not one.
      if (/^\[Image: /.test(content.trim())) continue;
      const text = clean(content);
      if (!text) continue;
      const index = turns.length;
      const line = lines.length;
      push("prompt", text, index);
      turns.push({
        index, kind: "prompt", label: text.split("\n")[0]!.slice(0, 72),
        startedAt: entry.timestamp, ms: 0, tools: [], failed: false, line,
      });
      continue;
    }

    if (type !== "assistant" || !Array.isArray(content)) continue;

    // One assistant message = one agent turn block.
    const index = turns.length;
    const line = lines.length;
    const tools: Tool[] = [];
    let end = entry.timestamp;
    let failed = false;
    let label = "";

    for (const block of content) {
      if (block?.type === "text" && typeof block.text === "string") {
        if (source.detail !== "full") {
          // Structure survives, prose does not: the shape is real, the words stay home.
          const withheld = block.text.split("\n").length;
          if (!label) label = `response · ${withheld} lines`;
          push("meta", `response · ${withheld} lines withheld by the anonymiser`, index);
          continue;
        }
        const text = clean(block.text);
        if (!text) continue;
        if (!label) label = text.split("\n")[0]!.slice(0, 72);
        push("text", text, index);
      }
      if (block?.type === "tool_use") {
        const target = clean(toolTarget(block.name, block.input ?? {}));
        const found = results.get(block.id);
        const isError = Boolean(found?.block?.is_error);
        const took = found ? ms(entry.timestamp, found.entry.timestamp) : 0;
        if (found && Date.parse(found.entry.timestamp) > Date.parse(end)) end = found.entry.timestamp;
        if (isError) failed = true;
        const summary = found ? resultSummary(found.block, isError) : "pending";
        tools.push({ name: block.name, target, ok: !isError, ms: took, summary });
        if (!label) label = target ? `${block.name} · ${target}` : block.name;
        push("tool", target ? `${block.name}(${target})` : block.name, index);
        push("result", summary, index);

        // A real permission request: the edit the agent wants to make.
        if (block.name === "Edit" && block.input?.old_string && block.input?.new_string) {
          approval = {
            tool: "Edit",
            file: basename(String(block.input.file_path ?? "file")),
            question: "Edit this file?",
            diff: unifiedDiff(clean(String(block.input.old_string)), clean(String(block.input.new_string))),
            askedAt: entry.timestamp,
          };
        }
      }
    }

    if (!tools.length && lines.length === line) continue;
    turns.push({
      index, kind: "agent", label: label || "thinking",
      startedAt: entry.timestamp, ms: ms(entry.timestamp, end), tools, failed, line,
    });
  }

  const last = turns.at(-1);
  return {
    id: source.id,
    name: source.name,
    title: title || source.name,
    branch,
    cli,
    detail: source.detail,
    state: source.state,
    since: last?.startedAt ?? new Date().toISOString(),
    idleMinutes: source.idleMinutes,
    turns,
    lines,
    approval,
  };
}

// -------------------------------------------------------------------- gate

function scrub(json: string): string[] {
  const hits: string[] = [];
  json.split("\n").forEach((line, i) => {
    for (const rx of DENY) {
      if (rx.test(line)) hits.push(`${i + 1}: ${rx} :: ${line.slice(0, 90)}`);
    }
  });
  return hits;
}

// -------------------------------------------------------------------- main

const OUT = new URL("../data/recorded-session.json", import.meta.url).pathname;

if (process.argv.includes("--verify")) {
  const hits = scrub(readFileSync(OUT, "utf8"));
  if (hits.length) {
    console.error(`SCRUB FAILED — ${hits.length} hits`);
    for (const hit of hits.slice(0, 20)) console.error("  " + hit);
    process.exit(1);
  }
  console.log("scrub clean: 0 identity/path hits in " + basename(OUT));
  process.exit(0);
}

const sourcesFile = process.argv[2];
if (!sourcesFile || !existsSync(sourcesFile)) {
  console.error("usage: bun demo/tools/extract.ts <sources.json> | --verify");
  process.exit(2);
}

const sources = JSON.parse(readFileSync(sourcesFile, "utf8")) as Source[];
const sessions = sources.filter((s) => existsSync(s.file)).map(buildSession);
const payload = {
  note: "Extracted from real Claude Code transcripts, anonymised. No hand-written turns.",
  extractedAt: new Date().toISOString(),
  sessions,
};
const json = JSON.stringify(payload, null, 1);

const hits = scrub(json);
if (hits.length) {
  console.error(`SCRUB FAILED — ${hits.length} hits, nothing written`);
  for (const hit of hits.slice(0, 20)) console.error("  " + hit);
  process.exit(1);
}

writeFileSync(OUT, json + "\n");
for (const s of sessions) {
  console.log(`${s.id.padEnd(10)} ${s.name.padEnd(12)} ${String(s.turns.length).padStart(3)} turns  ${String(s.lines.length).padStart(4)} lines  approval=${s.approval ? "yes" : "no"}  detail=${s.detail}`);
}
console.log(`scrub clean · wrote ${basename(OUT)}`);
