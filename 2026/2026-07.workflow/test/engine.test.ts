// Engine smoke test — validates the durable-execution mechanics
// end-to-end across both simulated engines. Run: npm test
import { createScenario, applyCommand, snapshotScenario } from "../server/scenarios.js";

const THREE_DAYS = 3 * 24 * 60 * 60 * 1000;
let failures = 0;
function check(name: string, cond: boolean, extra?: unknown) {
  console.log(`${cond ? "✅" : "❌"} ${name}`);
  if (!cond) {
    failures++;
    if (extra !== undefined) console.log("   ", JSON.stringify(extra));
  }
}

function order() {
  return { customerId: "c1", items: [{ sku: "widget", qty: 2 }], amountCents: 4999 };
}

// ---- 1. Happy path ----
{
  const s = createScenario(order(), "sim", {});
  await applyCommand(s, { action: "start", target: "both" });
  let snap = snapshotScenario(s);
  check("happy: both suspended at shipment wait", snap.lanes.restate.status === "suspended" && snap.lanes.temporal.status === "suspended", snap.lanes.restate.status);
  check("happy: reserve+charge side effects fired once each (restate)", snap.lanes.restate.sideEffects.length === 2, snap.lanes.restate.sideEffects.map(e=>e.step));
  await applyCommand(s, { action: "signal", target: "both", payload: { trackingNumber: "TRK123" } });
  snap = snapshotScenario(s);
  check("happy: both completed", snap.lanes.restate.status === "completed" && snap.lanes.temporal.status === "completed", { r: snap.lanes.restate.status, t: snap.lanes.temporal.status });
  check("happy: result has tracking", (snap.lanes.restate.result as any)?.trackingNumber === "TRK123");
  check("happy: 3 side effects total (reserve, charge, email)", snap.lanes.restate.sideEffects.length === 3, snap.lanes.restate.sideEffects.map(e=>e.step));
  check("happy: restate journals set-state, temporal does not", snap.lanes.restate.entries.some(e=>e.type==="set-state") && !snap.lanes.temporal.entries.some(e=>e.type==="set-state"));
}

// ---- 2. Timeout → saga ----
{
  const s = createScenario(order(), "sim", {});
  await applyCommand(s, { action: "start", target: "both" });
  await applyCommand(s, { action: "advance", target: "both", ms: THREE_DAYS });
  const snap = snapshotScenario(s);
  check("timeout: both failed", snap.lanes.restate.status === "failed" && snap.lanes.temporal.status === "failed", { r: snap.lanes.restate.status, t: snap.lanes.temporal.status });
  const effs = snap.lanes.restate.sideEffects.map((e) => e.step);
  check("timeout: compensations ran in reverse (refund then release)", effs.join(",") === "reserveInventory,chargePayment,refundPayment,releaseInventory", effs);
}

// ---- 3. Out of stock ----
{
  const s = createScenario(order(), "sim", { outOfStock: true });
  await applyCommand(s, { action: "start", target: "both" });
  const snap = snapshotScenario(s);
  check("oos: both failed immediately", snap.lanes.restate.status === "failed" && snap.lanes.temporal.status === "failed");
  check("oos: only reserve side effect (no compensations)", snap.lanes.restate.sideEffects.length === 1 && snap.lanes.restate.sideEffects[0].step === "reserveInventory", snap.lanes.restate.sideEffects.map(e=>e.step));
}

// ---- 4. Crash before effect (clean recovery, exactly once) ----
{
  const s = createScenario(order(), "sim", {});
  await applyCommand(s, { action: "arm-crash", target: "both", step: "chargePayment", when: "before-effect" });
  await applyCommand(s, { action: "start", target: "both" });
  let snap = snapshotScenario(s);
  check("crash-before: crashed", snap.lanes.restate.status === "crashed", snap.lanes.restate.status);
  check("crash-before: only reserve ran (no charge)", snap.lanes.restate.sideEffects.map(e=>e.step).join(",") === "reserveInventory", snap.lanes.restate.sideEffects.map(e=>e.step));
  await applyCommand(s, { action: "restart", target: "both" });
  snap = snapshotScenario(s);
  check("crash-before: after restart, reserve replayed + charge ran exactly once", snap.lanes.restate.sideEffects.map(e=>e.step).join(",") === "reserveInventory,chargePayment", snap.lanes.restate.sideEffects.map(e=>e.step));
  check("crash-before: reserve marked replayed on restart", snap.lanes.restate.timeline.find(t=>t.label.includes("Reserve"))?.replayed === true);
  check("crash-before: suspended at shipment wait after restart", snap.lanes.restate.status === "suspended", snap.lanes.restate.status);
}

