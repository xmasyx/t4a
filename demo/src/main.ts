/**
 * T4A — Phase 1 demo.
 *
 * Frontend only, no engine: the point is to settle the structure before a line
 * of Swift exists. Every recorded turn, tool call, duration and diff came out
 * of a real Claude Code session and was anonymised by demo/tools/extract.ts.
 */

import dataset from "../data/recorded-session.json";
import sampleFacts from "../data/facts.sample.json";
import type { Approval, Dataset, FactItem, Facts, Line, Session, SessionState, Turn, Waiting } from "./types.ts";

const data = dataset as Dataset;

/**
 * Facts have two levels. The public bundle carries the sample; a personal
 * dashboard arrives inlined by demo/local.html, which is never committed — so
 * the shipped app.js physically cannot hold anyone's numbers.
 */
const facts: Facts = ((globalThis as Record<string, unknown>).__T4A_FACTS__ as Facts) ?? (sampleFacts as Facts);

// ------------------------------------------------------------------ state

type SlotId = "left-1" | "left-2" | "left-3" | "right-1" | "right-2" | "right-3";

const SLOTS: SlotId[] = ["left-1", "left-2", "left-3", "right-1", "right-2", "right-3"];

const SLOT_TITLES: Record<SlotId, string> = {
  "left-1": "left · line 1",
  "left-2": "left · line 2",
  "left-3": "left · line 3",
  "right-1": "right · line 1",
  "right-2": "right · line 2",
  "right-3": "right · line 3",
};

/** Left is consumption then the windows; right is who you are, then the system. */
const DEFAULT_SLOTS: Record<SlotId, string[]> = {
  "left-1": ["context", "startup", "effort"],
  "left-2": ["w-5hr", "w-wk", "w-fable"],
  // The third line starts empty on both sides: it exists so a row can be
  // chosen, not because anything has to live there.
  "left-3": [],
  "right-1": ["session", "directory", "branch", "permissions", "model"],
  "right-2": ["engine", "lifeos", "algorithm", "memory", "review", "agents", "extra"],
  "right-3": [],
};

const groupOf = (slot: SlotId) => (slot.startsWith("left") ? "dash-left" : "dash-right");
const rowOf = (slot: SlotId) => Number(slot.slice(-1));


type Decision = "pending" | "approved" | "denied";

const STORE = "t4a.demo.v3";

type Prefs = {
  layout: "rail" | "tabs";
  rail: "open" | "closed";
  inspector: "open" | "closed";
  dash: "open" | "closed";
  theme: "black" | "warm";
  railW: number;
  inspW: number;
  bandH: number;
  dashH: number;
  off: string[];
  slots: Record<SlotId, string[]>;
};

/** The rows that start switched off on the bar. */
const OFF_BY_DEFAULT = ["session", "branch", "engine", "agents", "extra"];

/** The header path is a switchable row too, it just does not live on the bar. */
const HEADER_PATH = "header-path";

const DEFAULTS: Prefs = {
  layout: "rail",
  rail: "open",
  inspector: "open",
  dash: "open",
  theme: "black",
  railW: 232,
  inspW: 300,
  bandH: 56,
  dashH: 66,
  off: [...OFF_BY_DEFAULT],
  slots: structuredClone(DEFAULT_SLOTS),
};

function loadPrefs(): Prefs {
  try {
    const raw = localStorage.getItem(STORE);
    if (!raw) return { ...DEFAULTS };
    const saved = JSON.parse(raw) as Partial<Prefs>;
    return {
      ...DEFAULTS,
      ...saved,
      off: Array.isArray(saved.off) ? saved.off : [...OFF_BY_DEFAULT],
      slots: mergeSlots(saved.slots),
    };
  } catch {
    return { ...DEFAULTS };
  }
}

/**
 * Every key lives in exactly one slot, always. A saved layout that lost a key
 * (or carries one we no longer ship) is repaired here rather than trusted, so a
 * reorder can never strand an item outside the four slots.
 */
function mergeSlots(saved: unknown): Record<SlotId, string[]> {
  const known = new Set(Object.values(DEFAULT_SLOTS).flat());
  const out = {} as Record<SlotId, string[]>;
  const placed = new Set<string>();
  for (const slot of SLOTS) {
    const list = (saved as Record<string, unknown> | undefined)?.[slot];
    out[slot] = (Array.isArray(list) ? list.map(String) : []).filter((key) => {
      if (!known.has(key) || placed.has(key)) return false;
      placed.add(key);
      return true;
    });
  }
  for (const slot of SLOTS) {
    for (const key of DEFAULT_SLOTS[slot]) {
      if (!placed.has(key)) {
        out[slot].push(key);
        placed.add(key);
      }
    }
  }
  return out;
}

function savePrefs() {
  try {
    localStorage.setItem(STORE, JSON.stringify(prefs));
  } catch {
    /* private-mode browsers: the demo still works, it just forgets. */
  }
}

const prefs = loadPrefs();

const states = new Map<string, SessionState>();
const waiting = new Map<string, Waiting>();
const decisions = new Map<string, Decision>();
const extraTurns = new Map<string, Turn[]>();
const extraLines = new Map<string, Array<{ kind: "prompt" | "meta"; text: string; turn: number }>>();

function seed() {
  for (const session of data.sessions) {
    states.set(session.id, session.state);
    waiting.set(session.id, session.approval ? "approval" : session.state === "waits-you" ? "input" : null);
    decisions.set(session.id, session.approval ? "pending" : "approved");
    extraTurns.set(session.id, []);
    extraLines.set(session.id, []);
  }
}
seed();

let selectedId = data.sessions[0]?.id ?? "";
let selectedTurn = -1;
let sheet: "settings" | "palette" | null = null;

const CATEGORIES = ["Sessions", "Layout", "Appearance", "Dashboard rows", "Demo"] as const;
let category: (typeof CATEGORIES)[number] = "Dashboard rows";

/** One human name per row. The internal key is ours, not the reader's. */
const NAMES: Record<string, string> = {
  context: "Context window",
  startup: "Startup load",
  effort: "Effort",
  "w-5hr": "Five-hour window",
  "w-wk": "Weekly window",
  "w-fable": "Fable window",
  model: "Model",
  permissions: "Permission mode",
  directory: "Directory",
  session: "Session title",
  branch: "Branch",
  engine: "Engine version",
  lifeos: "System version",
  algorithm: "Algorithm version",
  memory: "Memory health",
  review: "Review backlog",
  agents: "Live agents",
  extra: "Subscription",
  [HEADER_PATH]: "Path in the header",
};

