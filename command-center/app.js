/* Avertis command centre.
 *
 * Deliberately dependency-free: no build step, no npm, no framework. It is
 * one static page that polls the backend. During a demo the fewest moving
 * parts wins, and this can be opened straight from disk.
 *
 * Everything shown here comes from the backend. Where the backend does not
 * know something, this says so rather than filling the gap — an operator
 * acting on an invented number is the failure mode the whole project is
 * built to avoid.
 */

const API = (() => {
  const fromQuery = new URLSearchParams(location.search).get("api");
  if (fromQuery) return fromQuery.replace(/\/+$/, "");
  // Served by the backend itself? Use the same origin. Opened from disk?
  // Fall back to the usual local port.
  if (location.protocol.startsWith("http")) return location.origin;
  return "http://127.0.0.1:8000";
})();

const POLL_MS = 2000;

const el = (id) => document.getElementById(id);
const state = { selected: null, whyOpen: false, lastReplan: null };

async function get(path) {
  const response = await fetch(`${API}${path}`, { cache: "no-store" });
  if (!response.ok) throw new Error(`${path} → ${response.status}`);
  return response.json();
}

// -- rendering ---------------------------------------------------------------

function renderHealth(health) {
  const badge = el("engine-badge");
  if (!health) {
    badge.textContent = "engine unknown";
    badge.className = "badge badge-muted";
    return;
  }
  const { engine, is_model: isModel } = health.reasoning;
  // Say plainly which engine produced what is on screen. Showing rule output
  // as model reasoning would misrepresent the system to anyone watching.
  badge.textContent = isModel ? `reasoning: ${engine}` : "reasoning: rules (no Gemini key)";
  badge.className = `badge ${isModel ? "badge-model" : "badge-rules"}`;
  badge.title = health.reasoning.note || "";
}

function renderNetwork(network) {
  el("net-nodes").textContent = network.nodes_total ?? 0;
  el("net-reachable").textContent = network.nodes_reachable ?? 0;
  el("net-partitions").textContent = network.partitions ?? 0;
  el("net-gateways").textContent = (network.gateways || []).length;

  const note = el("topology-note");
  if (!network.nodes || network.nodes.length === 0) {
    note.textContent = "No topology reported yet.";
  } else {
    note.textContent =
      `${network.links.length} link(s), mean stability ` +
      `${Math.round((network.mean_link_stability || 0) * 100)}%` +
      (network.partitions > 1
        ? ` · ${network.partitions} partitions — some nodes cannot reach others`
        : " · fully connected");
  }
  drawTopology(network);
}

const PARTITION_COLOURS = [
  "#3da5ff", "#ff8a3d", "#00d9a3", "#c77dff", "#ffc53d", "#ff4438",
];

function drawTopology(network) {
  const canvas = el("topology");
  const ctx = canvas.getContext("2d");
  const { width, height } = canvas;
  ctx.clearRect(0, 0, width, height);

  const nodes = network.nodes || [];
  if (nodes.length === 0) return;

  // Lay nodes out by geography when they report it, so the picture matches
  // the ground. Otherwise fall back to a circle — a made-up position would
  // imply knowledge we do not have.
  const located = nodes.filter((n) => n.location);
  const positions = {};
  const pad = 28;

  if (located.length >= 2) {
    const lats = located.map((n) => n.location.lat);
    const lons = located.map((n) => n.location.lon);
    const minLat = Math.min(...lats), maxLat = Math.max(...lats);
    const minLon = Math.min(...lons), maxLon = Math.max(...lons);
    const spanLat = maxLat - minLat || 1e-6;
    const spanLon = maxLon - minLon || 1e-6;

    nodes.forEach((n, i) => {
      if (n.location) {
        positions[n.node_id] = {
          x: pad + ((n.location.lon - minLon) / spanLon) * (width - 2 * pad),
          // North is up, so latitude inverts against screen y.
          y: pad + (1 - (n.location.lat - minLat) / spanLat) * (height - 2 * pad),
        };
      } else {
        const angle = (i / nodes.length) * Math.PI * 2;
        positions[n.node_id] = {
          x: width / 2 + Math.cos(angle) * (width / 2 - pad),
          y: height / 2 + Math.sin(angle) * (height / 2 - pad),
        };
      }
    });
  } else {
    nodes.forEach((n, i) => {
      const angle = (i / nodes.length) * Math.PI * 2;
      positions[n.node_id] = {
        x: width / 2 + Math.cos(angle) * (width / 2 - pad),
        y: height / 2 + Math.sin(angle) * (height / 2 - pad),
      };
    });
  }

  // Links first, so nodes sit on top. Thickness and opacity carry stability.
  for (const link of network.links || []) {
    const a = positions[link.a];
    const b = positions[link.b];
    if (!a || !b) continue;
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.strokeStyle = `rgba(136,151,168,${0.15 + link.stability * 0.6})`;
    ctx.lineWidth = 0.5 + link.stability * 2.5;
    ctx.stroke();
  }

  const partitionOf = network.partition_of || {};
  for (const node of nodes) {
    const p = positions[node.node_id];
    if (!p) continue;
    const partition = partitionOf[node.node_id];
    const colour =
      partition === null || partition === undefined
        ? "#6b7a8f"
        : PARTITION_COLOURS[partition % PARTITION_COLOURS.length];

    const isGateway = node.role === "GATEWAY";
    const radius = isGateway ? 8 : node.role === "RESPONDER" ? 7 : 5;

    ctx.beginPath();
    ctx.arc(p.x, p.y, radius, 0, Math.PI * 2);
    ctx.fillStyle = node.reachable ? colour : "#0a0d12";
    ctx.fill();
    ctx.strokeStyle = colour;
    ctx.lineWidth = 2;
    ctx.stroke();

    if (isGateway || node.role === "RESPONDER") {
      ctx.fillStyle = "#8b97a8";
      ctx.font = "9px ui-sans-serif, sans-serif";
      ctx.textAlign = "center";
      ctx.fillText(node.node_id, p.x, p.y + radius + 11);
    }
  }
}

