// ============================================================
// Durable Workflows Lab — frontend
//
// Thin rendering layer over the server API. Creates a scenario,
// subscribes to its Server-Sent Events stream, and drives it with
// commands. Both engine lanes render from the same snapshot shape;
// the differences you see are the engines' own artifacts.
// ============================================================

const ENGINES = ["restate", "temporal"];
const $ = (sel, root = document) => root.querySelector(sel);
const el = (tag, cls, txt) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (txt != null) n.textContent = txt;
  return n;
};

const state = {
  scenarioId: null,
  target: "both",
  meta: null,
  caps: null,
  es: null,
  creating: false, // guards against overlapping newScenario() calls
  lastSnap: null, // latest scenario snapshot (for button-state derivation)
  // identity-based "fresh" tracking per lane: signatures already shown, so a
  // repeat render of the same snapshot flashes nothing and an in-place change
  // flashes exactly once.
  seen: freshTrackers(),
  primed: { restate: false, temporal: false },
  activePreset: null,
  stepIndex: 0,
};

function freshTrackers() {
  return {
    restate: { entries: new Set(), effects: new Set() },
    temporal: { entries: new Set(), effects: new Set() },
  };
}

// ---------- API helpers ----------
async function api(path, opts) {
  const res = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...opts,
  });
  if (!res.ok && res.status !== 409) {
    let msg = `${res.status}`;
    try { msg = (await res.json()).message || msg; } catch {}
    throw new Error(msg);
  }
  return res.json();
}

function toast(msg, isErr = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast" + (isErr ? " err" : "");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add("hidden"), 3200);
}

// ---------- bootstrap ----------
async function boot() {
  state.caps = await api("/api/capabilities");
  state.meta = await api("/api/meta");
  renderCaps();
  renderRealEngines();
  renderPresets();
  renderConceptTable();
  $("#portable-note").textContent = state.meta.notes.portable;
  $("#faithful-note").textContent = state.meta.notes.faithful;
  wireControls();
  await newScenario();
}

function renderCaps() {
  const c = state.caps;
  const chip = (label, kind, on, title) => {
    const n = el("span", `cap-chip ${on ? "on" : ""} ${kind}`);
    n.title = title;
    n.append(el("span", "dot"), el("span", null, label));
    return n;
  };
  const wrap = $("#capabilities");
  wrap.innerHTML = "";
  wrap.append(
    chip("Simulated engines", "sim", true, "Always on — zero external dependencies"),
    chip(
      `real Temporal ${c.realTemporal.available ? "✓" : "—"}`,
      "",
      c.realTemporal.available,
      c.realTemporal.reason + "\n\n" + c.realTemporal.installHint
    ),
    chip(
      `real Restate ${c.realRestate.available ? "✓" : "—"}`,
      "",
      c.realRestate.available,
      c.realRestate.reason + "\n\n" + c.realRestate.installHint
    )
  );
}

function renderRealEngines() {
  const c = state.caps;
  const wrap = $("#real-engines");
  wrap.innerHTML = "";

  const engineCard = (cap, title, cmds) => {
    const card = el("div", "real-card");
    const head = el("div", "real-card-head");
    head.append(
      el("span", "real-name", title),
      el("span", `real-status ${cap.available ? "ok" : "off"}`, cap.available ? "ready" : "not installed")
    );
    card.append(head);
    card.append(el("div", "real-reason", cap.reason));
    if (cap.available) {
      const pre = el("pre", "real-cmds");
      pre.textContent = cmds.join("\n");
      card.append(pre);
    } else {
      const hint = el("div", "real-hint");
      hint.append(el("b", null, "To enable: "), el("span", null, cap.installHint));
      card.append(hint);
    }
    return card;
  };

  wrap.append(
    engineCard(c.realTemporal, "Temporal", [
      "# terminal 1",
      "temporal server start-dev",
      "# terminal 2",
      "npm run real:temporal:worker",
      "# terminal 3",
      "npm run real:temporal:client",
    ]),
    engineCard(c.realRestate, "Restate", [
      "# terminal 1",
      "restate-server",
      "# terminal 2",
      "npm run real:restate:serve",
      "restate deployments register http://localhost:9080",
      "# then invoke over plain HTTP (see README)",
    ])
  );
}

function renderPresets() {
  const wrap = $("#presets");
  wrap.innerHTML = "";
  for (const p of state.meta.presets) {
    const b = el("button", "preset");
    b.dataset.id = p.id;
    b.append(el("div", "p-title", p.title), el("div", "p-blurb", p.blurb));
    b.onclick = () => activatePreset(p);
    wrap.append(b);
  }
}

