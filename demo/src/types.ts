export type DiffRow = { kind: "ctx" | "add" | "del"; text: string };

export type Tool = { name: string; target: string; ok: boolean; ms: number; summary: string };

export type Turn = {
  index: number;
  kind: "prompt" | "agent";
  label: string;
  startedAt: string;
  ms: number;
  tools: Tool[];
  failed: boolean;
  line: number;
  live?: boolean;
};

export type Line = {
  kind: "prompt" | "text" | "tool" | "result" | "meta";
  text: string;
  turn: number;
};

export type Approval = {
  tool: string;
  file: string;
  question: string;
  diff: DiffRow[];
  askedAt: string;
};

export type SessionState = "waits-you" | "works" | "idle";

/** Why a session wants you: a permission to decide, or your next prompt. */
export type Waiting = "approval" | "input" | null;

export type Session = {
  id: string;
  name: string;
  title: string;
  branch: string;
  cli: string;
  detail: "full" | "activity";
  state: SessionState;
  since: string;
  idleMinutes: number;
  turns: Turn[];
  lines: Line[];
  approval: Approval | null;
};

export type Dataset = {
  note: string;
  extractedAt: string;
  sessions: Session[];
};

export type FactItem = {
  key: string;
  kind: "context" | "meter" | "effort" | "window" | "text";
  label: string;
  value?: string;
  note?: string;
  pct?: number;
  tokens?: number;
  model?: string;
  resets?: string;
  active?: boolean | string;
  scale?: string[];
};

export type Facts = {
  source: "sample" | "local";
  label: string;
  note?: string;
  items: FactItem[];
};
