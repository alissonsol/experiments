// Copyright (c) 2026 by Alisson Sol.
// ============================================================
// SERVER — HTTP + SSE, zero framework, zero required npm deps
//
// Serves the vanilla frontend from ./public, exposes a small JSON API
// to create and drive side-by-side scenarios, and streams live lane
// updates over Server-Sent Events. Runs entirely on one machine with
// only Node + tsx.
// ============================================================

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, extname, relative, isAbsolute, sep } from "node:path";
import {
  applyCommand,
  createScenario,
  deleteScenario,
  getScenario,
  snapshotScenario,
  type CommandInput,
  type ScenarioFaults,
} from "./scenarios.js";
import type { OrderInput } from "../order-workflow.js";
import { detectCapabilities } from "./real/capabilities.js";
import { META } from "./meta.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, "..", "public");
const PORT = Number(process.env.PORT ?? 3000);

// ---------- SSE subscriber registry, keyed by scenario id ----------
const subscribers = new Map<string, Set<ServerResponse>>();

function broadcast(scenarioId: string): void {
  const scenario = getScenario(scenarioId);
  if (!scenario) return;
  const subs = subscribers.get(scenarioId);
  if (!subs || subs.size === 0) return;
  const payload = `event: snapshot\ndata: ${JSON.stringify(snapshotScenario(scenario))}\n\n`;
  for (const res of subs) {
    if (res.writableEnded || res.destroyed) {
      subs.delete(res);
      continue;
    }
    try {
      res.write(payload);
    } catch {
      subs.delete(res);
    }
  }
}

/** Thrown by readBody when a request carries a body that isn't valid JSON. */
class BadJsonError extends Error {}

const COMMAND_ACTIONS = new Set([
  "start",
  "signal",
  "advance",
  "restart",
  "arm-crash",
  "clear-crash",
]);

// ---------- helpers ----------
function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(text);
}

async function readBody(req: IncomingMessage): Promise<any> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return {};
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (text === "") return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new BadJsonError("request body is not valid JSON");
  }
}

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