const humanName = (key: string) => NAMES[key] ?? key;

/**
 * On this terminal the house vendor is implied, so the model reads «Opus 5»,
 * never the slug. An unknown string is left alone rather than mangled.
 */
function shortModel(raw: string): string {
  const cleaned = raw.toLowerCase().replace(/\[[^\]]*\]/g, "").replace(/-\d{8}$/, "").trim();
  const match = /(fable|opus|sonnet|haiku)-?(\d+(?:[-.]\d+)*)?/.exec(cleaned);
  if (!match) return raw;
  const family = match[1]!;
  const version = match[2]?.replace(/-/g, ".").replace(/\.$/, "");
  return `${family[0]!.toUpperCase()}${family.slice(1)}${version ? ` ${version}` : ""}`;
}

type Severity = "critical" | "warn";

/**
 * THE map from state to colour, and the only one. Every red in the bar comes
 * from here — a word in a reading, or a percentage past its line — so adding a
 * row never means teaching a new place what trouble looks like.
 *
 *   critical  the thing is broken or full: red, at full strength
 *   warn      the thing is heading there: the same red, quieter
 */
const RED_WORDS: Array<{ when: RegExp; level: Severity }> = [
  { when: /\b(critical|critica|error|errore|failed|fail|down|exceeded|exhausted|full|piena)\b/i, level: "critical" },
  { when: /\b(warn|warning|attenzione|degraded|stale|blocked|backlog)\b/i, level: "warn" },
];

/** Percentages carry the same meaning without a word for it. */
const RED_RATIOS: Array<{ at: number; level: Severity }> = [
  { at: 100, level: "critical" },
  { at: 90, level: "warn" },
];

function severityOfText(value: string): Severity | null {
  for (const rule of RED_WORDS) if (rule.when.test(value)) return rule.level;
  return null;
}

function severityOfRatio(pct: number): Severity | null {
  for (const rule of RED_RATIOS) if (pct >= rule.at) return rule.level;
  return null;
}

/**
 * A switched-off row comes back on its own while something is wrong with it: a
 * fault is not an aesthetic preference, so it outranks the toggle and leaves
 * again when the value is healthy.
 */
function alarmOf(key: string): Severity | null {
  const forced = simulated.get(key);
  if (forced) return severityOfText(forced) ?? "warn";
  const item = facts.items.find((candidate) => candidate.key === key);
  if (!item) return null;
  if (item.kind === "text") return severityOfText(item.value ?? "");
  if (item.kind === "window" || item.kind === "meter") {
    return severityOfRatio(forcedPct.get(key) ?? Number(item.pct ?? 0));
  }
  if (item.kind === "context") {
    const window = windowFor(item.model ?? "");
    return window ? severityOfRatio(((item.tokens ?? 0) / window) * 100) : null;
  }
  return null;
}

/** Demo overrides: a reading forced into a state so it can be watched happen. */
const simulated = new Map<string, string>();
const forcedPct = new Map<string, number>();

/** A cross-vendor worker exists only while it runs. Never a standing row. */
let worker: { vendor: string; since: number } | null = null;
let workerTimer = 0;

const ROW_TITLES: Record<string, string> = {
  "dash-left-1": "left, upper line",
  "dash-left-2": "left, lower line",
  "dash-right-1": "right, upper line",
  "dash-right-2": "right, lower line",
};
const expanded = new Set<string>();

const el = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

// ----------------------------------------------------------------- format

function human(ms: number): string {
  if (ms <= 0) return "—";
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const minutes = Math.floor(ms / 60_000);
  return `${minutes}m ${Math.round((ms % 60_000) / 1000)}s`;
}

/** Token counts read as 363k and 1M — never 1000k. */
function short(n: number): string {
  if (n >= 1_000_000) {
    const m = n / 1_000_000;
    return `${Number.isInteger(m) ? m : m.toFixed(1)}M`;
  }
  if (n >= 1000) return `${Math.round(n / 1000)}k`;
  return String(n);
}

/**
 * The context ceiling belongs to the model, not to a constant. A wrong default
 * multiplies every percentage and still looks plausible, so the alias decides:
 * the `[1m]` suffix is the long window, everything else is the model's own.
 */
function windowFor(model: string): number {
  const name = model.toLowerCase();
  if (/\[1m\]|-1m\b/.test(name)) return 1_000_000;
  if (/haiku/.test(name)) return 200_000;
  if (/sonnet/.test(name)) return 200_000;
  if (/opus|fable/.test(name)) return 200_000;
  return 200_000;
}

function escape(text: string): string {
  return text.replace(/[<&]/g, (c) => (c === "<" ? "&lt;" : "&amp;"));
}

function stateLabel(session: Session): string {
  const state = states.get(session.id);
  if (state === "waits-you") return waiting.get(session.id) === "approval" ? "needs approval" : "waits you";
  if (state === "works") return "working";
  return `idle ${session.idleMinutes}m`;
}

const ORDER: Record<SessionState, number> = { "waits-you": 0, works: 1, idle: 2 };
const ordered = () => [...data.sessions].sort((a, b) => ORDER[states.get(a.id)!] - ORDER[states.get(b.id)!]);
const current = () => data.sessions.find((s) => s.id === selectedId)!;
const turnsOf = (session: Session) => [...session.turns, ...(extraTurns.get(session.id) ?? [])];

// ------------------------------------------------------------------ paint

function paintShell() {
  const root = document.documentElement;
  root.dataset.theme = prefs.theme;
  root.dataset.layout = prefs.layout;
  root.dataset.rail = prefs.rail;
  root.dataset.inspector = prefs.inspector;
  root.dataset.dash = prefs.dash;

  root.style.setProperty("--band-h", `${prefs.bandH}px`);
  root.style.setProperty("--dash-h", `${prefs.dashH}px`);

  // The stage columns are written here rather than in CSS: a hidden panel must
  // give its width back to the terminal, grip included.
  const railOn = prefs.layout === "rail" && prefs.rail === "open";
  const inspOn = prefs.inspector === "open";
  const columns = [
    railOn ? `${prefs.railW}px` : "0px",
    railOn ? "3px" : "0px",
    "minmax(0, 1fr)",
    inspOn ? "3px" : "0px",
    inspOn ? `${prefs.inspW}px` : "0px",
  ].join(" ");
  el("stage").style.gridTemplateColumns = columns;
  el("rail").style.display = railOn ? "flex" : "none";
  el("grip-rail").style.display = railOn ? "block" : "none";
  el("inspector").style.display = inspOn ? "grid" : "none";
  el("grip-inspector").style.display = inspOn ? "block" : "none";

  // The header title lines up with the terminal's first character, so the eye
  // finds one left edge instead of two.
  const TERMINAL_TEXT_INSET = 18;
  const titleX = railOn ? prefs.railW + 3 + TERMINAL_TEXT_INSET : TERMINAL_TEXT_INSET;
  document.documentElement.style.setProperty("--title-x", `${titleX}px`);

  el("toggle-rail").dataset.on = railOn ? "yes" : "no";
  el("toggle-inspector").dataset.on = inspOn ? "yes" : "no";
  el("toggle-dash").dataset.on = prefs.dash === "open" ? "yes" : "no";
}

