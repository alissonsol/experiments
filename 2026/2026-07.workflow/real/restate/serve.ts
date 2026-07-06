// ============================================================
// REAL RESTATE (portable path) — service host
//
// Serves the SAME portable order-workflow.ts as a Restate workflow
// service, via the Restate adapter. The adapter generates one shared
// handler per declared signal plus getStatus. No business logic is
// duplicated.
//
// Run:  npm run real:restate:serve
//       (after `npm run install:real` and starting the broker with
//        `restate-server`, then registering: `restate deployments
//        register http://localhost:9080`)
// ============================================================

import * as restate from "@restatedev/restate-sdk";
import { toRestateWorkflow } from "../../adapters/restate.js";
import { orderWorkflow } from "../../order-workflow.js";

restate.serve({
  services: [toRestateWorkflow(orderWorkflow)],
  port: Number(process.env.RESTATE_SERVICE_PORT ?? 9080),
});

console.log("[restate] serving OrderWorkflow handlers on :9080");
console.log("[restate] register once with: restate deployments register http://localhost:9080");
console.log("[restate] then start an order over plain HTTP:");
console.log(
  `  curl localhost:8080/OrderWorkflow/order-42/run --json '{"customerId":"c1","items":[{"sku":"widget","qty":2}],"amountCents":4999}'`
);
console.log("[restate] confirm shipment (the durable promise):");
console.log(`  curl localhost:8080/OrderWorkflow/order-42/shipmentConfirmed --json '{"trackingNumber":"TRK123"}'`);
console.log("[restate] read status:");
console.log(`  curl localhost:8080/OrderWorkflow/order-42/getStatus`);