function renderIncidents(data) {
  const counts = data.by_severity || {};
  el("inc-crit").textContent = counts.LIFE_CRITICAL || 0;
  el("inc-emer").textContent = counts.EMERGENCY || 0;
  el("inc-oper").textContent = counts.OPERATIONAL || 0;
  el("inc-norm").textContent = counts.NORMAL || 0;

  const incidents = data.incidents || [];
  const fused = incidents.filter((i) => i.evidence.length > 1);
  const absorbed = fused.reduce((sum, i) => sum + i.evidence.length - 1, 0);
  el("fusion-note").textContent = absorbed
    ? `${absorbed} duplicate report(s) absorbed into ${fused.length} incident(s).`
    : "";

  const list = el("incident-list");
  list.innerHTML = "";
  for (const incident of incidents) {
    const li = document.createElement("li");
    if (incident.incident_id === state.selected) li.className = "selected";

    const dot = document.createElement("span");
    dot.className = "dot";
    dot.style.background = severityColour(incident.severity);

    const who = document.createElement("span");
    who.className = "who";
    who.textContent = incident.incident_id;

    const what = document.createElement("span");
    what.className = "what";
    what.textContent =
      `${incident.type} · ${incident.evidence.length} source(s) · ` +
      `confidence ${Math.round(incident.confidence * 100)}%`;

    li.append(dot, who, what);
    li.onclick = () => {
      state.selected = incident.incident_id;
      state.whyOpen = false;
      refresh();
    };
    list.append(li);
  }
}

function severityColour(severity) {
  return {
    LIFE_CRITICAL: "#ff4438",
    EMERGENCY: "#ff8a3d",
    OPERATIONAL: "#ffc53d",
    NORMAL: "#6b7a8f",
  }[severity] || "#6b7a8f";
}

