// ============================================================
// SIMULATION — the shared durable replay executor
//
// ONE executor drives BOTH engines. It implements the same
// DurableContext<S> contract the real Restate/Temporal adapters
// implement (core/durable.ts), so the portable order-workflow.ts
// business logic runs here UNCHANGED — the abstraction, made
// executable. Engines differ only in presentation (sim/profiles.ts).
//
// Durability model (faithful to how real engines work):
//
//   * The journal (positional slots) is the single source of truth.
//   * To make progress OR to recover, we REPLAY def.run() from the
//     top. Each durable op consults its slot: if already settled it
//     returns the recorded outcome WITHOUT re-running; otherwise it
//     does the work and records it.
//   * A step's function is the ONLY thing that touches the outside
//     world, and it runs exactly where the journal says it hasn't yet.
//     Completed steps are never re-run on replay.
//   * If a worker dies mid-step (before the result is journaled), the
//     slot stays "running"; the next replay re-runs the step — this is
//     AT-LEAST-ONCE execution, why steps must be idempotent.
//   * Timers run on a VIRTUAL clock the operator advances, so a 3-day
//     wait is demonstrable in seconds.
// ============================================================

import type {
  DurableContext,
  StepMap,
  WorkflowDefinition,
} from "../core/durable.js";
import { WorkflowTerminalError } from "../core/durable.js";
import {
  Crash,
  Suspend,
  type ArmedCrash,
  type EngineId,
  type LaneSnapshot,
  type LaneStatus,
  type SideEffect,
  type Slot,
  type SlotKind,
  type TimelineStep,
} from "./types.js";
import { PROFILES } from "./profiles.js";

// A monotonic, replay-free wall clock the sim controls (Date.now is
// unavailable in this harness and would break determinism anyway).
let WALL = 1_700_000_000_000;
function wallNow(): number {
  WALL += 1;
  return WALL;
}

export interface Execution {
  id: string;
  engineId: EngineId;
  input: any;
  // ---- durable state (survives a "crash") ----
  journal: Slot[];
  state: Record<string, string>;
  stateLog: { key: string; value: string; at: number }[];
  signalInbox: Record<string, unknown[]>;
  vc: number; // virtual clock, ms since epoch 0
  // ---- observable + volatile ----
  sideEffects: SideEffect[];
  sideEffectSeq: number;
  status: LaneStatus;
  result: unknown | null;
  suspendReason: string | null;
  armedCrash: ArmedCrash | null;
  replayCount: number;
  createdAt: number;
  // ---- per-run bookkeeping (reset each replay) ----
  lastRunReplayed: Set<number>;
  lastRunExecuted: Set<number>;
}

export interface EngineOptions {
  /** Force reserveInventory to report out-of-stock (immediate saga demo). */
  outOfStock?: boolean;
}

export class SimEngine<S extends StepMap, I, O> {
  readonly engineId: EngineId;
  private readonly def: WorkflowDefinition<S, I, O>;
  private readonly steps: S;
  readonly exec: Execution;

  constructor(
    engineId: EngineId,
    def: WorkflowDefinition<S, I, O>,
    id: string,
    input: I,
    opts: EngineOptions = {}
  ) {
    this.engineId = engineId;
    this.def = def;
    this.steps = wrapSteps(def.steps, opts);
    this.exec = {
      id,
      engineId,
      input,
      journal: [],
      state: {},
      stateLog: [],
      signalInbox: Object.fromEntries((def.signals ?? []).map((s) => [s, []])),
      vc: 0,
      sideEffects: [],
      sideEffectSeq: 0,
      status: "idle",
      result: null,
      suspendReason: null,
      armedCrash: null,
      replayCount: 0,
      createdAt: wallNow(),
      lastRunReplayed: new Set(),
      lastRunExecuted: new Set(),
    };
  }