function paintSessions() {
  const rail = el("rail");
  const tabs = el("tabs");
  rail.innerHTML = "";
  tabs.innerHTML = "";

  const head = document.createElement("div");
  head.className = "rail-head";
  head.innerHTML = '<span class="rail-title">Sessions</span>';
  head.append(viewButton("top", "move sessions to tabs on top", () => setLayout("tabs")));
  rail.append(head);

  tabs.append(viewButton("side", "move sessions back to the side rail", () => setLayout("rail")));

  for (const session of ordered()) {
    const state = states.get(session.id)!;
    const make = (full: boolean) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "session";
      button.dataset.state = state;
      button.dataset.selected = session.id === selectedId ? "yes" : "no";
      button.title = session.title;
      button.innerHTML =
        `<span class="session-row">` +
        `<span class="session-icon">›</span>` +
        `<span class="session-name">${escape(session.name)}</span>` +
        (full ? `<span class="session-count">${turnsOf(session).length}</span>` : "") +
        `</span>` +
        (full
          ? `<span class="session-sub"><span class="state">${stateLabel(session)}</span>` +
            `<span class="session-title">${escape(session.title)}</span></span>`
          : "");
      button.addEventListener("click", () => select(session.id));
      return button;
    };
    rail.append(make(true));
    tabs.append(make(false));
  }
}

/** The chevron points where the sessions are going. Fixed box, stable size. */
function viewButton(side: "top" | "side", title: string, run: () => void): HTMLElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "icon icon-chevron";
  button.title = title;
  button.setAttribute("aria-label", title);
  button.dataset.dir = side;
  button.innerHTML = '<span class="chevron"></span>';
  button.addEventListener("click", run);
  return button;
}

function paintCount() {
  const count = data.sessions.filter((s) => states.get(s.id) === "waits-you").length;
  const node = el("count");
  node.dataset.waiting = count > 0 ? "yes" : "no";
  el("count-number").textContent = String(count);
  el("count-label").textContent = count === 1 ? "waiting" : "waiting";
}

/**
 * The terminal reads as a conversation, not as a wall: for every exchange the
 * question and the final answer stay visible, and everything the agent did in
 * between folds into one line you can open. The turn map on the right stays the
 * way to search and jump — opening a turn from there unfolds its work first.
 */
type Group = { prompt: Line | null; work: Line[]; answer: Line[]; turns: Set<number> };

function groupLines(lines: Line[]): Group[] {
  const groups: Group[] = [];
  for (const line of lines) {
    if (line.kind === "prompt" || !groups.length) {
      groups.push({ prompt: line.kind === "prompt" ? line : null, work: [], answer: [], turns: new Set() });
      if (line.kind === "prompt") {
        groups.at(-1)!.turns.add(line.turn);
        continue;
      }
    }
    groups.at(-1)!.work.push(line);
    groups.at(-1)!.turns.add(line.turn);
  }
  // The answer is the trailing run of prose: splitting it off keeps the order
  // honest — prompt, then the work, then what the agent finally said.
  for (const group of groups) {
    while (group.work.length && group.work.at(-1)!.kind === "text") {
      group.answer.unshift(group.work.pop()!);
    }
  }
  return groups;
}

const openWork = new Set<number>();

function lineNode(line: Line): HTMLElement {
  const span = document.createElement("span");
  span.className = `ln k-${line.kind}`;
  span.dataset.turn = String(line.turn);
  span.textContent = line.text || " ";
  return span;
}

function paintTerminal() {
  const session = current();
  const terminal = el("terminal");
  terminal.innerHTML = "";

  const groups = groupLines([...session.lines, ...(extraLines.get(session.id) ?? [])] as Line[]);
  groups.forEach((group, index) => {
    if (group.prompt) terminal.append(lineNode(group.prompt));

    if (group.work.length) {
      const open = openWork.has(index);
      const steps = group.work.filter((line) => line.kind === "tool").length;
      const fold = document.createElement("button");
      fold.type = "button";
      fold.className = "fold";
      fold.dataset.open = open ? "yes" : "no";
      fold.dataset.group = String(index);
      fold.textContent = open
        ? `hide the work · ${steps} step${steps === 1 ? "" : "s"}`
        : `${steps} step${steps === 1 ? "" : "s"} · show the work`;
      fold.addEventListener("click", () => {
        if (open) openWork.delete(index);
        else openWork.add(index);
        paintTerminal();
      });
      terminal.append(fold);
      if (open) {
        for (const line of group.work) terminal.append(lineNode(line));
        // Closing from the top means scrolling back up past everything you just
        // read; the control at the end is the one that gets used.
        const foot = document.createElement("button");
        foot.type = "button";
        foot.className = "fold fold-foot";
        foot.dataset.open = "yes";
        foot.textContent = `hide the work · ${steps} step${steps === 1 ? "" : "s"}`;
        foot.addEventListener("click", () => {
          openWork.delete(index);
          paintTerminal();
        });
        terminal.append(foot);
      }
    }

    for (const line of group.answer) terminal.append(lineNode(line));
  });

  paintApproval();
  paintComposer();
}

/** Opening a turn from the map unfolds the block that holds it. */
function revealTurn(turn: number) {
  const session = current();
  const groups = groupLines([...session.lines, ...(extraLines.get(session.id) ?? [])] as Line[]);
  const index = groups.findIndex((group) => group.turns.has(turn));
  if (index >= 0 && !openWork.has(index)) {
    openWork.add(index);
    paintTerminal();
  }
}