function renderDecision(world) {
  const incidents = world.physical.incidents || [];
  if (incidents.length === 0) {
    el("decision").hidden = true;
    el("decision-empty").hidden = false;
    return;
  }

  // Default to the most severe, oldest incident — what an operator should be
  // looking at if they have not chosen otherwise.
  const chosenIncident =
    incidents.find((i) => i.incident_id === state.selected) || incidents[0];
  state.selected = chosenIncident.incident_id;

  el("decision-empty").hidden = true;
  el("decision").hidden = false;

  el("decision-id").textContent = chosenIncident.incident_id;
  const sev = el("decision-severity");
  sev.textContent = chosenIncident.severity.replace("_", " ");
  sev.className = `pill ${chosenIncident.severity}`;

  const people = chosenIncident.people_affected;
  el("decision-sources").textContent =
    `${chosenIncident.evidence.length} source(s) · confidence ` +
    `${Math.round(chosenIncident.confidence * 100)}% · ` +
    (people === null || people === undefined
      ? "headcount unknown"
      : `${people} affected`);

  el("decision-desc").textContent = chosenIncident.description || "(no description)";

  const rec = (world.recommendations || {})[chosenIncident.incident_id];
  if (!rec) {
    el("decision-responder").textContent = "—";
    el("decision-reach").textContent = "—";
    el("decision-distance").textContent = "—";
    el("decision-hazard").textContent = "—";
    el("why-text").hidden = true;
    el("decision-flags").innerHTML = "";
    el("decision-alternatives").innerHTML = "";
    return;
  }

  const chosen = rec.chosen;
  el("decision-responder").textContent = rec.recommended_responder || "none available";
  el("decision-reach").textContent = chosen
    ? `${Math.round(chosen.network_reliability * 100)}%`
    : "—";
  el("decision-distance").textContent =
    chosen && chosen.distance_m !== null
      ? chosen.distance_m >= 1000
        ? `${(chosen.distance_m / 1000).toFixed(1)} km`
        : `${Math.round(chosen.distance_m)} m`
      : "unknown";
  el("decision-hazard").textContent = chosen ? chosen.hazard_exposure : "—";

  const why = el("why-text");
  why.textContent = rec.why || "No explanation available.";
  why.hidden = !state.whyOpen;

  const flags = el("decision-flags");
  flags.innerHTML = "";
  for (const flag of rec.safety_flags || []) {
    const span = document.createElement("span");
    span.className = "flag";
    span.textContent = flag.replace(/_/g, " ").toLowerCase();
    flags.append(span);
  }
  if (rec.requires_human_approval) {
    const span = document.createElement("span");
    span.className = "flag";
    span.textContent = "requires human approval";
    flags.append(span);
  }

  const alternatives = el("decision-alternatives");
  alternatives.innerHTML = "";
  for (const alt of rec.alternatives || []) {
    if (alt.responder_id === rec.recommended_responder) continue;
    const row = document.createElement("div");
    row.className = `alt-row${alt.reachable ? "" : " unreachable"}`;
    const who = document.createElement("span");
    who.className = "who";
    who.textContent = alt.responder_id;
    const detail = document.createElement("span");
    detail.textContent =
      (alt.distance_m !== null ? `${Math.round(alt.distance_m)} m · ` : "") +
      `${Math.round(alt.network_reliability * 100)}% reliability` +
      (alt.reachable ? "" : " · unreachable");
    row.append(who, detail);
    alternatives.append(row);
  }
}

function renderActivity(data) {
  const feed = el("activity-feed");
  feed.innerHTML = "";
  for (const entry of data.activity || []) {
    const li = document.createElement("li");

    const time = document.createElement("span");
    time.className = "time";
    time.textContent = new Date(entry.at).toLocaleTimeString();

    const action = document.createElement("span");
    action.className = `action ${entry.action}`;
    action.textContent = entry.action.replace(/_/g, " ");

    const detail = document.createElement("span");
    detail.className = "detail";
    detail.textContent = entry.detail;

    li.append(time, action, detail);
    feed.append(li);
  }
  el("activity-note").textContent = data.reasoned_by
    ? `Reasoning engine: ${data.reasoned_by}`
    : "";
}

// -- polling -----------------------------------------------------------------

async function refresh() {
  const link = el("link-badge");
  try {
    const [health, world, incidents, activity] = await Promise.all([
      get("/api/v1/health"),
      get("/api/v1/world"),
      get("/api/v1/incidents"),
      get("/api/v1/activity?limit=40"),
    ]);

    link.textContent = `backend up · ${world.network.nodes_total} nodes`;
    link.className = "badge badge-model";

    renderHealth(health);
    renderNetwork(world.network);
    renderIncidents(incidents);
    renderDecision(world);
    renderActivity(activity);

    el("footer-note").textContent =
      `${API} · store ${health.store} · updated ${new Date().toLocaleTimeString()}`;
  } catch (error) {
    // Say the backend is unreachable rather than leaving stale numbers on
    // screen looking live.
    link.textContent = "backend unreachable";
    link.className = "badge badge-down";
    // Clear the engine badge too. Left on "connecting…" it reads like a
    // first attempt still in progress, and it must never still be claiming
    // Gemini is live when nothing can be reached.
    renderHealth(null);
    el("footer-note").textContent =
      `Cannot reach ${API} — ${error.message}. Showing the last known state.`;
  }
}

el("why-button").onclick = () => {
  state.whyOpen = !state.whyOpen;
  el("why-text").hidden = !state.whyOpen;
};

refresh();
setInterval(refresh, POLL_MS);