  // ---------- the DurableContext the workflow programs against ----------
  private makeContext(cursor: { p: number }): DurableContext<S> {
    const exec = this.exec;
    const steps = this.steps;
    const engineId = this.engineId;

    const recordSideEffect = (
      name: string,
      args: unknown[],
      result: unknown,
      attempt: number
    ) => {
      exec.sideEffects.push({
        seq: exec.sideEffectSeq++,
        step: name,
        message: synthEffect(name, args, result),
        attempt,
        at: wallNow(),
      });
    };

    return {
      workflowId: exec.id,

      step: (async (name: string, ...args: any[]) => {
        const p = cursor.p;
        const slot = exec.journal[p];
        assertDeterministic(slot, "step", name);

        if (slot && slot.status === "completed") {
          exec.lastRunReplayed.add(p);
          cursor.p++;
          return slot.result;
        }
        if (slot && slot.status === "failed") {
          cursor.p++;
          throw new WorkflowTerminalError(slot.error ?? "step failed");
        }

        // New work, OR retry of a slot left "running" by a prior crash.
        const attempt = (slot?.attempts ?? 0) + 1;
        const rec: Slot =
          slot ??
          ({
            seq: p,
            kind: "step",
            name,
            args,
            status: "running",
            attempts: 0,
            startedAtVc: exec.vc,
            wallStartedAt: wallNow(),
          } as Slot);
        rec.status = "running";
        rec.attempts = attempt;
        rec.args = args;
        exec.journal[p] = rec;
        exec.lastRunExecuted.add(p);

        // Crash BEFORE the side effect: nothing happened in the world;
        // on restart the step runs cleanly for the first time.
        maybeCrash(exec, name, "before-effect");

        let value: unknown;
        try {
          value = await steps[name as keyof S](...(args as any));
        } catch (e) {
          if (e instanceof WorkflowTerminalError) {
            rec.status = "failed";
            rec.error = e.message;
            cursor.p++;
            throw e;
          }
          // A transient step error: leave the slot "running" so a restart
          // re-runs it. Surface as a suspend so the operator can retry.
          rec.error = (e as Error).message;
          throw new Suspend(`step "${name}" failed transiently: ${(e as Error).message} — restart the worker to retry`);
        }

        recordSideEffect(name, args, value, attempt);

        // Crash AFTER the side effect but BEFORE journaling the result:
        // the slot stays "running"; on restart the step runs AGAIN.
        // This is at-least-once execution, why steps must be idempotent.
        maybeCrash(exec, name, "after-effect");

        rec.status = "completed";
        rec.result = value;
        rec.wallSettledAt = wallNow();
        cursor.p++;
        return value;
      }) as DurableContext<S>["step"],

      sleep: async (ms: number) => {
        const p = cursor.p;
        const slot = exec.journal[p];
        assertDeterministic(slot, "timer");
        if (slot && slot.status === "fired") {
          exec.lastRunReplayed.add(p);
          cursor.p++;
          return;
        }
        const rec: Slot =
          slot ??
          ({
            seq: p,
            kind: "timer",
            name: "sleep",
            status: "running",
            startedAtVc: exec.vc,
            fireAtVc: exec.vc + ms,
            wallStartedAt: wallNow(),
          } as Slot);
        if (!slot) exec.journal[p] = rec;
        if (exec.vc >= (rec.fireAtVc ?? 0)) {
          rec.status = "fired";
          cursor.p++;
          return;
        }
        throw new Suspend(`durable timer: sleeping ${ms}ms (fires at T+${rec.fireAtVc})`);
      },

      waitForSignal: async <T,>(name: string, timeoutMs?: number): Promise<T | undefined> => {
        const p = cursor.p;
        const slot = exec.journal[p];
        assertDeterministic(slot, "signal", name);
        if (slot && slot.status === "signaled") {
          exec.lastRunReplayed.add(p);
          cursor.p++;
          return slot.result as T;
        }
        if (slot && slot.status === "timedout") {
          exec.lastRunReplayed.add(p);
          cursor.p++;
          return undefined;
        }
        const rec: Slot =
          slot ??
          ({
            seq: p,
            kind: "signal",
            name,
            status: "running",
            startedAtVc: exec.vc,
            fireAtVc: timeoutMs != null ? exec.vc + timeoutMs : undefined,
            wallStartedAt: wallNow(),
          } as Slot);
        if (!slot) exec.journal[p] = rec;

        // Race resolution: a delivered signal wins over an elapsed timeout.
        // This is a deterministic tie-break — if both the event and the
        // deadline are available at the same replay, we favor the success
        // path (the shipment DID arrive), which is the desirable outcome.
        const inbox = exec.signalInbox[name];
        if (inbox && inbox.length > 0) {
          const v = inbox.shift();
          rec.status = "signaled";
          rec.result = v;
          rec.wallSettledAt = wallNow();
          cursor.p++;
          return v as T;
        }
        if (rec.fireAtVc != null && exec.vc >= rec.fireAtVc) {
          rec.status = "timedout";
          rec.wallSettledAt = wallNow();
          cursor.p++;
          return undefined;
        }
        throw new Suspend(
          `waiting for external event "${name}"` +
            (rec.fireAtVc != null ? ` (times out at T+${rec.fireAtVc})` : "")
        );
      },

      now: async () => {
        const p = cursor.p;
        const slot = exec.journal[p];
        assertDeterministic(slot, "clock");
        if (slot && slot.status === "completed") {
          exec.lastRunReplayed.add(p);
          cursor.p++;
          return new Date(slot.result as number);
        }
        const rec: Slot = { seq: p, kind: "clock", name: "now", status: "completed", result: exec.vc };
        exec.journal[p] = rec;
        cursor.p++;
        return new Date(exec.vc);
      },

      uuid: () => {
        const p = cursor.p;
        const slot = exec.journal[p];
        assertDeterministic(slot, "rand");
        if (slot && slot.status === "completed") {
          exec.lastRunReplayed.add(p);
          cursor.p++;
          return slot.result as string;
        }
        const val = `${exec.id}-uuid-${p}`;
        const rec: Slot = { seq: p, kind: "rand", name: "uuid", status: "completed", result: val };
        exec.journal[p] = rec;
        cursor.p++;
        return val;
      },

      setStatus: (value: string) => {
        // K/V state is idempotent (last-write-wins) and non-positional, so
        // a replay that re-issues the same write must NOT append a duplicate
        // journal entry — the real engines journal each distinct set once.
        if (exec.state["status"] === value) return;
        exec.state["status"] = value;
        exec.stateLog.push({ key: "status", value, at: wallNow() });
      },
    };
  }