function paintApproval() {
  const session = current();
  const slot = el("approval-slot");
  slot.innerHTML = "";
  const approval: Approval | null = session.approval;
  if (!approval) return;

  // Once decided, the card is gone: it lives on as a line in the terminal, the
  // way a real permission prompt does. Leaving it hanging read like a bug.
  if (decisions.get(session.id) !== "pending") return;

  const card = document.createElement("div");
  card.className = "approval";
  card.dataset.waiting = "yes";

  const diff = approval.diff
    .map((row) => {
      const mark = row.kind === "add" ? "+" : row.kind === "del" ? "-" : " ";
      return `<div class="${row.kind}">${escape(`${mark} ${row.text}`) || " "}</div>`;
    })
    .join("");

  card.innerHTML =
    `<div class="approval-head"><span class="approval-q">${escape(approval.question)}</span>` +
    `<span class="approval-file">${escape(approval.tool)} · ${escape(approval.file)}</span></div>` +
    `<div class="diff">${diff}</div><div class="approval-actions"></div>`;

  const actions = card.querySelector(".approval-actions") as HTMLElement;

  const yes = document.createElement("button");
  yes.type = "button";
  yes.className = "primary";
  yes.textContent = "Approve";
  yes.addEventListener("click", () => decide(session.id, "approved"));

  const no = document.createElement("button");
  no.type = "button";
  no.className = "secondary";
  no.textContent = "Deny";
  no.addEventListener("click", () => decide(session.id, "denied"));

  const hint = document.createElement("span");
  hint.className = "approval-decided";
  hint.textContent = "writes the keystroke into the real prompt";
  actions.append(yes, no, hint);

  slot.append(card);
}

/** You can always answer a session; a pending permission is the one thing that blocks. */
function paintComposer() {
  const session = current();
  const form = el<HTMLFormElement>("composer");
  const input = el<HTMLTextAreaElement>("composer-input");
  const send = el<HTMLButtonElement>("composer-send");
  const hint = el("composer-hint");

  const blocked = waiting.get(session.id) === "approval";
  form.dataset.open = blocked ? "no" : "yes";
  input.disabled = blocked;
  send.disabled = blocked || !input.value.trim();
  input.placeholder = blocked ? "" : `reply to ${session.name}…`;
  hint.textContent = blocked ? "decide the permission first" : "⏎ to send · ⇧⏎ for a new line";
}

/** A map of the run, not a copy of it: one row per turn, tools folded inside. */
function paintInspector() {
  const session = current();
  const list = el("turns");
  const turns = turnsOf(session);
  list.innerHTML = "";
  el("turn-count").textContent = `${turns.length}`;

  for (const turn of turns) {
    const key = `${session.id}:${turn.index}`;
    const open = expanded.has(key);
    const item = document.createElement("li");

    const button = document.createElement("button");
    button.type = "button";
    button.className = "turn";
    button.dataset.kind = turn.kind;
    button.dataset.failed = turn.failed ? "yes" : "no";
    button.dataset.live = turn.live ? "yes" : "no";
    button.dataset.selected = turn.index === selectedTurn ? "yes" : "no";
    button.innerHTML =
      `<span class="turn-top">` +
      `<span class="turn-caret">${turn.tools.length ? (open ? "▾" : "▸") : ""}</span>` +
      `<span class="turn-label">${escape(turn.label)}</span>` +
      `<span class="turn-count">${turn.tools.length ? `${turn.tools.length}` : ""}</span>` +
      `<span class="turn-ms">${turn.live ? "now" : human(turn.ms)}</span></span>`;

    button.addEventListener("click", (event) => {
      const caret = (event.target as HTMLElement).closest(".turn-caret");
      if (caret && turn.tools.length) {
        if (open) expanded.delete(key);
        else expanded.add(key);
        paintInspector();
        return;
      }
      jumpTo(turn);
    });
    item.append(button);

    if (open && turn.tools.length) {
      const tools = document.createElement("ul");
      tools.className = "turn-tools";
      for (const tool of turn.tools) {
        const li = document.createElement("li");
        li.className = "turn-tool";
        li.dataset.ok = tool.ok ? "yes" : "no";
        li.innerHTML = `<span>${escape(`${tool.name} ${tool.target}`)}</span><span>${escape(tool.summary)}</span>`;
        tools.append(li);
      }
      item.append(tools);
    }
    list.append(item);
  }
}

/**
 * The dashboard is a statusline. Two groups pushed to the outer edges, each one
 * a two-row grid sharing a single column template — so the label on the lower
 * row starts at the same x as the one above it. The columns are max-content, so
 * sharing them never forces a cell to shrink and nothing is ever truncated.
 *
 * Left is consumption: what this session is burning, then the three windows in
 * a row the way the statusline prints them. Right is context: who and where you
 * are on the first row, what the system is on the second.
 */
const shownKeys = (slot: SlotId) => prefs.slots[slot].filter((key) => !prefs.off.includes(key) || alarmOf(key));

/**
 * Lay the bar out on N paired rows. Two is the resting shape; when the enabled
 * items no longer fit side by side a third row opens — in BOTH halves at once,
 * so the two groups never sit at different heights. The extra rows go to the
 * first slot of each group, which keeps the three windows together on one line.
 */
