// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// NATIVE TEMPORAL IMPLEMENTATION — client.ts
// Starting, signaling, and querying require the Temporal SDK
// client (gRPC to the server) — unlike Restate, where every
// handler is directly addressable over plain HTTP.
// ============================================================

import { Connection, Client } from "@temporalio/client";
import { orderWorkflow, shipmentConfirmedSignal, statusQuery } from "./workflows";

async function main() {
  const connection = await Connection.connect({ address: "localhost:7233" });
  const client = new Client({ connection });

  const orderId = "order-42";
  const handle = await client.workflow.start(orderWorkflow, {
    workflowId: orderId,
    taskQueue: "orders",
    args: [orderId, {
      customerId: "c1",
      items: [{ sku: "widget", qty: 2 }],
      amountCents: 4999,
    }],
  });

  console.log("status:", await handle.query(statusQuery));

  // Later, the warehouse system signals shipment:
  await handle.signal(shipmentConfirmedSignal, { trackingNumber: "TRK123" });

  console.log("result:", await handle.result());
}

main().catch(console.error);
