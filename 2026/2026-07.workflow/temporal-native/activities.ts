// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// NATIVE TEMPORAL IMPLEMENTATION — activities.ts
// In Temporal, side effects MUST live in "activities": plain
// functions registered on a worker and invoked by the workflow
// through the task queue. Their results are recorded in the
// workflow's event history.
// ============================================================

import type { OrderInput } from "./workflows";

export async function reserveInventory(
  orderId: string,
  items: OrderInput["items"]
): Promise<boolean> {
  console.log(`[inventory] reserving for ${orderId}`, items);
  return true;
}

export async function releaseInventory(orderId: string): Promise<void> {
  console.log(`[inventory] releasing for ${orderId}`);
}

export async function chargePayment(orderId: string, amountCents: number): Promise<string> {
  console.log(`[payments] charging ${amountCents} for ${orderId}`);
  return `pay_${orderId}`;
}

export async function refundPayment(paymentId: string): Promise<void> {
  console.log(`[payments] refunding ${paymentId}`);
}

export async function sendEmail(customerId: string, message: string): Promise<void> {
  console.log(`[email] to ${customerId}: ${message}`);
}