function layoutDash(rows: number) {
  for (const group of ["dash-left", "dash-right"] as const) {
    const host = el(group);
    host.innerHTML = "";
    host.style.gridTemplateRows = `repeat(${rows}, 21px)`;

    const lists = SLOTS.filter((slot) => groupOf(slot) === group)
      .map((slot) => {
        const keys = [...shownKeys(slot)];
        // The worker rides the LEFT group's second line, at the end. On the
        // right the group is anchored to the window edge, so anything appearing
        // there shoves the ordered set sideways; on the left it just grows.
        if (worker && slot === lastLeftSlot()) keys.push("worker");
        return keys;
      })
      // An empty line must not eat a row: the third one exists to be chosen,
      // not to reserve space before anything lives there.
      .filter((keys) => keys.length > 0);
    if (!lists.length) {
      host.style.gridTemplateColumns = "";
      continue;
    }

    // Extra rows go to whichever line is currently the most crowded. Handing
    // them all to the first slot left the second one as long as ever, so the
    // bar kept overflowing however many rows it opened.
    const spans = lists.map(() => 1);
    for (let extra = rows - spans.length; extra > 0; extra--) {
      let worst = 0;
      for (let i = 1; i < spans.length; i++) {
        if (Math.ceil(lists[i]!.length / spans[i]!) > Math.ceil(lists[worst]!.length / spans[worst]!)) worst = i;
      }
      spans[worst]!++;
    }

    const plan: Array<{ key: string; row: number; column: number }> = [];
    let cursor = 1;

    lists.forEach((keys, index) => {
      const span = Math.max(1, spans[index] ?? 1);
      const perRow = Math.max(1, Math.ceil(keys.length / span));
      keys.forEach((key, at) => {
        plan.push({ key, row: cursor + Math.floor(at / perRow), column: (at % perRow) + 1 });
      });
      cursor += span;
    });

    const columns = Math.max(1, ...plan.map((cell) => cell.column));
    host.style.gridTemplateColumns = `repeat(${columns}, max-content)`;

    // Every row starts at column one, in both halves: right-anchoring each row
    // on its own gave short rows a column grid of their own, which is exactly
    // the drift you see when a third line opens. The GROUP hugs the right edge;
    // its rows do not move independently.
    for (const cell of plan) {
      const item = cell.key === "worker" ? workerItem() : facts.items.find((candidate) => candidate.key === cell.key);
      if (!item) continue;
      const node = document.createElement("div");
      node.className = "dash-item";
      node.dataset.key = item.key;
      const alarm = alarmOf(item.key);
      if (alarm) node.dataset.alarm = alarm;
      if (item.key === "worker") node.dataset.live = "yes";
      node.style.gridRow = String(cell.row);
      node.style.gridColumn = String(cell.column);
      node.innerHTML = `<span class="dash-label">${escape(item.label)}</span>${factValue(item)}`;
      host.append(node);
    }
  }
  document.documentElement.style.setProperty("--dash-min", `${rows * 21 + 12}px`);
}

/** The running worker as a bar cell — built on the fly, never stored in facts. */
function workerItem(): FactItem {
  const seconds = Math.max(1, Math.round((performance.now() - worker!.since) / 1000));
  return { key: "worker", kind: "text", label: "WORKER", value: `${worker!.vendor} · ${seconds}s` };
}

/** Wherever the left group currently ends: the worker never reserves a line. */
function lastLeftSlot(): SlotId {
  const populated = SLOTS.filter((slot) => slot.startsWith("left") && shownKeys(slot).length);
  return populated.at(-1) ?? "left-1";
}

function paintDash() {
  // Measure, then grow: the row count is discovered from what actually fits,
  // never guessed from the number of items.
  // A group needs at least one row per non-empty line; the ceiling is the
  // number of items, past which extra rows buy nothing.
  const linesOf = (side: "left" | "right") =>
    SLOTS.filter((slot) => slot.startsWith(side) && shownKeys(slot).length).length;
  const floor = Math.max(1, linesOf("left"), linesOf("right"));
  const most = Math.max(...SLOTS.map((slot) => shownKeys(slot).length), 2);
  for (let rows = floor; rows <= most * 2; rows++) {
    layoutDash(rows);
    const bar = el("dash-items");
    // The container is the honest test: a per-cell check misses content clipped
    // at the edge of the bar rather than inside a cell.
    if (bar.scrollWidth <= bar.clientWidth + 1 || rows >= most * 2) return;
  }
}

function factValue(item: FactItem): string {
  if (item.kind === "context") {
    const window = windowFor(item.model ?? "");
    const tokens = item.tokens ?? 0;
    return `<span class="dash-value">${short(tokens)} of ${short(window)}</span>`;
  }
  if (item.kind === "meter") return `<span class="dash-value">${forcedPct.get(item.key) ?? item.pct}%</span>`;
  if (item.kind === "effort") {
    return (
      `<span class="dash-scale">` +
      (item.scale ?? [])
        .map((rung) => {
          const on = rung.toLowerCase() === String(item.active ?? "").toLowerCase();
          return `<span class="rung" data-on="${on ? "yes" : "no"}">${escape(rung)}</span>`;
        })
        .join("") +
      `</span>`
    );
  }
  if (item.kind === "window") {
    const pct = forcedPct.get(item.key) ?? item.pct;
    return `<span class="dash-value">${pct}%</span><span class="dash-note">${escape(item.resets ?? "")}</span>`;
  }
  // A simulated fault has to change the reading too, or the row contradicts the
  // alarm that brought it back.
  const forced = simulated.get(item.key);
  const raw = forced ? forced : item.value ?? "—";
  const text = item.key === "model" ? shortModel(raw) : raw;
  return `<span class="dash-value">${escape(text)}</span>`;
}

function paintBand() {
  const session = current();
  el("crumb-title").textContent = session.title;
  const path = el("crumb-path");
  const show = !prefs.off.includes(HEADER_PATH);
  path.style.display = show ? "" : "none";
  path.textContent = `${session.name} · ${session.branch}`;
}

