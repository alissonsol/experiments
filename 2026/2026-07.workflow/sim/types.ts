// ============================================================
// SIMULATION — shared types
//
// The simulated engines are FAITHFUL, in-memory models of how
// Restate and Temporal achieve durable execution. They are NOT
// the real servers (see server/real/* for those), but they model
// the same mechanics that make durability work:
//
//   * a durable log (Restate journal / Temporal event history)
//     that is the single source of truth,
//   * deterministic REPLAY of the workflow body from the top,
//     short-circuiting already-completed work from the log,
//   * durable timers on a virtual clock,
//   * external events (Restate durable promise / Temporal signal),
//   * at-least-once step execution (a step whose worker dies mid-run
//     is retried), which is why steps must be idempotent.
//
// Both engines share ONE replay executor (sim/engine.ts) driven by
// an EngineProfile that supplies the engine-specific vocabulary and
// log rendering. That is the whole thesis of the abstraction, made
// executable: same business logic + same mechanics, different skin.
// ============================================================

export type EngineId = "restate" | "temporal";

// ---------- The durable log (engine-agnostic internal form) ----------
// Every durable operation the workflow performs occupies one positional
// SLOT in the log. Because the workflow body is deterministic, the Nth
// durable operation is always the same operation on every replay, so a
// positional log is sufficient (this is exactly what real engines rely
// on). Each slot carries its settled outcome once known.

export type SlotKind = "step" | "timer" | "signal" | "state" | "rand" | "clock";

export type SlotStatus =
  | "running" // side effect started, result not yet durably recorded
  | "completed" // settled with a value (replayed, never re-run)
  | "failed" // settled with an error
  | "fired" // timer elapsed
  | "signaled" // external event delivered
  | "timedout"; // wait elapsed without the event

export interface Slot {
  seq: number; // position in the log (0-based)
  kind: SlotKind;
  name: string; // step name / signal name / "sleep" / "getStatus" ...
  status: SlotStatus;
  args?: unknown[]; // step arguments (for display + re-run on retry)
  result?: unknown; // settled value
  error?: string; // settled error message
  // timer / wait bookkeeping (virtual-clock milliseconds since epoch 0)
  startedAtVc?: number;
  fireAtVc?: number;
  attempts?: number; // how many times the side effect actually executed
  wallStartedAt?: number; // real wall-clock ms when first created (display)
  wallSettledAt?: number;
}

// ---------- Observable side effects (the "real world") ----------
// This log grows ONLY when a step's function actually executes. Replay
// does not add to it. It is the visible proof of durability: complete a
// step, crash, restart -> the step is NOT re-run, so this log is unchanged.
export interface SideEffect {
  seq: number;
  step: string;
  message: string; // human-readable effect, e.g. "Charged 4999 cents"
  attempt: number; // 1 = first execution; >1 = at-least-once retry
  at: number; // wall-clock ms
}

// ---------- Rendered engine-native log entry (for the UI) ----------
// The same underlying slot list is rendered two ways: as a Restate
// journal or as a Temporal event history. This is what the side-by-side
// comparison shows.
export interface RenderedEntry {
  id: number; // event id / journal seq (as the engine would number it)
  type: string; // engine-native type name
  summary: string; // one-line human description
  detail?: string; // secondary line (result, tracking #, error, ...)
  group: number; // maps back to the originating slot.seq (for correlation)
  state: "pending" | "ok" | "fail" | "wait" | "fired";
}

export type LaneStatus =
  | "idle"
  | "running"
  | "suspended"
  | "crashed"
  | "completed"
  | "failed";

// ---------- Step timeline (the four business steps + the wait) ----------
export interface TimelineStep {
  key: string;
  label: string;
  state: "pending" | "active" | "done" | "compensated" | "skipped";
  replayed: boolean; // last touched via replay (not fresh execution)
}

// ---------- A crash the operator armed ----------
export interface ArmedCrash {
  step: string; // step name to crash on (or "*" for the next step)
  when: "before-effect" | "after-effect";
  // before-effect: worker dies before the side effect runs -> clean retry
  // after-effect : worker dies AFTER the side effect ran but BEFORE its
  //                result was journaled -> AT-LEAST-ONCE re-execution
}

// ---------- Full lane snapshot sent to the UI ----------
export interface LaneSnapshot {
  engineId: EngineId;
  engineLabel: string;
  logLabel: string; // "Journal" (Restate) / "Event History" (Temporal)
  status: LaneStatus;
  queriedStatus: string; // value returned by the engine's status query
  result: unknown | null;
  virtualClockMs: number; // current position of the durable virtual clock
  virtualClockLabel: string;
  armedCrash: ArmedCrash | null;
  suspendReason: string | null; // why the workflow is parked
  entries: RenderedEntry[]; // engine-native durable log
  sideEffects: SideEffect[]; // the real-world effects
  timeline: TimelineStep[];
  replayCount: number; // how many times the body has been replayed
  invocationNote: string; // engine-specific "how you'd call this" hint
  mode: "sim" | "real";
}

// Signal used internally to unwind the workflow body when it must park
// (waiting on a timer or an external event that has not arrived).
export class Suspend extends Error {
  constructor(public reason: string) {
    super(reason);
    this.name = "Suspend";
  }
}

// Signal used internally to model a worker crash mid-execution.
export class Crash extends Error {
  constructor(public detail: string) {
    super(detail);
    this.name = "Crash";
  }
}
