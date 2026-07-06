// ============================================================
// SIMULATION — engine profiles (presentation only)
//
// The durability MECHANICS (durable log, deterministic replay,
// timers, at-least-once) are genuinely identical across engines and
// live in sim/engine.ts. What actually differs between Restate and
// Temporal is the PROGRAMMING-MODEL SURFACE and TOPOLOGY:
//
//   * where side effects run  — Restate: inline ctx.run() closures;
//                               Temporal: activities dispatched to a
//                               task queue and run by workers.
//   * external events         — Restate: durable promises;
//                               Temporal: signals + condition().
//   * queryable state         — Restate: ctx.set() is JOURNALED;
//                               Temporal: a workflow variable, NOT in
//                               history (queries aren't journaled).
//   * how you invoke it       — Restate: plain HTTP to any handler;
//                               Temporal: SDK client over gRPC + queue.
//
// A profile renders the same underlying slot list either as a Restate
// journal or as a Temporal event history, so the side-by-side view
// shows each engine's characteristic artifacts for the same actions.
// ============================================================

import type { RenderedEntry, Slot } from "./types.js";
import type { Execution } from "./engine.js";

export interface EngineProfile {
  id: "restate" | "temporal";
  label: string;
  logLabel: string;
  invocationNote: string;
  mechanicsNote: string;
  virtualClockLabel(ms: number): string;
  render(exec: Execution): RenderedEntry[];
}

function kebab(s: string): string {
  return s.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();
}

function fmtDuration(ms: number): string {
  if (ms % 86_400_000 === 0) return `${ms / 86_400_000}d`;
  if (ms % 3_600_000 === 0) return `${ms / 3_600_000}h`;
  if (ms % 60_000 === 0) return `${ms / 60_000}m`;
  if (ms % 1000 === 0) return `${ms / 1000}s`;
  return `${ms}ms`;
}