function paintSheet() {
  const overlay = el("overlay");
  const box = el("sheet");
  overlay.hidden = sheet === null;
  box.innerHTML = "";
  if (!sheet) return;

  if (sheet === "settings") {
    box.className = "sheet sheet-split";

    const nav = document.createElement("nav");
    nav.className = "sheet-nav";
    const pane = document.createElement("div");
    pane.className = "sheet-pane";

    for (const name of CATEGORIES) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "sheet-tab";
      button.dataset.on = name === category ? "yes" : "no";
      button.textContent = name;
      button.addEventListener("click", () => {
        category = name;
        paintSheet();
      });
      nav.append(button);
    }

    if (category === "Sessions") {
      pane.append(
        setting("Where they live", "", [
          choice("side rail", prefs.layout === "rail", () => setLayout("rail")),
          choice("tabs on top", prefs.layout === "tabs", () => setLayout("tabs")),
        ]),
      );
    }

    if (category === "Layout") {
      pane.append(
        setting("Turn map", "", [
          choice("shown", prefs.inspector === "open", () => set("inspector", "open")),
          choice("hidden", prefs.inspector === "closed", () => set("inspector", "closed")),
        ]),
        setting("Dashboard bar", "", [
          choice("shown", prefs.dash === "open", () => set("dash", "open")),
          choice("hidden", prefs.dash === "closed", () => set("dash", "closed")),
        ]),
        setting("Path in the header", "the T4A · main line beside the title", [
          choice("shown", !prefs.off.includes(HEADER_PATH), () => toggleKey(HEADER_PATH, false)),
          choice("hidden", prefs.off.includes(HEADER_PATH), () => toggleKey(HEADER_PATH, true)),
        ]),
      );
    }

    if (category === "Appearance") {
      pane.append(
        setting("Theme", "", [
          choice("full black", prefs.theme === "black", () => set("theme", "black")),
          choice("warm dark", prefs.theme === "warm", () => set("theme", "warm")),
        ]),
      );
    }

    if (category === "Demo") {
      pane.append(
        setting("Approval card", "reset brings the pending approval back on purpose", [
          choice("reset", false, reset),
        ]),
        setting("Simulate trouble", "every state that would be red upstream shows red here", [
          choice("memory: warn", simulated.get("memory")?.startsWith("warn") ?? false, () =>
            force("memory", "warn · 1w / 25ok")),
          choice("memory: critical", simulated.get("memory")?.startsWith("critical") ?? false, () =>
            force("memory", "critical · reviewer down")),
          choice("backlog: error", simulated.has("review"), () =>
            force("review", "error · 12 pending")),
          choice("5HR: 100%", forcedPct.get("w-5hr") === 100, () => forceRatio("w-5hr", 100)),
          choice("all clear", !simulated.size && !forcedPct.size, () => {
            simulated.clear();
            forcedPct.clear();
            paintDash();
            paintSheet();
          }),
        ]),
        setting("Cross-vendor worker", "appears only while one is running, then leaves", [
          choice("run GPT", worker?.vendor === "GPT", () => runWorker("GPT")),
          choice("run Gemini", worker?.vendor === "Gemini", () => runWorker("Gemini")),
        ]),
      );
    }

    if (category === "Dashboard rows") {
      const hint = document.createElement("p");
      hint.className = "pane-hint whisper";
      hint.textContent = "drag by the handle to reorder within a line of the bar";
      pane.append(hint);
      // Both columns on screen at once: with the six lines stacked, the far ones
      // sat below the fold and a single drag could never reach them.
      const columns = document.createElement("div");
      columns.className = "row-columns";
      const left = document.createElement("div");
      const right = document.createElement("div");
      for (const slot of SLOTS) (slot.startsWith("left") ? left : right).append(rowGroup(slot));
      columns.append(left, right);
      pane.append(columns);
    }

    box.append(nav, pane);
    return;
  }

  const input = document.createElement("input");
  input.className = "palette-input";
  input.placeholder = "type a command…";
  const list = document.createElement("div");
  list.className = "palette-list";

  const actions: Array<{ label: string; run: () => void }> = [
    { label: prefs.layout === "rail" ? "Sessions: tabs on top" : "Sessions: side rail", run: () => setLayout(prefs.layout === "rail" ? "tabs" : "rail") },
    { label: prefs.inspector === "open" ? "Turn map: hide" : "Turn map: show", run: () => set("inspector", prefs.inspector === "open" ? "closed" : "open") },
    { label: prefs.dash === "open" ? "Dashboard: hide" : "Dashboard: show", run: () => set("dash", prefs.dash === "open" ? "closed" : "open") },
    { label: prefs.theme === "black" ? "Theme: warm dark" : "Theme: full black", run: () => set("theme", prefs.theme === "black" ? "warm" : "black") },
    { label: "Demo: reset (brings the approval back)", run: reset },
    ...data.sessions.map((s) => ({ label: `Go to: ${s.name} — ${s.title}`, run: () => select(s.id) })),
  ];

  const draw = () => {
    const q = input.value.toLowerCase();
    list.innerHTML = "";
    for (const action of actions.filter((a) => a.label.toLowerCase().includes(q))) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "palette-item";
      button.textContent = action.label;
      button.addEventListener("click", () => {
        sheet = null;
        action.run();
      });
      list.append(button);
    }
  };
  input.addEventListener("input", draw);
  box.append(input, list);
  draw();
  input.focus();
}

/**
 * One line of the bar, as a reorderable list. Dropping is allowed across lines
 * too: an item belongs to exactly one slot, and the drag is how you choose it.
 */
function rowGroup(slot: SlotId): HTMLElement {
  const wrap = document.createElement("div");
  wrap.className = "row-group";

  const title = document.createElement("div");
  title.className = "row-group-title whisper";
  title.textContent = SLOT_TITLES[slot];
  wrap.append(title);

  const list = document.createElement("div");
  list.className = "row-list";
  list.dataset.slot = slot;
  if (!prefs.slots[slot].length) {
    list.dataset.empty = "yes";
    const hint = document.createElement("span");
    hint.className = "row-empty whisper";
    hint.textContent = "empty — drop a row here";
    list.append(hint);
  }

  for (const key of prefs.slots[slot]) {
    const item = facts.items.find((candidate) => candidate.key === key);
    if (!item) continue;
    const line = document.createElement("div");
    line.className = "toggle-row";
    line.draggable = true;
    line.dataset.key = key;

    // A real control, not decoration: a drag handle that nothing can address is
    // a handle no keyboard, no screen reader and no test can reach.
    const handle = document.createElement("button");
    handle.type = "button";
    handle.className = "handle";
    handle.setAttribute("aria-label", `Move ${humanName(key)}`);
    handle.innerHTML = "<i></i><i></i><i></i>";

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = humanName(key);

    // Pointer dragging rather than HTML5 drag-and-drop: a real pointer gesture
    // is what a person makes and what a browser test can actually perform, and
    // it hit-tests by coordinates, so an empty line is a target like any other.
    // Mouse events are wired as well: a synthetic mouse sequence never produces
    // a pointerdown, so a pointer-only handler is untestable from outside.
    const beginDrag = (startX: number, startY: number, family: "pointer" | "mouse") => {
      if (dragging) return;
      dragging = key;
      line.dataset.dragging = "yes";

      const moveTo = (x: number, y: number) => {
        // The pane scrolls, so a line below the fold would be unreachable in one
        // gesture: nudge the pane while the pointer sits near an edge.
        const pane = document.querySelector<HTMLElement>(".sheet-pane");
        if (pane) {
          const box = pane.getBoundingClientRect();
          if (y > box.bottom - 40) pane.scrollTop += 18;
          else if (y < box.top + 40) pane.scrollTop -= 18;
        }
        const target = document.elementFromPoint(x, y)?.closest<HTMLElement>(".row-list");
        if (!target) return;
        clearDropMarks();
        target.dataset.landing = "yes";
        const others = [...target.children].filter(
          (node) => node !== line && (node as HTMLElement).dataset.key,
        ) as HTMLElement[];
        const below = others.find((node) => {
          const box = node.getBoundingClientRect();
          return y < box.top + box.height / 2;
        });
        if (below) {
          below.dataset.drop = "before";
          target.insertBefore(line, below);
        } else {
          const last = others.at(-1);
          if (last) last.dataset.drop = "after";
          target.append(line);
        }
      };

      moveTo(startX, startY);

      const onMove = (event: PointerEvent | MouseEvent) => moveTo(event.clientX, event.clientY);
      const onEnd = () => {
        document.removeEventListener(`${family}move`, onMove as EventListener, true);
        document.removeEventListener(`${family}up`, onEnd, true);
        document.removeEventListener(`${family}cancel`, onEnd, true);
        delete line.dataset.dragging;
        dragging = null;
        clearDropMarks();
        commitSlots();
        paintSheet();
      };

      document.addEventListener(`${family}move`, onMove as EventListener, true);
      document.addEventListener(`${family}up`, onEnd, true);
      document.addEventListener(`${family}cancel`, onEnd, true);
    };

    handle.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      beginDrag(event.clientX, event.clientY, "pointer");
    });
    handle.addEventListener("mousedown", (event) => {
      // Only when no pointer event opened the gesture already.
      if (dragging) return;
      event.preventDefault();
      beginDrag(event.clientX, event.clientY, "mouse");
    });

    line.append(handle, name, switchFor(key, !prefs.off.includes(key)));
    list.append(line);
  }

  wrap.append(list);
  return wrap;
}

