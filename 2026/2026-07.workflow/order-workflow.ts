// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// PORTABLE ABSTRACTION — order-workflow.ts
// The business logic, written ONCE against DurableContext.
// No import of Restate or Temporal anywhere in this file.
// ============================================================

import { defineWorkflow, WorkflowTerminalError } from "./core/durable";

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
export interface ShipmentEvent { trackingNumber: string }

const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;

export const orderWorkflow = defineWorkflow({
  name: "OrderWorkflow",

  // Side effects: plain functions. The Temporal adapter registers
  // these as activities; the Restate adapter wraps them in ctx.run.
  steps: {
    reserveInventory: async (orderId: string, items: OrderInput["items"]) => {
      console.log(`[inventory] reserving for ${orderId}`, items);
      return true;
    },
    releaseInventory: async (orderId: string) => {
      console.log(`[inventory] releasing for ${orderId}`);
    },
    chargePayment: async (orderId: string, amountCents: number) => {
      console.log(`[payments] charging ${amountCents} for ${orderId}`);
      return `pay_${orderId}`;
    },
    refundPayment: async (paymentId: string) => {
      console.log(`[payments] refunding ${paymentId}`);
    },
    sendEmail: async (customerId: string, message: string) => {
      console.log(`[email] to ${customerId}: ${message}`);
    },
  },

  signals: ["shipmentConfirmed"],

  // Orchestration: identical semantics on both engines.
  run: async (ctx, order: OrderInput): Promise<OrderResult> => {
    const orderId = ctx.workflowId;
    const compensations: (() => Promise<unknown>)[] = [];

    try {
      const reserved = await ctx.step("reserveInventory", orderId, order.items);
      if (!reserved) throw new WorkflowTerminalError("out of stock");
      compensations.push(() => ctx.step("releaseInventory", orderId));

      const paymentId = await ctx.step("chargePayment", orderId, order.amountCents);
      compensations.push(() => ctx.step("refundPayment", paymentId));

      const shipment = await ctx.waitForSignal<ShipmentEvent>(
        "shipmentConfirmed",
        THREE_DAYS_MS
      );
      if (!shipment) throw new WorkflowTerminalError("shipment not confirmed in 3 days");

      await ctx.step(
        "sendEmail",
        order.customerId,
        `Order ${orderId} shipped: ${shipment.trackingNumber}`
      );

      ctx.setStatus("completed");
      return { status: "completed", paymentId, trackingNumber: shipment.trackingNumber };
    } catch (e) {
      if (e instanceof WorkflowTerminalError) {
        for (const undo of compensations.reverse()) await undo();
        ctx.setStatus("failed");
        return { status: "failed" };
      }
      throw e; // transient -> let the engine retry
    }
  },
});
