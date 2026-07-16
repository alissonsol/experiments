// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// REAL TEMPORAL (portable path) — workflow bundle
//
// This is what runs inside Temporal's deterministic sandbox. It takes
// the SAME portable business logic (order-workflow.ts) and wraps it
// with the Temporal adapter — no business logic is duplicated. The
// worker (worker.ts) registers orderWorkflow.steps as the activities.
//
// Requires the optional Temporal SDK + a local Temporal dev server.
// See REAL-ENGINES.md for setup. Not needed for the simulated lab.
// ============================================================

import { toTemporalWorkflow, statusQuery } from "../../adapters/temporal.js";
import { orderWorkflow } from "../../order-workflow.js";

// The bundled, sandbox-safe workflow function. Exported so the worker
// can pick it up via workflowsPath, and the client can reference it.
export const OrderWorkflow = toTemporalWorkflow(orderWorkflow);

// Re-export the query so the client can read status.
export { statusQuery };