function renderConceptTable() {
  const tb = $("#concept-table tbody");
  tb.innerHTML = "";
  for (const row of state.meta.conceptTable) {
    const tr = el("tr", row.usedHere ? "used" : "");
    const c0 = el("td", null, row.concept);
    const c1 = el("td", "restate-col", row.restate);
    const c2 = el("td", "temporal-col", row.temporal);
    tr.append(c0, c1, c2);
    tb.append(tr);
  }
}

// ---------- scenario lifecycle ----------
async function newScenario(faults = {}) {
  if (state.creating) return; // ignore overlapping requests (double-click, fast preset switching)
  state.creating = true;
  try {
    if (state.es) { state.es.close(); state.es = null; }
    // Release the previous scenario server-side so runs don't accumulate.
    if (state.scenarioId) {
      fetch(`/api/scenarios/${state.scenarioId}`, { method: "DELETE" }).catch(() => {});
      state.scenarioId = null;
    }
    const order = { customerId: "c1", items: [{ sku: "widget", qty: 2 }], amountCents: 4999 };
    const snap = await api("/api/scenarios", {
      method: "POST",
      body: JSON.stringify({ order, faults }),
    });
    state.scenarioId = snap.id;
    state.seen = freshTrackers();
    state.primed = { restate: false, temporal: false };
    renderOrder(snap.order);
    render(snap);
    // Subscribe to live updates. The stream is the single render trigger for
    // subsequent commands, so highlight animations aren't torn down by a
    // duplicate render.
    state.es = new EventSource(`/api/scenarios/${snap.id}/stream`);
    state.es.addEventListener("snapshot", (e) => render(JSON.parse(e.data)));
  } finally {
    state.creating = false;
  }
}

function renderOrder(order) {
  const items = order.items.map((i) => `${Number(i.qty)}×${escapeHtml(String(i.sku))}`).join(", ");
  $("#order-summary").innerHTML =
    `customer=<b>${escapeHtml(String(order.customerId))}</b><br>items=[${items}]<br>amount=<b>${Number(order.amountCents)}¢</b>`;
}

// ---------- commands ----------
async function sendCommand(body) {
  if (!state.scenarioId) return;
  try {
    // The server broadcasts the resulting snapshot over SSE, which drives the
    // single render — so we don't render the HTTP response here (doing both
    // would tear down the "fresh" highlight animation before it's visible).
    await api(`/api/scenarios/${state.scenarioId}/command`, {
      method: "POST",
      body: JSON.stringify(body),
    });
  } catch (e) {
    toast(e.message, true);
  }
}

function wireControls() {
  // target segmented control
  $("#target-seg").addEventListener("click", (e) => {
    const b = e.target.closest("button[data-target]");
    if (!b) return;
    state.target = b.dataset.target;
    for (const btn of $("#target-seg").children) btn.classList.toggle("active", btn === b);
    updateButtonStates(state.lastSnap); // eligibility depends on the target
  });

  // command buttons
  document.querySelectorAll("[data-cmd]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const cmd = btn.dataset.cmd;
      const base = { target: state.target };
      if (cmd === "start") sendCommand({ ...base, action: "start" });
      else if (cmd === "signal")
        sendCommand({ ...base, action: "signal", signalName: "shipmentConfirmed", payload: { trackingNumber: "TRK" + rand() } });
      else if (cmd === "advance")
        sendCommand({ ...base, action: "advance", ms: Number(btn.dataset.ms) });
      else if (cmd === "restart") sendCommand({ ...base, action: "restart" });
      else if (cmd === "arm-crash")
        sendCommand({ ...base, action: "arm-crash", step: $("#crash-step").value, when: $("#crash-when").value });
      else if (cmd === "clear-crash") sendCommand({ ...base, action: "clear-crash" });
    });
  });

  $("#btn-new").addEventListener("click", () => {
    clearPreset();
    newScenario();
  });

  $("#btn-refresh-caps").addEventListener("click", async () => {
    try {
      state.caps = await api("/api/capabilities?refresh=1");
      renderCaps();
      renderRealEngines();
      toast("Re-checked engine availability");
    } catch (e) {
      toast(e.message, true);
    }
  });
}

function rand() {
  return Math.floor(Math.random() * 900 + 100);
}

// ---------- guided presets ----------
function activatePreset(preset) {
  state.activePreset = preset;
  state.stepIndex = 0;
  document.querySelectorAll(".preset").forEach((p) => p.classList.toggle("active", p.dataset.id === preset.id));
  newScenario(preset.faults || {}).then(renderStepper);
}

