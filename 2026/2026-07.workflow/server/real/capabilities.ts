// ============================================================
// SERVER — real-engine capability detection
//
// Hybrid mode: the simulations always run. Real Temporal / Restate
// attach ONLY when their pieces are actually installed on this
// machine. This module reports, honestly, what is available so the
// UI can offer real mode or explain exactly what is missing.
//
// For each engine we need two things:
//   * the Node SDK (npm dependency), and
//   * the server binary on PATH (temporal / restate-server).
// ============================================================

import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";

const require = createRequire(import.meta.url);

export interface EngineCapability {
  available: boolean;
  sdkInstalled: boolean;
  binaryOnPath: boolean;
  binaryName: string;
  sdkName: string;
  reason: string; // human-readable: what's missing / how to enable
  installHint: string;
}

export interface Capabilities {
  sim: true;
  realTemporal: EngineCapability;
  realRestate: EngineCapability;
}

function hasModule(name: string): boolean {
  try {
    require.resolve(name);
    return true;
  } catch {
    return false;
  }
}

function onPath(binary: string): boolean {
  const finder = process.platform === "win32" ? "where" : "which";
  try {
    const res = spawnSync(finder, [binary], { encoding: "utf8", timeout: 4000 });
    return res.status === 0 && !!res.stdout && res.stdout.trim().length > 0;
  } catch {
    return false;
  }
}

function describe(
  sdkName: string,
  binaryName: string,
  sdkInstalled: boolean,
  binaryOnPath: boolean,
  installHint: string
): EngineCapability {
  const available = sdkInstalled && binaryOnPath;
  let reason: string;
  if (available) {
    reason = "Ready — SDK installed and server binary found on PATH.";
  } else if (!sdkInstalled && !binaryOnPath) {
    reason = `Not available — missing npm SDK "${sdkName}" and "${binaryName}" is not on PATH.`;
  } else if (!sdkInstalled) {
    reason = `Not available — missing npm SDK "${sdkName}".`;
  } else {
    reason = `Not available — "${binaryName}" is not on PATH.`;
  }
  return { available, sdkInstalled, binaryOnPath, binaryName, sdkName, reason, installHint };
}

let cached: Capabilities | null = null;

export function detectCapabilities(force = false): Capabilities {
  if (cached && !force) return cached;

  const temporalSdk = hasModule("@temporalio/worker") && hasModule("@temporalio/client");
  const temporalBin = onPath("temporal");
  const restateSdk = hasModule("@restatedev/restate-sdk");
  const restateBin = onPath("restate-server");

  cached = {
    sim: true,
    realTemporal: describe(
      "@temporalio/*",
      "temporal",
      temporalSdk,
      temporalBin,
      "npm i @temporalio/worker @temporalio/client @temporalio/workflow @temporalio/activity  &&  install the Temporal CLI (temporal server start-dev)"
    ),
    realRestate: describe(
      "@restatedev/restate-sdk",
      "restate-server",
      restateSdk,
      restateBin,
      "npm i @restatedev/restate-sdk  &&  install restate-server + restate CLI (npm i -g @restatedev/restate)"
    ),
  };
  return cached;
}