async function serveStatic(req: IncomingMessage, res: ServerResponse): Promise<void> {
  let urlPath = decodeURIComponent((req.url ?? "/").split("?")[0]);
  if (urlPath === "/") urlPath = "/index.html";
  const filePath = join(PUBLIC_DIR, urlPath);
  // Reject anything that resolves outside PUBLIC_DIR (path traversal).
  const rel = relative(PUBLIC_DIR, filePath);
  if (rel === ".." || rel.startsWith(".." + sep) || isAbsolute(rel)) {
    res.writeHead(403).end("Forbidden");
    return;
  }
  try {
    const data = await readFile(filePath);
    res.writeHead(200, { "content-type": MIME[extname(filePath)] ?? "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404, { "content-type": "text/plain" }).end("Not found");
  }
}

function defaultOrder(): OrderInput {
  return { customerId: "c1", items: [{ sku: "widget", qty: 2 }], amountCents: 4999 };
}

// ---------- routing ----------
async function handleApi(req: IncomingMessage, res: ServerResponse, url: URL): Promise<void> {
  const { pathname } = url;
  const method = req.method ?? "GET";

  // GET /api/capabilities
  if (pathname === "/api/capabilities" && method === "GET") {
    return sendJson(res, 200, detectCapabilities(url.searchParams.get("refresh") === "1"));
  }

  // GET /api/meta  (concept table, presets, reference text)
  if (pathname === "/api/meta" && method === "GET") {
    return sendJson(res, 200, META);
  }

  // POST /api/scenarios  { order?, faults? }
  if (pathname === "/api/scenarios" && method === "POST") {
    const body = await readBody(req);
    const order: OrderInput = body.order ?? defaultOrder();
    const faults: ScenarioFaults = body.faults ?? {};
    // The web lab drives the faithful SIMULATIONS. Real Temporal/Restate are
    // run out-of-band via the CLI (`npm run real:*`, see REAL-ENGINES.md), so
    // the API is honest about not executing them here.
    if (body.mode === "real") {
      return sendJson(res, 400, {
        error: "web-ui-is-simulation-only",
        message:
          "The web lab runs the simulated engines. Real Temporal/Restate run via the CLI — see REAL-ENGINES.md (npm run real:*).",
        capabilities: detectCapabilities(),
      });
    }
    const scenario = createScenario(order, "sim", faults);
    return sendJson(res, 201, snapshotScenario(scenario));
  }

  const scenMatch = pathname.match(/^\/api\/scenarios\/([^/]+)(\/[^/]+)?$/);
  if (scenMatch) {
    const id = scenMatch[1];
    const sub = scenMatch[2];
    const scenario = getScenario(id);

    // GET /api/scenarios/:id/stream   (SSE)
    if (sub === "/stream" && method === "GET") {
      if (!scenario) {
        res.writeHead(404).end();
        return;
      }
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      res.write(`event: snapshot\ndata: ${JSON.stringify(snapshotScenario(scenario))}\n\n`);
      let set = subscribers.get(id);
      if (!set) subscribers.set(id, (set = new Set()));
      set.add(res);
      const ping = setInterval(() => res.write(`: ping\n\n`), 15000);
      req.on("close", () => {
        clearInterval(ping);
        set!.delete(res);
      });
      return;
    }

    if (!scenario) return sendJson(res, 404, { error: "not-found" });

    // GET /api/scenarios/:id
    if (!sub && method === "GET") {
      return sendJson(res, 200, snapshotScenario(scenario));
    }

    // DELETE /api/scenarios/:id
    if (!sub && method === "DELETE") {
      // Close any open SSE streams first so their ping timers are cleared
      // (each res.end() fires the connection's 'close' cleanup).
      const subs = subscribers.get(id);
      if (subs) {
        for (const res2 of subs) {
          try {
            res2.end();
          } catch {
            /* already gone */
          }
        }
      }
      deleteScenario(id);
      subscribers.delete(id);
      return sendJson(res, 200, { ok: true });
    }

    // POST /api/scenarios/:id/command  { action, target, ... }
    if (sub === "/command" && method === "POST") {
      const cmd = (await readBody(req)) as CommandInput;
      if (!cmd || !COMMAND_ACTIONS.has(cmd.action)) {
        return sendJson(res, 400, {
          error: "bad-command",
          message: `unknown or missing action; expected one of ${[...COMMAND_ACTIONS].join(", ")}`,
        });
      }
      await applyCommand(scenario, cmd);
      const snap = snapshotScenario(scenario);
      broadcast(id);
      return sendJson(res, 200, snap);
    }
  }

  return sendJson(res, 404, { error: "unknown-route", path: pathname });
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
    if (url.pathname.startsWith("/api/")) {
      await handleApi(req, res, url);
    } else {
      await serveStatic(req, res);
    }
  } catch (err) {
    if (err instanceof BadJsonError) {
      if (!res.headersSent) sendJson(res, 400, { error: "bad-json", message: err.message });
      else res.end();
      return;
    }
    console.error("request error:", err);
    if (!res.headersSent) sendJson(res, 500, { error: "internal", message: String(err) });
    else res.end();
  }
});

server.listen(PORT, () => {
  const caps = detectCapabilities();
  console.log(`\n  Durable Workflows Lab — Restate vs Temporal (side-by-side)\n`);
  console.log(`  ▸ open   http://localhost:${PORT}`);
  console.log(`  ▸ engines: simulated (always on)`);
  console.log(
    `  ▸ real Temporal: ${caps.realTemporal.available ? "available" : "not installed"}` +
      `   |   real Restate: ${caps.realRestate.available ? "available" : "not installed"}`
  );
  console.log(`\n  Ctrl+C to stop.\n`);
});
