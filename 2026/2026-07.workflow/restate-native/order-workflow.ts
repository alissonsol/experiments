// ============================================================
// NATIVE RESTATE IMPLEMENTATION
// Order fulfillment: reserve inventory -> charge -> wait for
// shipment confirmation (external signal) -> notify customer.
// ============================================================
//
// Run with:  npm i @restatedev/restate-sdk
//            restate-server &          (single binary, holds the journal)
//            npx tsx order-workflow.ts (serves handlers on :9080)
//            restate deployments register http://localhost:9080
//
// Invoke over plain HTTP:
//   curl localhost:8080/OrderWorkflow/order-42/run \
//        --json '{"customerId":"c1","items":[{"sku":"widget","qty":2}],"amountCents":4999}'

import * as restate from "@restatedev/restate-sdk";
import { WorkflowContext, WorkflowSharedContext, TerminalError } from "@restatedev/restate-sdk";

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

// ---------- Plain side-effecting functions (your real code) ----------
async function reserveInventory(orderId: string, items: OrderInput["items"]): Promise<boolean> {
  console.log(`[inventory] reserving for ${orderId}`, items);
  return true;
}
async function releaseInventory(orderId: string): Promise<void> {
  console.log(`[inventory] releasing for ${orderId}`);
}
async function chargePayment(orderId: string, amountCents: number): Promise<string> {
  console.log(`[payments] charging ${amountCents} for ${orderId}`);
  return `pay_${orderId}`;
}
async function refundPayment(paymentId: string): Promise<void> {
  console.log(`[payments] refunding ${paymentId}`);
}
async function sendEmail(customerId: string, message: string): Promise<void> {
  console.log(`[email] to ${customerId}: ${message}`);
}

// ---------- The workflow ----------
export const orderWorkflow = restate.workflow({
  name: "OrderWorkflow",
  handlers: {
    // `run` executes exactly once per workflow ID (= per order ID here).
    // Every `ctx.run(...)` result is journaled by the Restate server:
    // on crash + retry, completed steps are replayed from the journal,
    // not re-executed.
    run: async (ctx: WorkflowContext, order: OrderInput): Promise<OrderResult> => {
      const orderId = ctx.key; // workflow ID doubles as the order ID
      const compensations: (() => Promise<void>)[] = [];

      try {
        // Step 1: reserve inventory (durable step)
        const reserved = await ctx.run("reserve-inventory", () =>
          reserveInventory(orderId, order.items)
        );
        if (!reserved) {
          throw new TerminalError("out of stock"); // terminal = don't retry
        }
        compensations.push(() =>
          ctx.run("release-inventory", () => releaseInventory(orderId))
        );

        // Step 2: charge payment (durable step)
        const paymentId = await ctx.run("charge-payment", () =>
          chargePayment(orderId, order.amountCents)
        );
        compensations.push(() =>
          ctx.run("refund-payment", () => refundPayment(paymentId))
        );

        // Step 3: park until the warehouse confirms shipment.
        // A durable promise survives restarts; the workflow suspends
        // (consumes no resources) until it is resolved — or 3 days pass.
        const shipped = await restate.RestatePromise.race([
          ctx.promise<ShipmentEvent>("shipment-confirmed").get(),
          ctx.sleep({ days: 3 }).map(() => null),
        ]);
        if (shipped === null) {
          throw new TerminalError("shipment not confirmed within 3 days");
        }

        // Step 4: notify the customer
        await ctx.run("notify-customer", () =>
          sendEmail(order.customerId, `Order ${orderId} shipped: ${shipped.trackingNumber}`)
        );

        ctx.set("status", "completed");
        return { status: "completed", paymentId, trackingNumber: shipped.trackingNumber };
      } catch (e) {
        if (e instanceof TerminalError) {
          // Saga: undo completed steps in reverse order
          for (const undo of compensations.reverse()) await undo();
          ctx.set("status", "failed");
          return { status: "failed" };
        }
        throw e; // transient error -> Restate retries the invocation
      }
    },

    // SIGNAL: the warehouse system calls this to resolve the durable promise.
    //   curl localhost:8080/OrderWorkflow/order-42/confirmShipment \
    //        --json '{"trackingNumber":"TRK123"}'
    confirmShipment: async (ctx: WorkflowSharedContext, event: ShipmentEvent) => {
      await ctx.promise<ShipmentEvent>("shipment-confirmed").resolve(event);
    },

    // QUERY: read workflow state from outside while it runs.
    getStatus: async (ctx: WorkflowSharedContext) =>
      (await ctx.get<string>("status")) ?? "in-progress",
  },
});

restate.serve({ services: [orderWorkflow], port: 9080 });
