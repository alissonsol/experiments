# Running on the REAL engines (optional)

The lab's live side-by-side view is a **faithful simulation** — always on, needs
nothing installed, and models the durability mechanics both products share.

This document covers the other half: running the **exact same**
`order-workflow.ts` on the **real** Temporal and Restate, locally. None of it is
required for the simulated lab. The point is to prove the abstraction
end-to-end — the business logic doesn't change, only the adapter does.

The lab detects whether each engine is available and shows these commands in its
**Real engines** panel; re-check after installing via the panel's ↻ button.

```
npm run install:real
```

installs the optional SDKs: `@temporalio/{worker,client,workflow,activity}` and
`@restatedev/restate-sdk`. You also need each engine's server binary (below).

---

## Temporal

**What you need**

- The optional SDKs (`npm run install:real`).
- The Temporal CLI (bundles a local dev server + Web UI).
  - macOS: `brew install temporal`
  - Windows/Linux: <https://docs.temporal.io/cli#install>

**Run it** (three terminals)

```bash
# 1. local server + Web UI (http://localhost:8233)
temporal server start-dev

# 2. worker — hosts the workflow, registers orderWorkflow.steps as activities
npm run real:temporal:worker

# 3. client — starts an order, queries status, signals shipment, awaits it
npm run real:temporal:client
```

The workflow starts, parks on the shipment wait, gets the signal, and completes.
The Web UI at <http://localhost:8233> shows the **real event history** — the same
`ActivityTaskScheduled/Started/Completed`, `TimerStarted`,
`WorkflowExecutionSignaled`, `WorkflowExecutionCompleted` events the sim renders.

**How the portable code maps** — `real/temporal/workflows.ts` wraps it with
`toTemporalWorkflow(orderWorkflow)` ([adapters/temporal.ts](adapters/temporal.ts));
the worker passes `activities: orderWorkflow.steps`. [order-workflow.ts](order-workflow.ts)
is untouched.

**Note on time.** Real timers take real time, so the 3-day shipment timeout is a
real 3 days here. To exercise timeout/saga on a controllable clock against a *real*
Temporal core, use the time-skipping test server (`@temporalio/testing` →
`TestWorkflowEnvironment.createTimeSkipping()`); the sim gives you that out of the box.

---

## Restate

**What you need**

- The optional SDK (`npm run install:real`).
- `restate-server` and the `restate` CLI.
  - `npm i -g @restatedev/restate-server @restatedev/restate`
  - or <https://docs.restate.dev/get_started/quickstart>

**Run it** (two terminals)

```bash
# 1. the broker (holds the journal, proxies invocations)
restate-server

# 2. serve the OrderWorkflow handlers (from the portable definition)
npm run real:restate:serve

# register the deployment once
restate deployments register http://localhost:9080
```

**Drive it over plain HTTP** — no SDK client; every handler is addressable:

```bash
# start order-42
curl localhost:8080/OrderWorkflow/order-42/run \
  --json '{"customerId":"c1","items":[{"sku":"widget","qty":2}],"amountCents":4999}'

# read status while it runs (shared handler over K/V state)
curl localhost:8080/OrderWorkflow/order-42/getStatus

# resolve the durable promise (the shipment signal)
curl localhost:8080/OrderWorkflow/order-42/shipmentConfirmed \
  --json '{"trackingNumber":"TRK123"}'
```

Inspect the **real journal** with `restate invocations list` and
`restate invocations describe <id>`, or SQL over `sys_journal`.

**How the portable code maps** — `real/restate/serve.ts` calls
`toRestateWorkflow(orderWorkflow)` ([adapters/restate.ts](adapters/restate.ts)),
which turns `ctx.step` into `ctx.run`, `ctx.waitForSignal` into a durable promise,
and adds a shared handler per declared signal plus `getStatus`. Same
[order-workflow.ts](order-workflow.ts).

---

## Native, for contrast

`temporal-native/` and `restate-native/` hold the same workflow written **directly**
against each SDK (no abstraction), so you can diff the portable version against the
hand-written one. Same run steps (worker/serve + client/HTTP).

## What doesn't cross over

Two lab controls are simulation-only, with no real-engine equivalent by design:

- **Inject crash** (before/after a step's side effect) — the sim pauses at an exact
  point to *show* at-least-once. On a real engine you'd kill the worker process; the
  guarantee is identical, but the precise injection point isn't an API.
- **Restart worker / advance virtual clock** — real workers recover automatically and
  real time advances on its own (or via the time-skipping test server for Temporal).
