# Durable Workflows: Restate vs. Temporal, and a Portable Abstraction

Copyright (c) 2026 by Alisson Sol.

One order-fulfillment workflow (reserve inventory → charge payment → wait for a
shipment signal with a 3-day timeout → email the customer, with saga-style
compensation on terminal failure), implemented three ways.

## Quick Start

One command (macOS or Windows). Installs deps on first run, starts the local
server, opens your browser. No Docker, no cloud.

```
pwsh ./run-lab.ps1
```

Windows without pwsh — use Windows PowerShell 5.1:

```
powershell -ExecutionPolicy Bypass -File .\run-lab.ps1
```

Options: `-Port 8080`, `-NoBrowser`, `-Reinstall`.

`run-lab.ps1` is a single cross-platform PowerShell script that runs in
PowerShell 7+ (pwsh, macOS/Windows/Linux) and Windows PowerShell 5.1. It verifies
Node.js on PATH, runs `npm install` on first run, starts the server, and opens
the browser once it answers.

**Prerequisites.** Node 18+ (macOS: `brew install node`) and PowerShell 7+:

- Windows: `winget install --id Microsoft.PowerShell` —
  https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
- macOS: `brew install powershell/tap/powershell` —
  https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos

**Run by hand:**

```
npm install
npm start            # → open http://localhost:3000
npm test             # asserts the durable-execution mechanics end-to-end
npm run typecheck
```

## The three implementations

```
restate-native/     the workflow written directly against the Restate SDK
temporal-native/    the same workflow written directly against the Temporal SDK
portable/           the workflow written ONCE against a small DurableContext
  core/durable.ts       engine-agnostic contract
  order-workflow.ts     business logic, zero engine imports
  adapters/restate.ts   DurableContext -> Restate primitives
  adapters/temporal.ts  DurableContext -> Temporal primitives
```

## The lab

An interactive web UI runs the workflow **side-by-side on both engines at once**:
journal vs event history filling in, durable timers, the shipment signal, saga
compensation, and crashing the worker to prove the journal survives.

Both lanes are driven by the **same** `order-workflow.ts` through the **same**
`DurableContext`; only each engine's own artifacts differ. The engines are
**faithful in-memory simulations** of the durability mechanics both products
share:

- a **durable log** as the single source of truth (Restate journal / Temporal
  event history),
- **deterministic replay** from the top that short-circuits completed work,
- **virtual-clock durable timers** (a 3-day wait fires in one click),
- **at-least-once** step execution (crash mid-step and watch it re-run — steps
  must be idempotent).

Guided demos: *Happy path*, *Shipment timeout → saga*, *Out of stock*, *Crash
before a step (clean recovery)*, *Crash after a step (at-least-once)*.

### The same code on the REAL engines

The simulation is always on. When Temporal and/or Restate are installed, the
**identical** `order-workflow.ts` runs on the real thing via the two adapters.
See **[REAL-ENGINES.md](REAL-ENGINES.md)**, in short:

```
npm run install:real                 # optional SDKs (only for real mode)

# Real Temporal (3 terminals)
temporal server start-dev            # Web UI localhost:8233, gRPC localhost:7233
npm run real:temporal:worker
npm run real:temporal:client

# Real Restate (2 terminals)
restate-server
npm run real:restate:serve           # serves on 9080
# then register once, targeting the service port:
#   restate deployments register http://localhost:9080
# invoke handlers over the ingress on 8080:
#   curl localhost:8080/OrderWorkflow/order-42/run
```

### Lab layout

```
run-lab.ps1            one-command launcher (PowerShell 7+ / 5.1)
core/durable.ts        the DurableContext contract (shared by sim + real)
order-workflow.ts      the business logic — runs on every backend, unchanged
sim/                   the two faithful in-memory engines
  engine.ts              one replay executor implementing DurableContext
  profiles.ts            Restate-journal vs Temporal-event-history rendering
server/                zero-dependency HTTP + SSE server driving side-by-side runs
public/                the vanilla-JS front end (no build step)
adapters/              DurableContext -> real Restate / real Temporal
real/                  runnable entrypoints for the portable code on real engines
test/engine.test.ts    end-to-end assertions of the durability mechanics
```

## How the two engines differ

Both give the same guarantee — durable execution: each step's result is
journaled, so after a crash the workflow resumes where it left off. They differ
in how you get there.

**Architecture.** Temporal is a server cluster (or Temporal Cloud) plus workers
that long-poll task queues; the server owns event history, timers, and retries,
and you need the SDK client (gRPC) to start, signal, or query. Restate is a
single lightweight broker that proxies invocations to your services; every
handler is addressable over plain HTTP, and services can suspend between steps.

