// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// NATIVE TEMPORAL IMPLEMENTATION — worker.ts
// Temporal separates "where code runs" (workers, this file) from
// "who orchestrates" (the Temporal server). Workers long-poll the
// task queue; the server owns history, timers, and retries.
// ============================================================

import { Worker } from "@temporalio/worker";
import * as activities from "./activities";

async function main() {
  const worker = await Worker.create({
    workflowsPath: require.resolve("./workflows"), // bundled into the sandbox
    activities,
    taskQueue: "orders",
  });
  await worker.run();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
