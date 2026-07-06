// ============================================================
// SERVER — reference metadata for the UI
//
// The concept table and the guided presets. Kept server-side so the
// frontend stays a thin rendering layer and the "teaching" content
// has one source of truth (mirrors README.md).
// ============================================================

export interface ConceptRow {
  concept: string;
  restate: string;
  temporal: string;
  usedHere: boolean; // exercised by the order workflow
}

export interface CommandStep {
  action: "start" | "signal" | "advance" | "restart" | "arm-crash" | "clear-crash";
  target?: "both" | "restate" | "temporal";
  label: string; // human description shown while stepping
  ms?: number;
  step?: string;
  when?: "before-effect" | "after-effect";
  payload?: unknown;
  note?: string; // what to watch for
}

export interface Preset {
  id: string;
  title: string;
  blurb: string;
  faults?: { outOfStock?: boolean };
  steps: CommandStep[];
}

const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;

export const META = {
  workflow: {
    name: "OrderWorkflow",
    summary:
      "reserve inventory → charge payment → wait for a shipment signal (3-day timeout) → email the customer, with saga-style compensation on terminal failure.",
    steps: ["reserveInventory", "chargePayment", "waitForSignal(shipmentConfirmed)", "sendEmail"],
    compensations: ["releaseInventory", "refundPayment"],
  },

  conceptTable: <ConceptRow[]>[
    {
      concept: "Durable step",
      restate: "ctx.run(name, fn)  — inline closure",
      temporal: "activity via proxyActivities() — task queue",
      usedHere: true,
    },
    {
      concept: "Durable timer",
      restate: "ctx.sleep(ms)",
      temporal: "sleep(ms) (workflow API)",
      usedHere: true,
    },
    {
      concept: "External event",
      restate: "durable promise ctx.promise()",
      temporal: "signal + condition()",
      usedHere: true,
    },
    {
      concept: "Read-only introspection",
      restate: "shared handler reading K/V state",
      temporal: "query handler",
      usedHere: true,
    },
    {
      concept: "Don't-retry error",
      restate: "TerminalError",
      temporal: "ApplicationFailure.nonRetryable",
      usedHere: true,
    },
    {
      concept: "Queryable state write",
      restate: "ctx.set() — journaled",
      temporal: "workflow variable — NOT in history",
      usedHere: true,
    },
    {
      concept: "Replay-safe time / random",
      restate: "ctx.date / ctx.rand",
      temporal: "patched Date.now() / uuid4()",
      usedHere: false,
    },
    {
      concept: "Identity / dedup",
      restate: "workflow key (ctx.key)",
      temporal: "workflowId",
      usedHere: true,
    },
    {
      concept: "Invocation",
      restate: "plain HTTP to any handler",
      temporal: "SDK client over gRPC + task queue",
      usedHere: true,
    },
    {
      concept: "Where side effects run",
      restate: "inline in the workflow body",
      temporal: "separate activity workers",
      usedHere: true,
    },
  ],

  presets: <Preset[]>[
    {
      id: "happy",
      title: "Happy path",
      blurb:
        "The warehouse confirms shipment before the deadline. Both engines complete identically; watch the journal vs the event history fill in.",
      steps: [
        { action: "start", target: "both", label: "Start the order on both engines", note: "Both park at the shipment wait — a durable suspension that costs nothing." },
        {
          action: "signal",
          target: "both",
          label: "Warehouse confirms shipment",
          payload: { trackingNumber: "TRK123" },
          note: "Restate resolves a durable promise; Temporal delivers a signal that satisfies condition().",
        },
      ],
    },
    {
      id: "timeout",
      title: "Shipment timeout → saga",
      blurb:
        "No confirmation arrives. Advance the virtual clock past the 3-day deadline; the timeout triggers saga compensation (refund + release) in reverse order.",
      steps: [
        { action: "start", target: "both", label: "Start the order on both engines" },
        {
          action: "advance",
          target: "both",
          ms: THREE_DAYS_MS,
          label: "Advance the virtual clock 3 days",
          note: "The durable timer fires; waitForSignal returns undefined → WorkflowTerminalError → compensations run in reverse.",
        },
      ],
    },
    {
      id: "oos",
      title: "Out of stock (terminal, no compensation)",
      blurb:
        "Inventory reports out-of-stock. The workflow fails terminally before charging — there is nothing to compensate, so the saga stack is empty.",
      faults: { outOfStock: true },
      steps: [
        {
          action: "start",
          target: "both",
          label: "Start the order (inventory is out of stock)",
          note: "reserveInventory → false → TerminalError. No payment, no compensation. Failed result returned.",
        },
      ],
    },
    {
      id: "crash-clean",
      title: "Crash BEFORE a step (clean recovery)",
      blurb:
        "Kill the worker just before it charges payment. The journal is intact and no charge happened; restarting replays completed steps and runs the charge cleanly — exactly once.",
      steps: [
        {
          action: "arm-crash",
          target: "both",
          step: "chargePayment",
          when: "before-effect",
          label: "Arm: crash before chargePayment runs",
        },
        {
          action: "start",
          target: "both",
          label: "Start — worker dies before charging",
          note: "Status → crashed. reserveInventory is journaled; no charge occurred.",
        },
        {
          action: "restart",
          target: "both",
          label: "Restart the worker",
          note: "reserveInventory is REPLAYED (not re-run — side-effect log unchanged); chargePayment runs once. Durable execution.",
        },
      ],
    },
    {
      id: "crash-atleastonce",
      title: "Crash AFTER a step (at-least-once)",
      blurb:
        "Kill the worker after payment runs but before its result is journaled. On restart the engine has no record of the charge, so it charges AGAIN — the visible reason durable steps must be idempotent.",
      steps: [
        {
          action: "arm-crash",
          target: "both",
          step: "chargePayment",
          when: "after-effect",
          label: "Arm: crash after chargePayment's side effect, before journaling",
        },
        {
          action: "start",
          target: "both",
          label: "Start — payment fires, then the worker dies",
          note: "Side-effect log shows ONE charge; the journal has no completed result for it.",
        },
        {
          action: "restart",
          target: "both",
          label: "Restart the worker",
          note: "chargePayment runs a SECOND time (attempt 2). Side-effect log shows TWO charges. Make steps idempotent!",
        },
        {
          action: "signal",
          target: "both",
          payload: { trackingNumber: "TRK123" },
          label: "Confirm shipment to finish the order",
        },
      ],
    },
  ],

  notes: {
    faithful:
      "The durability mechanics shown here — a durable log as source of truth, deterministic replay from the top, virtual-clock timers, and at-least-once step execution — are genuinely identical across Restate and Temporal, and are modeled faithfully by these simulations. What differs (and what the two columns highlight) is the programming-model surface and topology: inline ctx.run() closures vs activities on a task queue, durable promises vs signals + condition(), journaled ctx.set() state vs an in-memory query variable, and plain HTTP vs a gRPC SDK client.",
    portable:
      "Both columns are driven by the SAME order-workflow.ts business logic through the SAME DurableContext contract. Adding a third backend would mean writing one more adapter — not touching business logic.",
  },
} as const;
