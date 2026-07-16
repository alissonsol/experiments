// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// PORTABLE ABSTRACTION — adapters/temporal.ts
// Maps DurableContext onto Temporal primitives:
//
//   def.steps                -> registered as activities on the worker
//   ctx.step(name, ...)      -> proxyActivities()[name](...args)
//   ctx.sleep(ms)            -> workflow.sleep(ms)
//   ctx.waitForSignal(name)  -> defineSignal + setHandler + condition()
//   ctx.now() / ctx.uuid()   -> replay-safe Date.now() / uuid4() inside
//                               the workflow sandbox
//   WorkflowTerminalError    -> ApplicationFailure.nonRetryable
//
// Temporal's sandbox forces a two-file split: this module has a
// workflow-side factory (deterministic code only) and a worker-side
// helper (registers activities). Keep them in separate bundles in a
// real project; shown together here for readability.
// ============================================================

// ----------------------- workflow side -----------------------
// (bundled by the worker via workflowsPath; no Node APIs allowed)

import {
  proxyActivities,
  defineSignal,
  defineQuery,
  setHandler,
  condition,
  sleep as wfSleep,
  uuid4,
  workflowInfo,
  ApplicationFailure,
} from "@temporalio/workflow";
import {
  DurableContext,
  StepMap,
  WorkflowDefinition,
  WorkflowTerminalError,
} from "../core/durable";

export const statusQuery = defineQuery<string>("getStatus");

/**
 * Produce a Temporal workflow function from a portable definition.
 * Export the result from your workflows.ts so the worker can bundle it:
 *
 *   // workflows.ts
 *   import { orderWorkflow } from "../order-workflow";
 *   export const OrderWorkflow = toTemporalWorkflow(orderWorkflow);
 */
export function toTemporalWorkflow<S extends StepMap, I, O>(
  def: WorkflowDefinition<S, I, O>
): (input: I) => Promise<O> {
  return async function portableWorkflow(input: I): Promise<O> {
    // Activities are invoked BY NAME over the task queue — the step
    // implementations live on the worker, not in this sandbox.
    const acts = proxyActivities<S>({
      startToCloseTimeout: "5 minutes",
      retry: { maximumAttempts: 5 },
    });

    // Signal mailbox: one slot per declared signal name.
    const inbox = new Map<string, unknown[]>();
    for (const sig of def.signals ?? []) {
      inbox.set(sig, []);
      setHandler(defineSignal<[unknown]>(sig), (payload) => {
        inbox.get(sig)!.push(payload);
      });
    }

    let status = "in-progress";
    setHandler(statusQuery, () => status);

    const ctx: DurableContext<S> = {
      workflowId: workflowInfo().workflowId,

      step: (name, ...args) => (acts[name] as any)(...args),

      sleep: (ms) => wfSleep(ms),

      waitForSignal: async <T,>(name: string, timeoutMs?: number) => {
        const queue = inbox.get(name);
        if (!queue) throw new Error(`signal "${name}" not declared in definition`);
        const arrived =
          timeoutMs === undefined
            ? (await condition(() => queue.length > 0), true)
            : await condition(() => queue.length > 0, timeoutMs);
        return arrived ? (queue.shift() as T) : undefined;
      },

      // Replay-safe inside the sandbox: Temporal patches Date/random.
      now: async () => new Date(Date.now()),
      uuid: () => uuid4(),
      setStatus: (value) => { status = value; },
    };

    try {
      return await def.run(ctx, input);
    } catch (e) {
      if (e instanceof WorkflowTerminalError) {
        throw ApplicationFailure.nonRetryable(e.message);
      }
      throw e;
    }
  };
}

// ----------------------- worker side -----------------------
// (plain Node; give the steps to Worker.create as activities)
//
//   // worker.ts
//   import { Worker } from "@temporalio/worker";
//   import { orderWorkflow } from "../order-workflow";
//
//   const worker = await Worker.create({
//     workflowsPath: require.resolve("./workflows"),
//     activities: orderWorkflow.steps,        // <- steps ARE the activities
//     taskQueue: "orders",
//   });
//   await worker.run();
//
// Signal from a client:
//   const handle = client.workflow.getHandle("order-42");
//   await handle.signal("shipmentConfirmed", { trackingNumber: "TRK123" });
