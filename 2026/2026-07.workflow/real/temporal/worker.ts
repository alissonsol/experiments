// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// REAL TEMPORAL (portable path) — worker
//
// Hosts the workflow (bundled from workflows.ts) and registers the
// portable definition's steps AS the Temporal activities. This is the
// abstraction's payoff: `activities: orderWorkflow.steps` — the same
// named side effects the simulation and the Restate adapter use.
//
// Run:  npm run real:temporal:worker   (after `npm run install:real`
//       and starting a Temporal dev server: `temporal server start-dev`)
// ============================================================

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Worker } from "@temporalio/worker";
import { orderWorkflow } from "../../order-workflow.js";

const require = createRequire(import.meta.url);
const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
  const worker = await Worker.create({
    // Temporal bundles this file into the V8 sandbox. Pointing at the
    // .ts source lets the worker's bundler transpile it.
    workflowsPath: join(__dirname, "workflows.ts"),
    activities: orderWorkflow.steps, // <- steps ARE the activities
    taskQueue: "orders",
  });
  console.log("[temporal worker] listening on task queue 'orders' …");
  await worker.run();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