function clearPreset() {
  state.activePreset = null;
  state.stepIndex = 0;
  document.querySelectorAll(".preset").forEach((p) => p.classList.remove("active"));
  $("#stepper").classList.add("hidden");
}

function renderStepper() {
  const preset = state.activePreset;
  const s = $("#stepper");
  if (!preset) { s.classList.add("hidden"); return; }
  s.classList.remove("hidden");
  s.innerHTML = "";
  const head = el("div", "s-head");
  head.append(el("div", "s-title", preset.title));
  const close = el("button", "btn subtle", "✕");
  close.onclick = clearPreset;
  head.append(close);
  s.append(head);

  preset.steps.forEach((step, i) => {
    const item = el("div", "step-item " + (i < state.stepIndex ? "done" : i === state.stepIndex ? "current" : ""));
    item.append(el("div", "idx", i < state.stepIndex ? "✓" : String(i + 1)));
    const body = el("div");
    body.append(el("div", "s-label", step.label));
    if (step.note && i === state.stepIndex) body.append(el("div", "s-note", "👁 " + step.note));
    item.append(body);
    s.append(item);
  });

  const actions = el("div", "s-actions");
  const done = state.stepIndex >= preset.steps.length;
  const next = el("button", "btn primary", done ? "✓ Complete" : "▶ Run step " + (state.stepIndex + 1));
  next.disabled = done;
  next.onclick = runNextStep;
  const all = el("button", "btn", "⏩ Run all");
  all.disabled = done;
  all.onclick = runAllSteps;
  actions.append(next, all);
  s.append(actions);
}

async function runNextStep() {
  const preset = state.activePreset;
  if (!preset || state.stepIndex >= preset.steps.length) return;
  const step = preset.steps[state.stepIndex];
  await sendCommand({
    action: step.action,
    target: step.target || "both",
    ms: step.ms,
    step: step.step,
    when: step.when,
    signalName: step.action === "signal" ? "shipmentConfirmed" : undefined,
    payload: step.payload,
  });
  state.stepIndex++;
  renderStepper();
}