  // ---------- the replay loop ----------
  // Runs def.run() from the top, replaying settled slots and doing new
  // work, until the workflow completes, fails, suspends, or crashes.
  private async runToBlock(): Promise<void> {
    const exec = this.exec;
    exec.replayCount++;
    exec.lastRunReplayed = new Set();
    exec.lastRunExecuted = new Set();
    exec.suspendReason = null;
    const cursor = { p: 0 };
    const ctx = this.makeContext(cursor);
    exec.status = "running";
    try {
      const result = await this.def.run(ctx, exec.input);
      exec.result = result;
      // The business logic maps terminal failures to a returned value, so
      // a normal return may still be a business "failed" outcome.
      exec.status = (result as any)?.status === "failed" ? "failed" : "completed";
      exec.suspendReason = null;
    } catch (e) {
      if (e instanceof Suspend) {
        exec.status = "suspended";
        exec.suspendReason = e.reason;
      } else if (e instanceof Crash) {
        exec.status = "crashed";
        exec.suspendReason = e.detail;
      } else if (e instanceof WorkflowTerminalError) {
        // The engine's terminal-error translation point. (Our business
        // logic catches these itself, so this is a safety net.)
        exec.status = "failed";
        exec.result = { status: "failed", reason: e.message };
        exec.suspendReason = null;
      } else {
        exec.status = "crashed";
        exec.suspendReason = `unexpected error: ${(e as Error).message}`;
      }
    }
  }

  // ---------- operator-facing operations ----------
  async start(): Promise<void> {
    if (this.exec.status !== "idle") return;
    await this.runToBlock();
  }

  async deliverSignal(name: string, payload: unknown): Promise<void> {
    if (this.isDone()) return; // terminal executions ignore late signals
    // The inbox is DURABLE state: buffer the payload regardless of whether
    // the worker is momentarily parked, exactly as Temporal (signals to a
    // running/recovering execution) and Restate (durable promises) do. A
    // signal that arrives before the first suspend, or during a crash, must
    // not be lost — it is consumed when the workflow next reaches the wait.
    (this.exec.signalInbox[name] ??= []).push(payload);
    if (this.exec.status === "suspended") await this.runToBlock();
    // idle / crashed: buffered now, drained on the next start() / restart().
  }

  async advanceClock(deltaMs: number): Promise<void> {
    // The virtual clock only matters while parked on a durable timer.
    if (this.exec.status !== "suspended") return;
    this.exec.vc += Math.max(0, deltaMs);
    await this.runToBlock();
  }

  /** Discard the (stateless-between-steps) worker and replay from the
   *  durable log — proving the journal, not memory, is the source of truth.
   *  Safe from any started state; recovers a crashed worker. */
  async restartWorker(): Promise<void> {
    if (this.exec.status === "idle") return;
    await this.runToBlock();
  }

  armCrash(crash: ArmedCrash | null): void {
    this.exec.armedCrash = crash;
  }

  private isDone(): boolean {
    return this.exec.status === "completed" || this.exec.status === "failed";
  }

  // ---------- snapshot for the UI ----------
  snapshot(): LaneSnapshot {
    const profile = PROFILES[this.engineId];
    const exec = this.exec;
    return {
      engineId: this.engineId,
      engineLabel: profile.label,
      logLabel: profile.logLabel,
      status: exec.status,
      queriedStatus: exec.state["status"] ?? (exec.status === "idle" ? "—" : "in-progress"),
      result: exec.result,
      virtualClockMs: exec.vc,
      virtualClockLabel: profile.virtualClockLabel(exec.vc),
      armedCrash: exec.armedCrash,
      suspendReason: exec.suspendReason,
      entries: profile.render(exec),
      sideEffects: exec.sideEffects,
      timeline: this.timeline(),
      replayCount: exec.replayCount,
      invocationNote: profile.invocationNote,
      mode: "sim",
    };
  }

