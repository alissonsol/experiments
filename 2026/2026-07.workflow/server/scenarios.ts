// ============================================================
// SERVER — scenario store
//
// A "scenario" is ONE order run side-by-side across both engines.
// Crucially, both lanes are driven by the SAME portable business
// logic (../order-workflow.ts) through the SAME DurableContext
// contract — the whole point of the abstraction. The engines differ
// only in how their durable log is presented and in the real-world
// topology each models.
// ============================================================

import { orderWorkflow, type OrderInput } from "../order-workflow.js";
import { SimEngine, type EngineOptions } from "../sim/engine.js";
import type { ArmedCrash, EngineId, LaneSnapshot } from "../sim/types.js";

export type EngineTarget = "both" | EngineId;
export type RunMode = "sim" | "real";

export interface ScenarioFaults {
  outOfStock?: boolean;
}

export interface ScenarioSnapshot {
  id: string;
  order: OrderInput;
  mode: RunMode;
  faults: ScenarioFaults;
  createdAt: number;
  lanes: { restate: LaneSnapshot; temporal: LaneSnapshot };
}

export interface Scenario {
  id: string;
  order: OrderInput;
  mode: RunMode;
  faults: ScenarioFaults;
  createdAt: number;
  engines: { restate: SimEngine<any, any, any>; temporal: SimEngine<any, any, any> };
  /** Serializes commands so overlapping requests can't interleave two
   *  replay passes over the same engine's shared journal. */
  lock: Promise<void>;
}

let scenarioCounter = 0;
let orderCounter = 41; // so the first order is "order-42"

const scenarios = new Map<string, Scenario>();

export function createScenario(
  order: OrderInput,
  mode: RunMode,
  faults: ScenarioFaults
): Scenario {
  const id = `scenario-${++scenarioCounter}`;
  const orderId = `order-${++orderCounter}`;
  const opts: EngineOptions = { outOfStock: !!faults.outOfStock };
  const scenario: Scenario = {
    id,
    order,
    mode,
    faults,
    createdAt: safeNow(),
    engines: {
      restate: new SimEngine("restate", orderWorkflow, orderId, order, opts),
      temporal: new SimEngine("temporal", orderWorkflow, orderId, order, opts),
    },
    lock: Promise.resolve(),
  };
  scenarios.set(id, scenario);
  return scenario;
}

export function getScenario(id: string): Scenario | undefined {
  return scenarios.get(id);
}

export function deleteScenario(id: string): boolean {
  return scenarios.delete(id);
}

export function listScenarios(): Scenario[] {
  return [...scenarios.values()];
}

function targets(scenario: Scenario, target: EngineTarget): EngineId[] {
  if (target === "both") return ["restate", "temporal"];
  return [target];
}

// ---------- apply a command to one or both lanes ----------
export interface CommandInput {
  action: "start" | "signal" | "advance" | "restart" | "arm-crash" | "clear-crash";
  target: EngineTarget;
  // signal
  signalName?: string;
  payload?: unknown;
  // advance
  ms?: number;
  // arm-crash
  step?: string;
  when?: ArmedCrash["when"];
}

export async function applyCommand(scenario: Scenario, cmd: CommandInput): Promise<void> {
  // Chain onto the scenario's lock so commands run one-at-a-time, even if
  // several HTTP requests arrive concurrently for the same scenario.
  const run = scenario.lock.then(() => doApply(scenario, cmd));
  scenario.lock = run.then(
    () => {},
    () => {}
  );
  return run;
}

async function doApply(scenario: Scenario, cmd: CommandInput): Promise<void> {
  const engines = targets(scenario, cmd.target).map((id) => scenario.engines[id]);
  await Promise.all(
    engines.map(async (engine) => {
      switch (cmd.action) {
        case "start":
          await engine.start();
          break;
        case "signal":
          await engine.deliverSignal(
            cmd.signalName ?? "shipmentConfirmed",
            cmd.payload ?? { trackingNumber: "TRK123" }
          );
          break;
        case "advance":
          await engine.advanceClock(cmd.ms ?? 0);
          break;
        case "restart":
          await engine.restartWorker();
          break;
        case "arm-crash":
          engine.armCrash({ step: cmd.step ?? "*", when: cmd.when ?? "after-effect" });
          break;
        case "clear-crash":
          engine.armCrash(null);
          break;
      }
    })
  );
}

export function snapshotScenario(scenario: Scenario): ScenarioSnapshot {
  return {
    id: scenario.id,
    order: scenario.order,
    mode: scenario.mode,
    faults: scenario.faults,
    createdAt: scenario.createdAt,
    lanes: {
      restate: scenario.engines.restate.snapshot(),
      temporal: scenario.engines.temporal.snapshot(),
    },
  };
}

// Date.now() may be unavailable in some harness contexts; degrade safely.
function safeNow(): number {
  try {
    return Date.now();
  } catch {
    return 0;
  }
}