**Where side effects live** — the biggest difference. Temporal requires side
effects to be *activities*: functions registered on a worker, invoked by name
through the task queue, with the workflow body in a deterministic sandbox that
bans I/O, `Date.now()`, and `Math.random()`. Restate inlines them as
`ctx.run("name", () => ...)` — lower ceremony, but determinism is on you.

**Signals.** Temporal: `defineSignal` + `setHandler` + `condition(fn, timeout)`.
Restate: durable promises — `ctx.promise("name")` awaited in `run`, resolved by
any handler of the same workflow, callable over HTTP.

**Failure.** Both retry transient errors and treat one error type as terminal:
`ApplicationFailure.nonRetryable` (Temporal), `TerminalError` (Restate). Sagas
look identical (accumulate undo lambdas, run in reverse on failure).

**Same concept, different names:**

| Concept                    | Restate                          | Temporal                              |
|----------------------------|----------------------------------|---------------------------------------|
| Durable step               | `ctx.run(name, fn)`              | activity via `proxyActivities()`       |
| Durable timer              | `ctx.sleep(ms)`                  | `sleep(ms)` (workflow API)             |
| External event             | durable promise `ctx.promise()`  | signal + `condition()`                 |
| Read-only introspection    | shared handler reading K/V state | query handler                          |
| Don't-retry error          | `TerminalError`                  | `ApplicationFailure.nonRetryable`      |
| Replay-safe time / random  | `ctx.date` / `ctx.rand`          | patched `Date.now()` / `uuid4()`       |
| Identity / dedup           | workflow key (`ctx.key`)         | `workflowId`                           |
| Invocation                 | plain HTTP to any handler        | SDK client over gRPC + task queue      |

## The abstraction layer

`core/durable.ts` defines the smallest contract both engines satisfy (simplified;
the real signatures are generic):

```ts
interface DurableContext<S> {
  workflowId: string;
  step(name, ...args): Promise<Result>;   // durable side effect
  sleep(ms): Promise<void>;               // durable timer
  waitForSignal(name, timeoutMs?);        // external event
  now(): Promise<Date>;  uuid(): string;  // deterministic sources
  setStatus(v: string): void;             // externally queryable state
}
```

The key design decision: **side effects are declared up front as named `steps`,
not inlined closures.** Temporal is the stricter engine — activities must be
registered by name, and closures can't cross the task queue. Named steps satisfy
Temporal directly (`activities: def.steps`) and map trivially onto Restate
(`ctx.run(name, () => steps[name](...args))`). Target the strictest engine and
the rest fall out free.

The rest is mechanical mapping, in the two adapters: `waitForSignal` becomes a
durable promise (Restate) or a signal handler feeding `condition()` (Temporal);
`WorkflowTerminalError` translates to each engine's terminal error;
`now()`/`uuid()` route to each engine's replay-safe sources.

## Migrating old code to new code

Strangler-style migration in either direction. Suppose you have native Temporal
code:

**1. Extract steps.** Activities are already named functions — they become the
`steps` map almost verbatim. From Restate, hoist each inline `ctx.run(name,
closure)` body into a named function; the journal name becomes the step name.

**2. Rewrite the body against `DurableContext`.** Mechanical substitutions:
`acts.chargePayment(...)` → `ctx.step("chargePayment", ...)`;
`condition(() => x, t)` → `ctx.waitForSignal(name, t)`;
`ApplicationFailure.nonRetryable` → `WorkflowTerminalError`. Control flow —
branches, loops, saga compensation — is untouched.

**3. Run the portable definition on the OLD engine first.** Wrap it with that
engine's adapter and deploy. Behavior should be identical; existing tests and
production traffic validate the refactor before any infra change — the critical
de-risking step.

**4. Cut over new executions.** Route *newly started* workflow IDs to the new
engine (feature flag or ID-hash split) while the old engine drains its in-flight
executions.

**5. Never migrate in-flight state.** Journals and event histories are not
interchangeable. Long-running workflows either drain naturally, or you checkpoint
them at a business boundary (e.g. "payment charged, awaiting shipment") and start
a fresh workflow on the new engine from that checkpoint, with idempotent steps.

**6. Decommission** the old engine once its last execution finishes.

Adding a backend (a Postgres journal for tests, another vendor) means one more
adapter, not touching business logic. Keep it minimal — every leaked
engine-specific feature (Temporal child workflows, `continueAsNew`, Restate
virtual objects) is portability debt.

## Honest caveats

- An abstraction is a least-common-denominator. If you need Temporal's
  `continueAsNew`/child-workflow patterns or Restate's virtual objects, extend
  the interface (on both sides) or drop to native code for those workflows.
- Retry-policy knobs differ in shape; the abstraction pins a sane default —
  decide where per-step overrides belong.
- Determinism rules apply inside `run()`: no direct I/O, no `Date.now()`, no
  `Math.random()` — always go through `ctx`. Restate won't stop you at compile
  time; Temporal's sandbox will.