let dragging: string | null = null;

function clearDropMarks() {
  for (const node of document.querySelectorAll<HTMLElement>(".toggle-row[data-drop]")) {
    delete node.dataset.drop;
  }
  for (const list of document.querySelectorAll<HTMLElement>(".row-list[data-landing]")) {
    delete list.dataset.landing;
  }
}

/** The DOM is the truth after a drag; read every slot back and store it. */
function commitSlots() {
  const next = {} as Record<SlotId, string[]>;
  for (const slot of SLOTS) {
    const list = document.querySelector<HTMLElement>(`.row-list[data-slot="${slot}"]`);
    next[slot] = list
      ? [...list.children].map((n) => (n as HTMLElement).dataset.key ?? "").filter(Boolean)
      : prefs.slots[slot];
  }
  prefs.slots = next;
  savePrefs();
  paintDash();
}

/** M6 lives here so every switch in the app gets the same gesture. */
function switchFor(key: string, on: boolean): HTMLElement {
  const toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = "switch";
  toggle.dataset.on = on ? "yes" : "no";
  toggle.dataset.press = "no";
  toggle.dataset.key = key;
  toggle.setAttribute("aria-label", humanName(key));
  // A real element, not ::after: pseudo-elements vanish from some capture
  // paths, and a control nobody can screenshot cannot be reviewed.
  toggle.innerHTML = '<i class="knob"></i>';

  // Stretch, travel, settle — always in that order. Holding keeps the stretch
  // until release; a quick tap gets the same gesture, compressed, because a
  // switch that snaps has no direction.
  const STRETCH_MS = 60;
  let pressedAt = 0;
  const press = (state: "yes" | "no") => { toggle.dataset.press = state; };

  toggle.addEventListener("pointerdown", () => {
    pressedAt = performance.now();
    press("yes");
  });
  for (const cancelled of ["pointerleave", "pointercancel"]) {
    toggle.addEventListener(cancelled, () => press("no"));
  }
  toggle.addEventListener("click", () => {
    const held = pressedAt ? performance.now() - pressedAt : 0;
    const wasOn = toggle.dataset.on === "yes";
    press("yes");
    const settle = () => {
      // Flip in place and let the transition carry the knob across.
      toggle.dataset.on = wasOn ? "no" : "yes";
      press("no");
      toggleKey(key, wasOn, false);
    };
    const wait = Math.max(0, STRETCH_MS - held);
    if (wait === 0) settle();
    else setTimeout(settle, wait);
  });
  return toggle;
}

function section(title: string): HTMLElement {
  const node = document.createElement("div");
  node.className = "section-title whisper";
  node.textContent = title;
  return node;
}

/**
 * One place decides what a switched-off key means, bar row or header alike.
 * The sheet is NOT repainted for a switch: rebuilding the control mid-gesture
 * destroys the knob and its travel becomes a jump. Measured at 73ms before this
 * was fixed — the stretch played, the run did not.
 */
function toggleKey(key: string, wasOn: boolean, repaintSheet = true) {
  prefs.off = wasOn ? [...prefs.off, key] : prefs.off.filter((k) => k !== key);
  savePrefs();
  paintDash();
  paintBand();
  if (repaintSheet) paintSheet();
}

function setting(label: string, note: string, controls: HTMLElement[]): HTMLElement {
  const wrap = document.createElement("div");
  wrap.className = "setting";
  const name = document.createElement("span");
  name.className = "setting-label";
  name.innerHTML = `${escape(label)}${note ? `<em class="setting-note">${escape(note)}</em>` : ""}`;
  const group = document.createElement("span");
  group.className = "setting-controls";
  group.append(...controls);
  wrap.append(name, group);
  return wrap;
}

function choice(label: string, on: boolean, run: () => void): HTMLElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "ghost";
  button.dataset.on = on ? "yes" : "no";
  button.textContent = label;
  button.addEventListener("click", run);
  return button;
}

function paint() {
  paintShell();
  paintCount();
  paintSessions();
  paintBand();
  paintTerminal();
  paintInspector();
  paintDash();
  paintSheet();
}

// ------------------------------------------------------------- behaviour

function select(id: string) {
  selectedId = id;
  selectedTurn = -1;
  openWork.clear();
  sheet = null;
  paint();
  toBottom();
}

/** A terminal opens on the present, not on the beginning of the history. */
function toBottom() {
  const scroll = el("terminal-scroll");
  scroll.scrollTop = scroll.scrollHeight;
}

function set<K extends keyof Prefs>(key: K, value: Prefs[K]) {
  prefs[key] = value;
  savePrefs();
  paint();
}

/** Moving sessions to tabs closes the rail, and coming back reopens it. */
function setLayout(layout: Prefs["layout"]) {
  prefs.layout = layout;
  if (layout === "rail") prefs.rail = "open";
  savePrefs();
  paint();
}

