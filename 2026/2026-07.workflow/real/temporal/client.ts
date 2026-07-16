// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// REAL TEMPORAL (portable path) — client
//
// Starts the workflow, queries its status, sends the shipment signal,
// and awaits the result — all over the SDK client (gRPC), the way
// Temporal requires (contrast with Restate's plain-HTTP handlers).
//
// Run (in a second terminal, worker already running):
//   npm run real:temporal:client
// ============================================================

import { Connection, Client } from "@temporalio/client";
import { OrderWorkflow, statusQuery } from "./workflows.js";

async function main() {
  const connection = await Connection.connect({ address: "localhost:7233" });
  const client = new Client({ connection });

  const orderId = `order-${Math.floor(Math.random() * 9000 + 1000)}`;
  const order = { customerId: "c1", items: [{ sku: "widget", qty: 2 }], amountCents: 4999 };

  const handle = await client.workflow.start(OrderWorkflow, {
    workflowId: orderId,
    taskQueue: "orders",
    args: [order], // the portable workflow reads its id from ctx.workflowId
  });
  console.log(`[client] started ${orderId}`);
  console.log(`[client] status query → ${await handle.query(statusQuery)}`);

  // The warehouse confirms shipment (signal name comes from the
  // definition's `signals: ["shipmentConfirmed"]`).
  await handle.signal("shipmentConfirmed", { trackingNumber: "TRK123" });
  console.log("[client] sent shipmentConfirmed signal");

  const result = await handle.result();
  console.log("[client] result →", JSON.stringify(result));
  await connection.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