  // A generic timeline derived from the journal slots.
  private timeline(): TimelineStep[] {
    const compensations = new Set(["releaseInventory", "refundPayment"]);
    return this.exec.journal.map((slot) => {
      let state: TimelineStep["state"];
      if (slot.status === "completed" || slot.status === "fired" || slot.status === "signaled") {
        state = compensations.has(slot.name) ? "compensated" : "done";
      } else if (slot.status === "timedout") {
        state = "skipped";
      } else {
        state = "active";
      }
      return {
        key: `${slot.seq}`,
        label: labelFor(slot),
        state,
        replayed: this.exec.lastRunReplayed.has(slot.seq),
      };
    });
  }
}

// ---------- helpers ----------

// Wrap the workflow's step functions to (a) inject faults for demos and
// (b) keep them pure of engine concerns. The business logic never knows.
function wrapSteps<S extends StepMap>(steps: S, opts: EngineOptions): S {
  const wrapped: Record<string, any> = {};
  for (const [name, fn] of Object.entries(steps)) {
    wrapped[name] = async (...args: any[]) => {
      if (name === "reserveInventory" && opts.outOfStock) return false as any;
      return fn(...args);
    };
  }
  return wrapped as S;
}

// Determinism guard: on replay, the Nth durable operation MUST be the same
// operation the journal recorded at that position. If the workflow body is
// nondeterministic (different branch, reordered steps), the recorded slot and
// the requested op diverge — real engines fail the workflow task here rather
// than corrupt the journal, and so do we, with an explanatory error.
function assertDeterministic(slot: Slot | undefined, kind: SlotKind, name?: string): void {
  if (!slot) return;
  const nameMatters = kind === "step" || kind === "signal";
  const nameMismatch = nameMatters && name !== undefined && slot.name !== name;
  if (slot.kind !== kind || nameMismatch) {
    throw new Error(
      `non-determinism detected at journal[${slot.seq}]: replay requested ` +
        `${kind}${name ? ` "${name}"` : ""}, but the log recorded ` +
        `${slot.kind}${slot.name ? ` "${slot.name}"` : ""}. The workflow body must issue ` +
        `the same durable operations in the same order on every replay.`
    );
  }
}

function maybeCrash(exec: Execution, stepName: string, when: ArmedCrash["when"]): void {
  const armed = exec.armedCrash;
  if (!armed) return;
  if (armed.when !== when) return;
  if (armed.step !== "*" && armed.step !== stepName) return;
  exec.armedCrash = null; // one-shot
  throw new Crash(
    when === "before-effect"
      ? `worker crashed BEFORE running "${stepName}" — journal intact, no side effect occurred`
      : `worker crashed AFTER running "${stepName}" but BEFORE journaling its result — restart re-runs it (at-least-once)`
  );
}

// Friendly, human-readable descriptions of the real-world effect a step
// causes. This log grows only when a step actually executes.
function synthEffect(name: string, args: unknown[], result: unknown): string {
  switch (name) {
    case "reserveInventory":
      return result === false
        ? `🏭 Inventory check for ${args[0]} → OUT OF STOCK`
        : `🏭 Reserved inventory for ${args[0]}`;
    case "releaseInventory":
      return `↩️ Released reserved inventory for ${args[0]}`;
    case "chargePayment":
      return `💳 Charged ${args[1]}¢ for ${args[0]} → ${result}`;
    case "refundPayment":
      return `↩️ Refunded payment ${args[0]}`;
    case "sendEmail":
      return `✉️ Emailed ${args[0]}: "${args[1]}"`;
    default:
      return `${name}(${args.map((a) => JSON.stringify(a)).join(", ")}) → ${JSON.stringify(result)}`;
  }
}

function labelFor(slot: Slot): string {
  const pretty: Record<string, string> = {
    reserveInventory: "Reserve inventory",
    releaseInventory: "Release inventory (compensate)",
    chargePayment: "Charge payment",
    refundPayment: "Refund payment (compensate)",
    sendEmail: "Email customer",
  };
  if (slot.kind === "step") return pretty[slot.name] ?? slot.name;
  if (slot.kind === "signal") return "Await shipment confirmation";
  if (slot.kind === "timer") return "Durable timer";
  if (slot.kind === "clock") return "Read clock";
  if (slot.kind === "rand") return "Generate id";
  return slot.name;
}
