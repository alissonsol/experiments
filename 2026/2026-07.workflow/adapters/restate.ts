// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// PORTABLE ABSTRACTION — adapters/restate.ts
// Maps DurableContext onto Restate primitives:
//
//   ctx.step(name, ...)      -> restateCtx.run(name, () => fn(...args))
//   ctx.sleep(ms)            -> restateCtx.sleep(ms)
//   ctx.waitForSignal(name)  -> restateCtx.promise(name)  (durable promise)
//   ctx.now() / ctx.uuid()   -> restateCtx.date.now() / restateCtx.rand.uuidv4()
//   signals[]                -> generated shared handlers that resolve
//                               the matching durable promise
//   WorkflowTerminalError    -> restate.TerminalError (no retry)
// ============================================================

import * as restate from "@restatedev/restate-sdk";
import {
  WorkflowContext,
  WorkflowSharedContext,
  TerminalError,
  RestatePromise,
} from "@restatedev/restate-sdk";
import {
  DurableContext,
  StepMap,
  WorkflowDefinition,
  WorkflowTerminalError,
} from "../core/durable";

function makeContext<S extends StepMap>(
  rctx: WorkflowContext,
  steps: S
): DurableContext<S> {
  return {
    workflowId: rctx.key,

    step: (name, ...args) =>
      rctx.run(name, () => steps[name](...args)) as any,

    sleep: async (ms) => { await rctx.sleep(ms); },

    waitForSignal: async <T,>(name: string, timeoutMs?: number) => {
      const signal = rctx.promise<T>(name).get();
      if (timeoutMs === undefined) return await signal;
      return await RestatePromise.race([
        signal,
        rctx.sleep(timeoutMs).map(() => undefined as undefined),
      ]);
    },

    now: async () => new Date(await rctx.date.now()),
    uuid: () => rctx.rand.uuidv4(),
    setStatus: (value) => rctx.set("status", value),
  };
}

/**
 * Turn a portable WorkflowDefinition into a Restate workflow service.
 * Generates one shared handler per declared signal, plus getStatus.
 */
export function toRestateWorkflow<S extends StepMap, I, O>(
  def: WorkflowDefinition<S, I, O>
) {
  const signalHandlers = Object.fromEntries(
    (def.signals ?? []).map((sig) => [
      sig,
      async (ctx: WorkflowSharedContext, payload: unknown) => {
        await ctx.promise(sig).resolve(payload);
      },
    ])
  );

  return restate.workflow({
    name: def.name,
    handlers: {
      run: async (rctx: WorkflowContext, input: I): Promise<O> => {
        try {
          return await def.run(makeContext(rctx, def.steps), input);
        } catch (e) {
          if (e instanceof WorkflowTerminalError) {
            throw new TerminalError(e.message); // stop retrying
          }
          throw e;
        }
      },
      getStatus: async (ctx: WorkflowSharedContext) =>
        (await ctx.get<string>("status")) ?? "in-progress",
      ...signalHandlers,
    },
  });
}

// ---------- Serve it ----------
// import { orderWorkflow } from "../order-workflow";
// restate.serve({ services: [toRestateWorkflow(orderWorkflow)], port: 9080 });
//
// Signal from anywhere:
//   curl localhost:8080/OrderWorkflow/order-42/shipmentConfirmed \
//        --json '{"trackingNumber":"TRK123"}'