function jumpTo(turn: Turn) {
  selectedTurn = turn.index;
  revealTurn(turn.index);
  paintInspector();
  const lines = Array.from(document.querySelectorAll<HTMLElement>(".ln"));
  for (const line of lines) line.classList.remove("is-lit");
  const mine = lines.filter((line) => line.dataset.turn === String(turn.index));
  for (const line of mine) line.classList.add("is-lit");
  mine[0]?.scrollIntoView({ block: "center", behavior: "smooth" });
}

/** Deciding the permission releases the session: it goes back to work. */
function decide(sessionId: string, decision: Decision) {
  decisions.set(sessionId, decision);
  waiting.set(sessionId, null);
  states.set(sessionId, "works");

  const session = data.sessions.find((s) => s.id === sessionId)!;
  const lines = extraLines.get(sessionId)!;
  lines.push({
    kind: "meta",
    text: decision === "approved" ? "permission approved — keystroke sent" : "permission denied — keystroke sent",
    turn: Math.max(0, turnsOf(session).length - 1),
  });

  paint();
  el<HTMLTextAreaElement>("composer-input").focus();
}

/** Sending is the only thing here that writes new content, and it says so. */
function submit(text: string) {
  const session = current();
  const trimmed = text.trim();
  if (!trimmed) return;

  const turns = extraTurns.get(session.id)!;
  const lines = extraLines.get(session.id)!;
  const index = turnsOf(session).length;

  lines.push({ kind: "prompt", text: trimmed, turn: index });
  lines.push({ kind: "meta", text: "sent — the engine has it", turn: index });
  turns.push({
    index,
    kind: "prompt",
    label: trimmed.split("\n")[0]!.slice(0, 72),
    startedAt: new Date().toISOString(),
    ms: 0,
    tools: [],
    failed: false,
    line: 0,
    live: true,
  });

  states.set(session.id, "works");
  waiting.set(session.id, null);
  paint();
  const scroll = el("terminal-scroll");
  scroll.scrollTop = scroll.scrollHeight;
}

/** Simulations write through one door, so what the bar shows stays consistent. */
function force(key: string, reading: string) {
  if (simulated.get(key) === reading) simulated.delete(key);
  else simulated.set(key, reading);
  paintDash();
  paintSheet();
}

function forceRatio(key: string, pct: number) {
  if (forcedPct.get(key) === pct) forcedPct.delete(key);
  else forcedPct.set(key, pct);
  paintDash();
  paintSheet();
}

/** A worker run: it lights up, counts, and takes itself off the bar when done. */
function runWorker(vendor: string, seconds = 8) {
  clearInterval(workerTimer);
  worker = { vendor, since: performance.now() };
  paintDash();
  paintSheet();
  workerTimer = setInterval(() => {
    if (!worker) return;
    if (performance.now() - worker.since >= seconds * 1000) {
      clearInterval(workerTimer);
      worker = null;
      paintSheet();
    }
    paintDash();
  }, 1000) as unknown as number;
}

function reset() {
  seed();
  simulated.clear();
  forcedPct.clear();
  clearInterval(workerTimer);
  worker = null;
  selectedTurn = -1;
  sheet = null;
  expanded.clear();
  paint();
}

// ------------------------------------------------------------------ drag

type Axis = "x" | "y";

function draggable(gripId: string, axis: Axis, apply: (delta: number, start: number) => void, startOf: () => number) {
  const grip = el(gripId);
  grip.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    const from = axis === "x" ? event.clientX : event.clientY;
    const start = startOf();
    // Capture keeps the drag alive outside the 3px grip; a pointer the browser
    // does not know (a synthetic probe) must not break the resize.
    try {
      grip.setPointerCapture(event.pointerId);
    } catch {
      /* no capture available: the move listeners below still do the work. */
    }

    const move = (move: PointerEvent) => {
      const now = axis === "x" ? move.clientX : move.clientY;
      apply(now - from, start);
    };
    const up = () => {
      grip.removeEventListener("pointermove", move);
      grip.removeEventListener("pointerup", up);
      savePrefs();
    };
    grip.addEventListener("pointermove", move);
    grip.addEventListener("pointerup", up);
  });
}

const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));

draggable("grip-rail", "x", (d, start) => {
  prefs.railW = clamp(start + d, 150, 460);
  paintShell();
}, () => prefs.railW);

draggable("grip-inspector", "x", (d, start) => {
  prefs.inspW = clamp(start - d, 180, 560);
  paintShell();
}, () => prefs.inspW);

draggable("grip-band", "y", (d, start) => {
  prefs.bandH = clamp(start + d, 40, 160);
  paintShell();
}, () => prefs.bandH);

draggable("grip-dash", "y", (d, start) => {
  prefs.dashH = clamp(start - d, 26, 200);
  paintShell();
}, () => prefs.dashH);

// ----------------------------------------------------------------- wiring

el("toggle-rail").addEventListener("click", () => {
  if (prefs.layout === "tabs") setLayout("rail");
  else set("rail", prefs.rail === "open" ? "closed" : "open");
});
el("toggle-inspector").addEventListener("click", () => set("inspector", prefs.inspector === "open" ? "closed" : "open"));
el("toggle-dash").addEventListener("click", () => set("dash", prefs.dash === "open" ? "closed" : "open"));

el("open-settings").addEventListener("click", () => {
  sheet = sheet === "settings" ? null : "settings";
  paintSheet();
});

el("overlay").addEventListener("click", (event) => {
  if (event.target === el("overlay")) {
    sheet = null;
    paintSheet();
  }
});

const composerInput = el<HTMLTextAreaElement>("composer-input");

composerInput.addEventListener("input", () => {
  el<HTMLButtonElement>("composer-send").disabled = !composerInput.value.trim();
  composerInput.style.height = "auto";
  composerInput.style.height = `${Math.min(150, composerInput.scrollHeight)}px`;
});

composerInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    const text = composerInput.value;
    composerInput.value = "";
    composerInput.style.height = "auto";
    submit(text);
  }
});

el<HTMLFormElement>("composer").addEventListener("submit", (event) => {
  event.preventDefault();
  const text = composerInput.value;
  composerInput.value = "";
  composerInput.style.height = "auto";
  submit(text);
});

document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    sheet = sheet === "palette" ? null : "palette";
    paintSheet();
  }
  if (event.key === "Escape" && sheet) {
    sheet = null;
    paintSheet();
  }
});

// A small handle so the claims about this demo can be probed from the console
// instead of asserted: poke the facts, repaint, read the ceiling back.
(globalThis as Record<string, unknown>).__T4A__ = { paint, windowFor, facts, prefs };

paint();
toBottom();
