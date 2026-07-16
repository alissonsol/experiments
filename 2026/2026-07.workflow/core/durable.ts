// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// PORTABLE ABSTRACTION — core/durable.ts
//
// The minimal contract both engines can satisfy. Design rules:
//
// 1. Side effects are declared up front as named `steps`, not
//    inlined closures. This is the key to portability: Temporal
//    requires side effects to be registered activities invoked by
//    name through a task queue; Restate merely wraps them in
//    ctx.run(). Named steps satisfy the stricter engine (Temporal)
//    and are trivially mapped to the looser one (Restate).
//
// 2. The workflow body only touches the outside world through
//    DurableContext. Anything nondeterministic (time, randomness,
//    I/O) goes through ctx — never through globals.
//
// 3. Signals and queries are declared in the definition so each
//    adapter can generate the engine-specific plumbing
//    (Restate shared handlers / Temporal defineSignal+setHandler).
// ============================================================

// ---------- Step declarations ----------
// A step is a plain async function: (args) => result. It runs
// OUTSIDE the deterministic workflow body and may do arbitrary I/O.
export type StepFn = (...args: any[]) => Promise<any>;
export type StepMap = Record<string, StepFn>;

export interface RetryPolicy {
  maximumAttempts?: number;   // default: engine default (retry forever/policy)
  nonRetryable?: boolean;     // treat any failure as terminal
}

// ---------- The context your workflow code programs against ----------
export interface DurableContext<S extends StepMap> {
  /** The unique workflow execution ID. */
  workflowId: string;

  /**
   * Execute a declared step durably: run at-least-once, result
   * journaled, replayed (not re-run) on recovery.
   */
  step<K extends keyof S & string>(
    name: K,
    ...args: Parameters<S[K]>
  ): Promise<Awaited<ReturnType<S[K]>>>;

  /** Durable timer. The workflow may suspend for days at no cost. */
  sleep(ms: number): Promise<void>;

  /**
   * Park until an external party delivers the named signal, or
   * timeoutMs elapses (then resolves to undefined).
   */
  waitForSignal<T = unknown>(name: string, timeoutMs?: number): Promise<T | undefined>;

  /** Deterministic clock (journaled / replay-safe). */
  now(): Promise<Date>;

  /** Deterministic UUID (journaled / replay-safe). */
  uuid(): string;

  /** Publish a value readable by external queries. */
  setStatus(value: string): void;
}

/** Throw this for business failures that must NOT be retried. */
export class WorkflowTerminalError extends Error {
  readonly terminal = true;
  constructor(message: string) {
    super(message);
    this.name = "WorkflowTerminalError";
  }
}

// ---------- Workflow definition ----------
export interface WorkflowDefinition<S extends StepMap, I, O> {
  name: string;
  /** Named side-effecting functions. Adapters register these as
   *  Temporal activities or wrap them in Restate ctx.run(). */
  steps: S;
  /** Signal names the workflow may wait on (adapters generate handlers). */
  signals?: string[];
  /** The orchestration logic. Deterministic; talks to the world via ctx. */
  run: (ctx: DurableContext<S>, input: I) => Promise<O>;
}

export function defineWorkflow<S extends StepMap, I, O>(
  def: WorkflowDefinition<S, I, O>
): WorkflowDefinition<S, I, O> {
  return def;
}
