// ============================================================
// NATIVE TEMPORAL IMPLEMENTATION — workflows.ts
// This file runs inside Temporal's deterministic V8 sandbox.
// No I/O, no Date.now(), no Math.random(), no direct imports of
// side-effecting code — only proxied activities, signals, queries,
// timers. The Temporal server replays this function against the
// event history after any crash.
// ============================================================
//
// Run with:  npm i @temporalio/{client,worker,workflow,activity}
//            temporal server start-dev      (dev server + UI)
//            npx tsx worker.ts              (hosts workflows + activities)
//            npx tsx client.ts              (starts a workflow, sends signal)

import {
  proxyActivities,
  defineSignal,
  defineQuery,
  setHandler,
  condition,
  ApplicationFailure,
} from "@temporalio/workflow";
import type * as activities from "./activities";

// ---------- Types ----------
export interface OrderInput {
  customerId: string;
  items: { sku: string; qty: number }[];
  amountCents: number;
}
export interface OrderResult {
  status: "completed" | "failed";
  paymentId?: string;
  trackingNumber?: string;
}
interface ShipmentEvent { trackingNumber: string }

// Activities are invoked by name through the task queue; the proxy
// gives us type-safe stubs. Retry policy is configured here.
const acts = proxyActivities<typeof activities>({
  startToCloseTimeout: "1 minute",
  retry: { maximumAttempts: 5 },
});

// ---------- Signals & queries (declared, then handled below) ----------
export const shipmentConfirmedSignal = defineSignal<[ShipmentEvent]>("shipmentConfirmed");
export const statusQuery = defineQuery<string>("getStatus");

// ---------- The workflow ----------
export async function orderWorkflow(orderId: string, order: OrderInput): Promise<OrderResult> {
  let status = "in-progress";
  let shipment: ShipmentEvent | undefined;
  const compensations: (() => Promise<void>)[] = [];

  setHandler(shipmentConfirmedSignal, (evt) => { shipment = evt; });
  setHandler(statusQuery, () => status);

  try {
    // Step 1: reserve inventory (activity — recorded in event history)
    const reserved = await acts.reserveInventory(orderId, order.items);
    if (!reserved) {
      throw ApplicationFailure.nonRetryable("out of stock");
    }
    compensations.push(() => acts.releaseInventory(orderId));

    // Step 2: charge payment
    const paymentId = await acts.chargePayment(orderId, order.amountCents);
    compensations.push(() => acts.refundPayment(paymentId));

    // Step 3: park until the warehouse signals shipment (or 3 days pass).
    // `condition` suspends durably; the worker can die and come back.
    const confirmed = await condition(() => shipment !== undefined, "3 days");
    if (!confirmed || !shipment) {
      throw ApplicationFailure.nonRetryable("shipment not confirmed within 3 days");
    }

    // Step 4: notify the customer
    await acts.sendEmail(
      order.customerId,
      `Order ${orderId} shipped: ${shipment.trackingNumber}`
    );

    status = "completed";
    return { status: "completed", paymentId, trackingNumber: shipment.trackingNumber };
  } catch (e) {
    if (e instanceof ApplicationFailure && e.nonRetryable) {
      for (const undo of compensations.reverse()) await undo();
      status = "failed";
      return { status: "failed" };
    }
    throw e;
  }
}