async function runAllSteps() {
  const preset = state.activePreset;
  while (state.activePreset === preset && state.stepIndex < preset.steps.length) {
    await runNextStep();
    await sleep(650);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- rendering the lanes ----------
function render(snap) {
  state.lastSnap = snap;
  for (const engineId of ENGINES) {
    renderLane(engineId, snap.lanes[engineId]);
  }
  updateButtonStates(snap);
}

// Signature of a rendered entry: flashes on first appearance AND on any
// in-place change (a step slot's detail flipping from "executing…" to a
// result keeps its position but changes its signature).
function entrySig(e) {
  return `${e.group}|${e.type}|${e.state}|${e.summary}|${e.detail ?? ""}`;
}

function renderLane(engineId, lane) {
  const root = document.querySelector(`.lane[data-engine="${engineId}"]`);
  const seen = state.seen[engineId];
  const primed = state.primed[engineId]; // don't flash on the very first paint

  // Build fresh DOM (simple + reliable; lists are small).
  root.innerHTML = "";

  // --- head ---
  const head = el("div", "lane-head");
  const titleRow = el("div", "lane-title-row");
  const title = el("div", "lane-title");
  title.append(el("span", "engine-dot"), el("span", null, lane.engineLabel));
  titleRow.append(title, statusPill(lane.status));
  head.append(titleRow);
  head.append(el("div", "mech-note", metaMech(engineId)));
  head.append(el("div", "invoke-note", "▸ " + lane.invocationNote));

  const metaRow = el("div", "meta-row");
  metaRow.append(kv("status query", lane.queriedStatus));
  metaRow.append(kv(lane.virtualClockLabel.split(":")[0], lane.virtualClockLabel.split(":").slice(1).join(":").trim() || "T+0"));
  metaRow.append(kv("replays", String(lane.replayCount)));
  head.append(metaRow);
  root.append(head);

  // --- armed crash ---
  if (lane.armedCrash) {
    const a = el("div", "armed");
    a.append(el("span", null, "💥"), el("span", null,
      `Crash armed: ${lane.armedCrash.when === "before-effect" ? "before" : "after"} "${lane.armedCrash.step}" side effect`));
    root.append(a);
  }

  // --- timeline ---
  const tl = el("div", "timeline");
  if (lane.timeline.length === 0) {
    tl.append(el("div", "kv", "no steps yet — press Start"));
  }
  for (const step of lane.timeline) {
    const s = el("div", "tl-step " + step.state);
    s.append(el("div", "tl-node", step.label));
    s.append(el("div", "tl-replay", step.replayed ? "↺ replayed" : ""));
    tl.append(s);
  }
  root.append(tl);

  // --- suspend / crash banner ---
  if (lane.suspendReason && (lane.status === "suspended" || lane.status === "crashed")) {
    const b = el("div", "banner " + (lane.status === "crashed" ? "crash" : "suspend"));
    b.textContent = (lane.status === "crashed" ? "⚠ " : "⏸ ") + lane.suspendReason;
    root.append(b);
  }

  // --- body: durable log + side effects ---
  const body = el("div", "lane-body");

  // durable log pane
  const logPane = el("div", "pane");
  const logHead = el("div", "pane-head");
  logHead.append(el("h3", null, lane.logLabel), el("span", "count", `${lane.entries.length} entries`));
  logPane.append(logHead);
  const log = el("div", "log");
  lane.entries.forEach((entry) => {
    const sig = entrySig(entry);
    const isFresh = primed && !seen.entries.has(sig);
    seen.entries.add(sig);
    log.append(renderEntry(entry, isFresh));
  });
  logPane.append(log);
  body.append(logPane);

  // side effects pane
  const fxPane = el("div", "pane");
  const fxHead = el("div", "pane-head");
  fxHead.append(el("h3", null, "Real-world side effects"), el("span", "count", `${lane.sideEffects.length} fired`));
  fxPane.append(fxHead);
  const fx = el("div", "effects");
  if (lane.sideEffects.length === 0) {
    fx.append(el("div", "effects-empty", "nothing has touched the outside world yet"));
  }
  lane.sideEffects.forEach((e) => {
    const sig = `${e.seq}|${e.attempt}`;
    const isFresh = primed && !seen.effects.has(sig);
    seen.effects.add(sig);
    const row = el("div", "effect" + (e.attempt > 1 ? " retry" : "") + (isFresh ? " fresh" : ""));
    row.append(el("span", null, e.message));
    row.append(el("span", "attempt-badge", e.attempt > 1 ? `⟳ attempt ${e.attempt}` : "×1"));
    fx.append(row);
  });
  fxPane.append(fx);
  body.append(fxPane);
  root.append(body);

  // --- result ---
  if ((lane.status === "completed" || lane.status === "failed") && lane.result) {
    const r = el("div", "result " + (lane.status === "failed" ? "fail" : "ok"));
    r.textContent = (lane.status === "failed" ? "✗ " : "✓ ") + JSON.stringify(lane.result);
    root.append(r);
  }

  // After the first paint, subsequent new/changed signatures may flash.
  state.primed[engineId] = true;
}

function renderEntry(entry, fresh) {
  const n = el("div", `entry st-${entry.state}` + (fresh ? " fresh" : ""));
  n.append(el("div", "eid", "#" + entry.id));
  const main = el("div");
  main.append(el("span", "etype-badge", entry.type));
  main.append(el("div", "esum", entry.summary));
  if (entry.detail) main.append(el("div", "edet", entry.detail));
  n.append(main);
  return n;
}

// Reflect per-lane eligibility in the controls so illegal actions are
// visibly disabled instead of silently no-op'ing.
function updateButtonStates(snap) {
  if (!snap) return;
  const targeted = state.target === "both" ? ["restate", "temporal"] : [state.target];
  const statuses = targeted.map((id) => snap.lanes[id].status);
  const any = (s) => statuses.includes(s);
  const setCmd = (cmd, enabled) =>
    document.querySelectorAll(`[data-cmd="${cmd}"]`).forEach((b) => {
      b.disabled = !enabled;
    });
  setCmd("start", any("idle"));
  setCmd("signal", any("suspended"));
  setCmd("advance", any("suspended"));
  setCmd("restart", statuses.some((s) => s !== "idle"));
  // arm-crash / clear-crash stay enabled (you arm before the step runs).
}

function statusPill(status) {
  return el("span", `pill s-${status}`, status);
}

function kv(k, v) {
  const n = el("span", "kv");
  n.innerHTML = `${k}: <b>${escapeHtml(String(v))}</b>`;
  return n;
}

function metaMech(engineId) {
  return engineId === "restate"
    ? "Side effects run INLINE as ctx.run() closures · externals = durable promises · ctx.set() state is journaled."
    : "Side effects are ACTIVITIES on a task queue · externals = signals + condition() · query state is NOT journaled.";
}

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

boot().catch((e) => {
  console.error(e);
  toast("Failed to start: " + e.message, true);
});