function fmtResult(v: unknown): string {
  if (v === undefined) return "undefined";
  if (v === null) return "null";
  if (typeof v === "string") return v;
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

function orderSummary(exec: Execution): string {
  const o = exec.input;
  const items = o.items.map((i: any) => `${i.qty}×${i.sku}`).join(", ");
  return `customer=${o.customerId}, items=[${items}], amount=${o.amountCents}¢`;
}

// A running step slot that has already run its side effect at least once
// but is not settled means the worker was lost mid-flight.
function stepStateLabel(slot: Slot): "pending" | "ok" | "fail" | "wait" {
  if (slot.status === "completed") return "ok";
  if (slot.status === "failed") return "fail";
  return "pending";
}

// ------------------------------------------------------------
// RESTATE profile — renders the durable log as a Restate journal.
// ------------------------------------------------------------
export const restateProfile: EngineProfile = {
  id: "restate",
  label: "Restate",
  logLabel: "Journal",
  invocationNote:
    'Every handler is addressable over plain HTTP:  curl localhost:8080/OrderWorkflow/{id}/run',
  mechanicsNote:
    "Side effects run INLINE as ctx.run() closures. Externals are durable promises. ctx.set() state is journaled.",
  virtualClockLabel: (ms) => `virtual clock: T+${fmtDuration(ms || 0)}`,

  render(exec) {
    const out: RenderedEntry[] = [];
    let id = 0;
    out.push({
      id: id++,
      type: "Input",
      summary: `run(order) invoked  ·  key="${exec.id}"`,
      detail: orderSummary(exec),
      group: -1,
      state: "ok",
    });

    for (const slot of exec.journal) {
      const replayed = exec.lastRunReplayed.has(slot.seq);
      const tag = replayed ? "  (replayed from journal)" : "";
      if (slot.kind === "step") {
        const retry = (slot.attempts ?? 1) > 1 ? `  ⟳ attempt ${slot.attempts}` : "";
        out.push({
          id: id++,
          type: "run",
          summary: `ctx.run("${kebab(slot.name)}")${retry}`,
          detail:
            slot.status === "completed"
              ? `→ ${fmtResult(slot.result)}${tag}`
              : slot.status === "failed"
              ? `✗ ${slot.error}`
              : "executing side effect…",
          group: slot.seq,
          state: stepStateLabel(slot),
        });
      } else if (slot.kind === "timer") {
        const dur = (slot.fireAtVc ?? 0) - (slot.startedAtVc ?? 0);
        out.push({
          id: id++,
          type: "sleep",
          summary: `ctx.sleep(${fmtDuration(dur)})`,
          detail: slot.status === "fired" ? `timer elapsed${tag}` : "durable timer pending…",
          group: slot.seq,
          state: slot.status === "fired" ? "fired" : "wait",
        });
      } else if (slot.kind === "signal") {
        const dur = slot.fireAtVc != null ? (slot.fireAtVc - (slot.startedAtVc ?? 0)) : null;
        out.push({
          id: id++,
          type: "promise",
          summary: `ctx.promise("${slot.name}").get()${dur != null ? `  ‖ sleep(${fmtDuration(dur)})` : ""}`,
          detail:
            slot.status === "signaled"
              ? `resolved → ${fmtResult(slot.result)}${tag}`
              : slot.status === "timedout"
              ? `sleep won the race → undefined (timeout)${tag}`
              : "awaiting durable promise…",
          group: slot.seq,
          state:
            slot.status === "signaled" ? "ok" : slot.status === "timedout" ? "fired" : "wait",
        });
      } else if (slot.kind === "clock" || slot.kind === "rand") {
        out.push({
          id: id++,
          type: slot.kind === "clock" ? "ctx.date.now" : "ctx.rand.uuidv4",
          summary: slot.kind === "clock" ? "ctx.date.now()" : "ctx.rand.uuidv4()",
          detail: `→ ${fmtResult(slot.result)}`,
          group: slot.seq,
          state: "ok",
        });
      }
    }

    // Restate journals K/V state writes.
    for (const w of exec.stateLog) {
      out.push({
        id: id++,
        type: "set-state",
        summary: `ctx.set("${w.key}", "${w.value}")`,
        detail: "journaled K/V state (readable via getStatus shared handler)",
        group: -2,
        state: "ok",
      });
    }

    if (exec.status === "completed" || exec.status === "failed") {
      out.push({
        id: id++,
        type: "Output",
        summary: "run() returned",
        detail: fmtResult(exec.result),
        group: -3,
        state: exec.status === "failed" ? "fail" : "ok",
      });
    }
    return out;
  },
};

// ------------------------------------------------------------
// TEMPORAL profile — renders the durable log as an event history.
// ------------------------------------------------------------
export const temporalProfile: EngineProfile = {
  id: "temporal",
  label: "Temporal",
  logLabel: "Event History",
  invocationNote:
    "Start / signal / query go through the SDK client over gRPC:  client.workflow.start(...), handle.signal(...)",
  mechanicsNote:
    "Side effects are ACTIVITIES dispatched to a task queue and run by workers. Externals are signals + condition(). Query state is NOT journaled.",
  virtualClockLabel: (ms) => `event time: +${fmtDuration(ms || 0)}`,

  render(exec) {
    const out: RenderedEntry[] = [];
    let id = 1; // Temporal event ids are 1-based
    out.push({
      id: id++,
      type: "WorkflowExecutionStarted",
      summary: `workflowId="${exec.id}", taskQueue="orders"`,
      detail: orderSummary(exec),
      group: -1,
      state: "ok",
    });

    for (const slot of exec.journal) {
      const replayed = exec.lastRunReplayed.has(slot.seq);
      const tag = replayed ? "  (replayed from history)" : "";
      if (slot.kind === "step") {
        out.push({
          id: id++,
          type: "ActivityTaskScheduled",
          summary: `activityType="${slot.name}"  → task queue`,
          detail: `args: ${fmtResult(slot.args ?? [])}`,
          group: slot.seq,
          state: "ok",
        });
        out.push({
          id: id++,
          type: "ActivityTaskStarted",
          summary:
            (slot.attempts ?? 1) > 1
              ? `worker picked up task  ⟳ attempt ${slot.attempts}`
              : "worker picked up task",
          detail:
            slot.status !== "completed"
              ? "worker lost before completion — activity will be retried (at-least-once)"
              : undefined,
          group: slot.seq,
          state: slot.status === "completed" ? "ok" : "pending",
        });
        if (slot.status === "completed") {
          out.push({
            id: id++,
            type: "ActivityTaskCompleted",
            summary: `activityType="${slot.name}"`,
            detail: `result → ${fmtResult(slot.result)}${tag}`,
            group: slot.seq,
            state: "ok",
          });
        }
      } else if (slot.kind === "timer") {
        const dur = (slot.fireAtVc ?? 0) - (slot.startedAtVc ?? 0);
        out.push({
          id: id++,
          type: "TimerStarted",
          summary: `sleep(${fmtDuration(dur)})`,
          detail: undefined,
          group: slot.seq,
          state: "ok",
        });
        if (slot.status === "fired") {
          out.push({
            id: id++,
            type: "TimerFired",
            summary: "durable timer elapsed",
            detail: tag || undefined,
            group: slot.seq,
            state: "fired",
          });
        }
      } else if (slot.kind === "signal") {
        // condition(() => signal, "3 days") arms a timer, then either a
        // signal event satisfies it or the timer fires (timeout).
        if (slot.fireAtVc != null) {
          const dur = slot.fireAtVc - (slot.startedAtVc ?? 0);
          out.push({
            id: id++,
            type: "TimerStarted",
            summary: `condition timeout: sleep(${fmtDuration(dur)})`,
            group: slot.seq,
            state: "ok",
          });
        }
        if (slot.status === "signaled") {
          out.push({
            id: id++,
            type: "WorkflowExecutionSignaled",
            summary: `signalName="${slot.name}"`,
            detail: `payload: ${fmtResult(slot.result)} — condition() satisfied${tag}`,
            group: slot.seq,
            state: "ok",
          });
        } else if (slot.status === "timedout") {
          out.push({
            id: id++,
            type: "TimerFired",
            summary: "condition timeout elapsed",
            detail: `condition() returned false → timeout${tag}`,
            group: slot.seq,
            state: "fired",
          });
        }
      } else if (slot.kind === "clock" || slot.kind === "rand") {
        out.push({
          id: id++,
          type: "MarkerRecorded",
          summary: slot.kind === "clock" ? 'markerName="Date.now"' : 'markerName="uuid4"',
          detail: `→ ${fmtResult(slot.result)} (replay-safe via marker)`,
          group: slot.seq,
          state: "ok",
        });
      }
    }

    // NOTE: setStatus() in Temporal is a plain workflow variable read by a
    // query handler — it is NOT written to event history. So, unlike the
    // Restate journal, no set-state events appear here.

    if (exec.status === "completed" || exec.status === "failed") {
      out.push({
        id: id++,
        type: "WorkflowExecutionCompleted",
        summary: "workflow function returned",
        detail: fmtResult(exec.result),
        group: -3,
        state: exec.status === "failed" ? "fail" : "ok",
      });
    }
    return out;
  },
};

export const PROFILES: Record<"restate" | "temporal", EngineProfile> = {
  restate: restateProfile,
  temporal: temporalProfile,
};