// ---- 5. Crash after effect (at-least-once, double charge) ----
{
  const s = createScenario(order(), "sim", {});
  await applyCommand(s, { action: "arm-crash", target: "both", step: "chargePayment", when: "after-effect" });
  await applyCommand(s, { action: "start", target: "both" });
  let snap = snapshotScenario(s);
  check("crash-after: crashed", snap.lanes.restate.status === "crashed");
  check("crash-after: charge fired once before crash", snap.lanes.restate.sideEffects.filter(e=>e.step==="chargePayment").length === 1, snap.lanes.restate.sideEffects.map(e=>e.step));
  await applyCommand(s, { action: "restart", target: "both" });
  snap = snapshotScenario(s);
  const charges = snap.lanes.restate.sideEffects.filter(e=>e.step==="chargePayment");
  check("crash-after: charge fired TWICE after restart (at-least-once)", charges.length === 2, snap.lanes.restate.sideEffects.map(e=>e.step));
  check("crash-after: second charge is attempt 2", charges[1]?.attempt === 2, charges.map(c=>c.attempt));
  await applyCommand(s, { action: "signal", target: "both", payload: { trackingNumber: "TRK9" } });
  snap = snapshotScenario(s);
  check("crash-after: completes after signal", snap.lanes.restate.status === "completed", snap.lanes.restate.status);
}

// ---- 6. Restart a suspended workflow does not re-run steps ----
{
  const s = createScenario(order(), "sim", {});
  await applyCommand(s, { action: "start", target: "both" });
  const before = snapshotScenario(s).lanes.temporal.sideEffects.length;
  await applyCommand(s, { action: "restart", target: "both" });
  const after = snapshotScenario(s).lanes.temporal.sideEffects.length;
  check("restart-suspended: no new side effects (pure replay)", before === after, { before, after });
}

// ---- 7. At-least-once applies to compensation steps too ----
{
  const s = createScenario(order(), "sim", {});
  await applyCommand(s, { action: "start", target: "both" });
  await applyCommand(s, { action: "arm-crash", target: "both", step: "refundPayment", when: "after-effect" });
  await applyCommand(s, { action: "advance", target: "both", ms: THREE_DAYS }); // timeout → saga → crash mid-refund
  let snap = snapshotScenario(s);
  check("saga-crash: crashed while compensating", snap.lanes.restate.status === "crashed", snap.lanes.restate.status);
  await applyCommand(s, { action: "restart", target: "both" });
  snap = snapshotScenario(s);
  const refunds = snap.lanes.restate.sideEffects.filter((e) => e.step === "refundPayment");
  check("saga-crash: refund ran twice across the crash (at-least-once in compensation)", refunds.length === 2, snap.lanes.restate.sideEffects.map((e) => `${e.step}#${e.attempt}`));
  check("saga-crash: finishes failed with both compensations", snap.lanes.restate.status === "failed" && snap.lanes.restate.sideEffects.some((e) => e.step === "releaseInventory"), snap.lanes.restate.status);
}

// ---- 8. Restarting a completed workflow is a pure, idempotent replay ----
{
  const s = createScenario(order(), "sim", {});
  await applyCommand(s, { action: "start", target: "both" });
  await applyCommand(s, { action: "signal", target: "both", payload: { trackingNumber: "TRK1" } });
  const setStateBefore = snapshotScenario(s).lanes.restate.entries.filter((e) => e.type === "set-state").length;
  await applyCommand(s, { action: "restart", target: "both" });
  const snap = snapshotScenario(s);
  const setStateAfter = snap.lanes.restate.entries.filter((e) => e.type === "set-state").length;
  check("restart-completed: still completed", snap.lanes.restate.status === "completed");
  check("restart-completed: no duplicate set-state entries on replay", setStateBefore === setStateAfter, { setStateBefore, setStateAfter });
}

// ---- 9. A signal is durably buffered even if it arrives before the wait ----
{
  const s = createScenario(order(), "sim", {});
  // Deliver the signal BEFORE starting — a real durable promise / Temporal
  // signal buffers it; it must not be lost.
  await applyCommand(s, { action: "signal", target: "both", payload: { trackingNumber: "EARLY" } });
  let snap = snapshotScenario(s);
  check("early-signal: nothing ran yet (still idle)", snap.lanes.restate.status === "idle");
  await applyCommand(s, { action: "start", target: "both" });
  snap = snapshotScenario(s);
  check("early-signal: buffered signal completes the workflow on start", snap.lanes.restate.status === "completed" && (snap.lanes.restate.result as any)?.trackingNumber === "EARLY", { st: snap.lanes.restate.status, r: snap.lanes.restate.result });
}

console.log(`\n${failures === 0 ? "ALL PASSED" : failures + " FAILED"}`);
process.exit(failures === 0 ? 0 : 1);
