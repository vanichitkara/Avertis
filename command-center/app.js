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
const state = {
  selected: null,
  whyOpen: false,
  lastReplan: null,
  // "all" or "devices". Simulated nodes prove scale that phones cannot;
  // real handsets prove the radio works. Showing them together without
  // saying which is which would leave a viewer unable to tell.
  nodeFilter: "all",
  // Replay position. null means live; otherwise an index into the
  // chronological activity list, so the operator can wind back through
  // what happened rather than only seeing the end state.
  replayIndex: null,
  activity: [],
  dispatching: false,
  search: "",
  severity: "ALL",
  status: "ALL",
  // Collapsed by default, and reset when the operator moves to another
  // incident — expanding one should not silently expand the next.
  evidenceOpen: false,
  alternativesOpen: false,
  // Which node the operator is inspecting, and whether the topology is
  // open full-size. A mesh of dots a few pixels apart is unreadable in a
  // column; the expanded view is where it becomes a diagram.
  selectedNode: null,
  topologyExpanded: false,
  // The last payload, kept so filtering and replay redraw from memory.
  // Re-fetching five endpoints on every keystroke made typing feel like
  // the page was struggling, for work that is entirely local.
  last: null,
};

/// Redraw from what was last fetched, without touching the network.
function rerender() {
  if (!state.last) return;
  const { health, world, incidents, activity, metrics } = state.last;
  renderHealth(health);
  renderNetwork(world.network);
  renderIncidents(incidents);
  renderDecision(world);
  renderActivity(activity);
  renderMetrics(metrics);
}

/// Damerau-Levenshtein distance, bounded so a long word cannot cost much.
///
/// Damerau rather than plain Levenshtein because it counts a transposition
/// as one edit, not two. "brigde" for "bridge" is the single most common
/// way people mistype, and under plain Levenshtein it sits two edits away
/// and finds nothing — a search an operator stops trusting after once.
function withinEditDistance(a, b, max) {
  if (Math.abs(a.length - b.length) > max) return false;

  let twoBack = null;
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);

  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    let best = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(
        previous[j] + 1,        // deletion
        current[j - 1] + 1,     // insertion
        previous[j - 1] + cost  // substitution
      );
      if (
        i > 1 && j > 1 &&
        a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]
      ) {
        current[j] = Math.min(current[j], twoBack[j - 2] + 1); // transposition
      }
      best = Math.min(best, current[j]);
    }
    if (best > max) return false;   // no path back under the limit
    twoBack = previous;
    previous = current;
  }
  return previous[b.length] <= max;
}

/// Does this incident match what was typed?
///
/// Three passes, cheapest first: the whole phrase as a substring, then
/// every word present somewhere, thenevery word within a typo of some word in
/// the text. Short words are matched exactly, because one edit on a
/// three-letter token matches almost anything.
function matchesSearch(incident, query) {
  if (!query) return true;

  const haystack = [
    incident.incident_id,
    incident.type,
    incident.severity,
    incident.status,
    incident.description,
    ...(incident.evidence || []).map((e) => e.excerpt || ""),
    ...(incident.evidence || []).map((e) => e.origin_node || ""),
  ].join(" ").toLowerCase().replace(/_/g, " ");

  const q = query.toLowerCase().trim();
  if (haystack.includes(q)) return true;

  const tokens = q.split(/\s+/).filter(Boolean);
  if (tokens.every((t) => haystack.includes(t))) return true;

  const words = haystack.split(/[^a-z0-9]+/).filter(Boolean);
  return tokens.every((token) => {
    if (haystack.includes(token)) return true;
    if (token.length < 4) return false;
    const tolerance = token.length >= 7 ? 2 : 1;
    return words.some((word) => withinEditDistance(token, word, tolerance));
  });
}

function visibleIncidents(incidents) {
  return incidents.filter(
    (i) =>
      (state.severity === "ALL" || i.severity === state.severity) &&
      (state.status === "ALL" || i.status === state.status) &&
      matchesSearch(i, state.search)
  );
}

const WRITE_KEY = new URLSearchParams(location.search).get("key") || "";

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
  const all = network.nodes || [];
  const devices = all.filter((n) => n.source === "DEVICE");
  const shown = state.nodeFilter === "devices" ? devices : all;

  // The counters describe what is on screen, so they agree with the canvas
  // rather than contradicting it.
  const reachable = shown.filter((n) => n.reachable).length;
  el("net-nodes").textContent = shown.length;
  el("net-reachable").textContent = reachable;
  // Known but not heard from recently. Shown rather than hidden: an
  // operator should be able to tell a network of 11 live nodes from a
  // network of 1 live node and 10 that have gone quiet.
  const shownIds = new Set(shown.map((n) => n.node_id));
  el("net-stale").textContent = shown.length - reachable;
  el("net-partitions").textContent = network.partitions ?? 0;
  el("net-gateways").textContent = shown.filter(
    (n) => n.role === "GATEWAY"
  ).length;

  el("filter-all").className =
    `chip${state.nodeFilter === "all" ? " chip-on" : ""}`;
  el("filter-devices").className =
    `chip${state.nodeFilter === "devices" ? " chip-on" : ""}`;
  el("filter-devices").textContent = `devices only (${devices.length})`;

  const note = el("topology-note");
  if (shown.length === 0) {
    note.textContent =
      state.nodeFilter === "devices"
        ? "No real devices have synced yet. Simulated nodes are hidden by " +
          "this filter."
        : "No topology reported yet.";
  } else if (state.nodeFilter === "devices") {
    // Link and partition counts describe the whole mesh, so quoting them
    // beside a filtered node count would read as though one device had
    // six links and sat in two partitions.
    const deviceLinks = (network.links || []).filter(
      (l) => shownIds.has(l.a) && shownIds.has(l.b)
    ).length;
    note.textContent =
      `${shown.length} real device(s), ${deviceLinks} link(s) between them. ` +
      `Whole mesh including simulated nodes: ${all.length} node(s), ` +
      `${(network.links || []).length} link(s), ` +
      `${network.partitions ?? 0} partition(s).`;
  } else {
    note.textContent =
      `${network.links.length} link(s), mean stability ` +
      `${Math.round((network.mean_link_stability || 0) * 100)}%` +
      (network.partitions > 1
        ? ` · ${network.partitions} partitions — some nodes cannot reach others`
        : " · fully connected") +
      ((network.nodes_stale ?? 0) > 0
        ? ` · ${network.nodes_stale} node(s) not heard from recently`
        : "") +
      (state.nodeFilter === "all" && devices.length !== all.length
        ? ` · ${devices.length} real device(s), ` +
          `${all.length - devices.length} simulated`
        : "");
  }
  const view = {
    ...network,
    nodes: shown,
    links: (network.links || []).filter(
      (l) => shownIds.has(l.a) && shownIds.has(l.b)
    ),
  };
  // Kept so the expanded view and the node panel work from exactly what
  // the canvas drew, filter included.
  state.networkView = view;

  const spread = drawTopology(view, el("topology"));
  if (spread) note.textContent = `${note.textContent} · ${spread}`;

  if (state.topologyExpanded) {
    drawTopology(view, el("topology-large"), {
      height: Math.max(420, Math.round(window.innerHeight * 0.6)),
    });
    el("topology-large-note").textContent = note.textContent;
  }

  // A node can disappear between polls — a filter change, or it stopped
  // being reported. Drop the selection rather than showing a stale card.
  if (state.selectedNode && !shownIds.has(state.selectedNode)) {
    state.selectedNode = null;
  }
  const selected = shown.find((n) => n.node_id === state.selectedNode) || null;
  renderNodeDetail(el("node-detail"), selected, view);
}

const PARTITION_COLOURS = [
  "#3da5ff", "#ff8a3d", "#00d9a3", "#c77dff", "#ffc53d", "#ff4438",
];

/// Distance in metres between two reported positions (haversine).
function metresBetween(a, b) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/// Where each node goes, and what had to be done to make it visible.
///
/// Geography first, because the picture should match the ground. But
/// phones in one building are metres apart, and metres apart at this
/// scale is the same pixel: four of five nodes drew on top of each other
/// and the operator saw one blob. So after placing them, markers that
/// still collide are pushed apart.
///
/// The nudging is reported rather than hidden. A map that silently moves
/// things is worse than one that says it had to: "spread apart to be
/// legible — they are within 12 m of each other" tells the operator both
/// that the layout is approximate and the real figure.
function layoutTopology(network, width, height, radiusOf, extentOf) {
  const nodes = network.nodes || [];
  const positions = {};
  const pad = 34;
  if (nodes.length === 0) return { positions, note: "" };

  const located = nodes.filter((n) => n.location);
  const onCircle = (i, n) => {
    const angle = (i / Math.max(n, 1)) * Math.PI * 2 - Math.PI / 2;
    const rx = (width - 2 * pad) / 2;
    const ry = (height - 2 * pad) / 2;
    return {
      x: width / 2 + Math.cos(angle) * rx,
      y: height / 2 + Math.sin(angle) * ry,
    };
  };

  if (located.length >= 2) {
    const lats = located.map((n) => n.location.lat);
    const lons = located.map((n) => n.location.lon);
    const minLat = Math.min(...lats), maxLat = Math.max(...lats);
    const minLon = Math.min(...lons), maxLon = Math.max(...lons);
    const spanLat = maxLat - minLat || 1e-9;
    const spanLon = maxLon - minLon || 1e-9;

    let unlocated = 0;
    const unlocatedTotal = nodes.length - located.length;
    nodes.forEach((n) => {
      if (n.location) {
        positions[n.node_id] = {
          x: pad + ((n.location.lon - minLon) / spanLon) * (width - 2 * pad),
          // North is up, so latitude inverts against screen y.
          y: pad + (1 - (n.location.lat - minLat) / spanLat) * (height - 2 * pad),
          located: true,
        };
      } else {
        // Nodes with no position go along the bottom, kept clear of the
        // mapped ones so their placement is never read as a location.
        const slot = (unlocated + 1) / (unlocatedTotal + 1);
        positions[n.node_id] = {
          x: pad + slot * (width - 2 * pad),
          y: height - pad / 2,
          located: false,
        };
        unlocated += 1;
      }
    });
  } else {
    nodes.forEach((n, i) => {
      positions[n.node_id] = { ...onCircle(i, nodes.length), located: false };
    });
  }

  // Push overlapping markers apart. What has to clear is not the dot but
  // the dot *and its label*: six monospace characters are far wider than
  // the marker, so separating on radius alone left names written over one
  // another. Each node therefore claims an ellipse — wide enough for its
  // label, tall enough for the lines under it — and pairs are relaxed in
  // that normalised space.
  //
  // A handful of passes is plenty for the node counts this ever shows,
  // and the result is deterministic, so the picture does not jitter
  // between polls.
  let moved = 0;
  let closestMetres = Infinity;
  for (let pass = 0; pass < 80; pass++) {
    let shifted = false;
    for (let i = 0; i < nodes.length; i++) {
      for (let j = i + 1; j < nodes.length; j++) {
        const a = positions[nodes[i].node_id];
        const b = positions[nodes[j].node_id];
        if (!a || !b) continue;
        const ea = extentOf(nodes[i]);
        const eb = extentOf(nodes[j]);
        const rx = ea.x + eb.x;
        const ry = ea.y + eb.y;

        let dx = b.x - a.x;
        let dy = b.y - a.y;
        let d = Math.hypot(dx / rx, dy / ry);
        if (d >= 1) continue;
        if (d < 0.001) {
          // Exactly coincident: separate along a fixed angle per pair so
          // the outcome is stable rather than flickering each frame.
          const angle = ((i * 97 + j * 53) % 360) * (Math.PI / 180);
          dx = Math.cos(angle) * rx;
          dy = Math.sin(angle) * ry;
          d = 0.001;
        }
        // Move each endpoint half the shortfall, in real pixels.
        const scale = (1 - d) / 2;
        a.x -= dx * scale; a.y -= dy * scale;
        b.x += dx * scale; b.y += dy * scale;
        shifted = true;
        if (pass === 0) {
          moved++;
          if (nodes[i].location && nodes[j].location) {
            closestMetres = Math.min(
              closestMetres,
              metresBetween(nodes[i].location, nodes[j].location)
            );
          }
        }
      }
    }
    for (const node of nodes) {
      const p = positions[node.node_id];
      if (!p) continue;
      const e = extentOf(node);
      p.x = Math.min(width - e.x, Math.max(e.x, p.x));
      p.y = Math.min(height - e.y, Math.max(radiusOf(node) + 6, p.y));
    }
    if (!shifted) break;
  }

  let note = "";
  if (moved > 0) {
    note = Number.isFinite(closestMetres)
      ? `Markers spread apart to stay legible — the closest pair is about ` +
        `${closestMetres < 1 ? "under a metre" : Math.round(closestMetres) + " m"} ` +
        `apart on the ground.`
      : "Markers spread apart to stay legible.";
  }
  return { positions, note };
}

/// The second line under a node in the expanded view. Shared with the
/// layout, because the text it has to clear is wider than the node id and
/// clamping on the id alone cropped "survivor" to "urvivor" at the edge.
function nodeSubtitle(node) {
  const bits = [node.role.toLowerCase()];
  if (node.source === "DEVICE") bits.push("device");
  if (!node.reachable) bits.push("gone quiet");
  return bits.join(" · ");
}

function nodeRadius(node) {
  if (node.role === "GATEWAY") return 11;
  if (node.role === "RESPONDER") return 9;
  return 7;
}

/// What is under the pointer, so hover and click agree with what is drawn.
const hitRegions = new WeakMap();

function drawTopology(network, canvas, opts = {}) {
  canvas = canvas || el("topology");
  const ctx = canvas.getContext("2d");

  // Match the backing store to the element's real size in device pixels.
  // It was a fixed 560x320 stretched by CSS to whatever width the column
  // happened to be, which is why everything looked soft.
  const dpr = window.devicePixelRatio || 1;
  const cssWidth = canvas.clientWidth || 560;
  const cssHeight = opts.height || Math.round(cssWidth * 0.58);
  if (canvas.style.height !== `${cssHeight}px`) {
    canvas.style.height = `${cssHeight}px`;
  }
  const pxWidth = Math.round(cssWidth * dpr);
  const pxHeight = Math.round(cssHeight * dpr);
  if (canvas.width !== pxWidth || canvas.height !== pxHeight) {
    canvas.width = pxWidth;
    canvas.height = pxHeight;
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cssWidth, cssHeight);

  const nodes = network.nodes || [];
  hitRegions.set(canvas, []);
  if (nodes.length === 0) return "";

  const big = cssWidth > 700;
  const radiusOf = (n) => nodeRadius(n) * (big ? 1.25 : 1);

  // How much room a node needs around its centre, label included. The id
  // is monospace, so its width is predictable from its length without
  // measuring every frame.
  const labelPx = big ? 13 : 11;
  const charPx = labelPx * 0.62;
  const subPx = 11 * 0.52;
  const extentOf = (n) => ({
    x:
      Math.max(
        radiusOf(n),
        (n.node_id.length * charPx) / 2,
        big ? (nodeSubtitle(n).length * subPx) / 2 : 0
      ) + 10,
    y: radiusOf(n) + labelPx + (big ? 18 : 2) + 10,
  });

  const { positions, note } =
    layoutTopology(network, cssWidth, cssHeight, radiusOf, extentOf);

  // Links first, so nodes sit on top. Thickness and opacity carry stability.
  for (const link of network.links || []) {
    const a = positions[link.a];
    const b = positions[link.b];
    if (!a || !b) continue;
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.strokeStyle = `rgba(136,151,168,${0.25 + link.stability * 0.6})`;
    ctx.lineWidth = 1 + link.stability * 3;
    ctx.stroke();

    if (big) {
      // There is room at this size to say how good the link is, which is
      // the number the responder recommendation actually turns on.
      const mx = (a.x + b.x) / 2;
      const my = (a.y + b.y) / 2;
      ctx.fillStyle = "#6b7a8f";
      ctx.font = "11px ui-monospace, monospace";
      ctx.textAlign = "center";
      ctx.fillText(`${Math.round(link.stability * 100)}%`, mx, my - 5);
    }
  }

  const partitionOf = network.partition_of || {};
  const regions = [];
  for (const node of nodes) {
    const p = positions[node.node_id];
    if (!p) continue;
    const partition = partitionOf[node.node_id];
    const colour =
      partition === null || partition === undefined
        ? "#6b7a8f"
        : PARTITION_COLOURS[partition % PARTITION_COLOURS.length];

    const radius = radiusOf(node);
    const selected = state.selectedNode === node.node_id;

    if (selected) {
      ctx.beginPath();
      ctx.arc(p.x, p.y, radius + 6, 0, Math.PI * 2);
      ctx.strokeStyle = colour;
      ctx.lineWidth = 1;
      ctx.stroke();
    }

    // Two things have to be readable at a glance, and they must not be
    // confusable with each other: whether a node is still being heard
    // from, and whether it is a gateway.
    //
    // Hollow meant "gone quiet" and a gateway was drawn as a ring, so a
    // live gateway and a silent survivor looked the same. Reachability is
    // now carried by the outline — solid for heard-from, dashed for
    // not — which nothing else uses.
    ctx.beginPath();
    ctx.arc(p.x, p.y, radius, 0, Math.PI * 2);
    ctx.fillStyle = node.reachable ? colour : "#0a0d12";
    ctx.fill();
    ctx.setLineDash(node.reachable ? [] : [3, 3]);
    ctx.strokeStyle = colour;
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.setLineDash([]);

    // A gateway is the way out of the mesh, so it earns a mark of its
    // own: a hole through the middle, which only reads on a filled
    // marker and so never collides with the dashed outline above.
    if (node.role === "GATEWAY" && node.reachable) {
      ctx.beginPath();
      ctx.arc(p.x, p.y, radius - 4.5, 0, Math.PI * 2);
      ctx.fillStyle = "#0a0d12";
      ctx.fill();
    } else if (node.role === "GATEWAY") {
      ctx.beginPath();
      ctx.arc(p.x, p.y, Math.max(1.5, radius - 6), 0, Math.PI * 2);
      ctx.fillStyle = colour;
      ctx.fill();
    }

    // Every node is named now. Labelling only gateways and responders
    // left most of the mesh as anonymous dots.
    ctx.fillStyle = selected ? "#e8eef6" : "#8b97a8";
    ctx.font = `${big ? 13 : 11}px ui-monospace, monospace`;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.fillText(node.node_id, p.x, p.y + radius + 4);

    if (big) {
      ctx.fillStyle = "#6b7a8f";
      ctx.font = "11px ui-sans-serif, sans-serif";
      ctx.fillText(nodeSubtitle(node), p.x, p.y + radius + 20);
    }

    regions.push({ x: p.x, y: p.y, r: radius + 8, node });
  }

  hitRegions.set(canvas, regions);
  return note;
}

function nodeAt(canvas, clientX, clientY) {
  const rect = canvas.getBoundingClientRect();
  const x = clientX - rect.left;
  const y = clientY - rect.top;
  let best = null;
  let bestD = Infinity;
  for (const region of hitRegions.get(canvas) || []) {
    const d = Math.hypot(region.x - x, region.y - y);
    if (d <= region.r && d < bestD) {
      best = region.node;
      bestD = d;
    }
  }
  return best;
}

/// Everything this backend knows about one node, and nothing it does not.
function nodeFacts(node, network) {
  const partition = (network.partition_of || {})[node.node_id];
  const links = (network.links || []).filter(
    (l) => l.a === node.node_id || l.b === node.node_id
  );
  const pct = (v) => `${Math.round(v * 100)}%`;
  const facts = [
    ["Role", node.role.toLowerCase()],
    ["Source", node.source === "DEVICE" ? "real handset" : "simulated"],
    ["Reachable", node.reachable ? "yes" : "no — not heard from recently"],
    [
      "Partition",
      partition === null || partition === undefined
        ? "unknown"
        : `#${partition}`,
    ],
    [
      "Battery",
      node.battery === null || node.battery === undefined
        ? "not reported"
        : pct(node.battery),
    ],
    [
      "Hops to a gateway",
      // A gateway is the way out, so it is never "no route" to itself —
      // it reports no distance because the question does not apply.
      node.role === "GATEWAY" || node.gateway_distance === 0
        ? "it is one"
        : node.gateway_distance === null || node.gateway_distance === undefined
          ? "no route to a gateway"
          : `${node.gateway_distance}`,
    ],
    ["Links", links.length ? `${links.length}` : "none"],
    [
      "Mean link stability",
      links.length
        ? pct(links.reduce((s, l) => s + l.stability, 0) / links.length)
        : "no links to measure",
    ],
    ["Queued packets", `${node.queue_depth ?? 0}`],
    [
      "Position",
      node.location
        ? `${node.location.lat.toFixed(5)}, ${node.location.lon.toFixed(5)}` +
          (node.location.accuracy_m
            ? ` (±${Math.round(node.location.accuracy_m)} m)`
            : "")
        : "not reported",
    ],
    ["Last heard", node.received_at ? whenText(node.received_at) : "unknown"],
  ];
  return facts;
}

function renderNodeDetail(container, node, network) {
  if (!node) {
    container.innerHTML =
      '<p class="muted small">Select a node to see what the command ' +
      "centre knows about it.</p>";
    return;
  }
  const rows = nodeFacts(node, network)
    .map(
      ([label, value]) =>
        `<div class="node-fact"><span class="k">${label}</span>` +
        `<span class="v">${value}</span></div>`
    )
    .join("");
  const neighbours = (node.neighbors || []).length
    ? node.neighbors.join(", ")
    : "none reported";
  container.innerHTML =
    `<h3 class="node-title">${node.node_id}</h3>` +
    `<div class="node-facts">${rows}</div>` +
    `<p class="muted small">Neighbours: ${neighbours}</p>`;
}

function renderIncidents(data) {
  const counts = data.by_severity || {};
  el("inc-crit").textContent = counts.LIFE_CRITICAL || 0;
  el("inc-emer").textContent = counts.EMERGENCY || 0;
  el("inc-oper").textContent = counts.OPERATIONAL || 0;
  el("inc-norm").textContent = counts.NORMAL || 0;

  const incidents = data.incidents || [];
  // Counted across everything, not the filtered view: these are the
  // headline figures for the whole situation, and a filter narrowing them
  // would make the operator think incidents had gone away.
  el("inc-dispatched").textContent = incidents.filter(
    (i) => i.status === "DISPATCHED"
  ).length;

  for (const button of document.querySelectorAll("[data-sev]")) {
    button.className =
      `chip${button.dataset.sev === state.severity ? " chip-on" : ""}`;
  }
  for (const button of document.querySelectorAll("[data-status]")) {
    button.className =
      `chip${button.dataset.status === state.status ? " chip-on" : ""}`;
  }

  const fused = incidents.filter((i) => i.evidence.length > 1);
  const absorbed = fused.reduce((sum, i) => sum + i.evidence.length - 1, 0);
  el("fusion-note").textContent = absorbed
    ? `${absorbed} duplicate report(s) absorbed into ${fused.length} incident(s).`
    : "";

  const list = el("incident-list");
  list.innerHTML = "";

  const shown = visibleIncidents(incidents);
  const filtering =
    state.search || state.severity !== "ALL" || state.status !== "ALL";

  if (filtering) {
    const note = document.createElement("li");
    note.className = "filter-note";
    note.textContent = shown.length
      ? `Showing ${shown.length} of ${incidents.length}`
      : `Nothing matches. ${incidents.length} incident(s) hidden by the ` +
        `current filters.`;
    list.append(note);
  }

  for (const incident of shown) {
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

    const when = document.createElement("span");
    when.className = "when";
    when.textContent = whenText(incident.created_at);

    li.append(dot, who, what, when);
    li.onclick = () => {
      if (state.selected !== incident.incident_id) {
        state.evidenceOpen = false;
        state.alternativesOpen = false;
      }
      state.selected = incident.incident_id;
      state.whyOpen = false;
      refresh();
    };
    list.append(li);
  }
}

/// When something happened, in the form an operator actually needs.
///
/// Absolute time for the record, and elapsed time because that is what
/// drives urgency — "14:02" says less than "22 min ago" when deciding
/// what to look at next.
function whenText(iso) {
  if (!iso) return "time unknown";
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return "time unknown";

  const seconds = Math.max(0, (Date.now() - then.getTime()) / 1000);
  const clock = then.toLocaleTimeString([], {
    hour: "2-digit", minute: "2-digit",
  });

  if (seconds < 90) return `${clock} · just now`;
  if (seconds < 3600) return `${clock} · ${Math.round(seconds / 60)} min ago`;
  if (seconds < 86400) {
    return `${clock} · ${Math.round(seconds / 3600)} h ago`;
  }
  return `${then.toLocaleDateString()} ${clock}`;
}

function severityColour(severity) {
  return {
    LIFE_CRITICAL: "#ff4438",
    EMERGENCY: "#ff8a3d",
    OPERATIONAL: "#ffc53d",
    NORMAL: "#6b7a8f",
  }[severity] || "#6b7a8f";
}

function priorityLabel(priority) {
  return (priority || "unknown").replace(/_/g, " ").toLowerCase();
}

function renderDecision(world) {
  // Follow the filters: showing a decision for an incident the operator
  // has just filtered out reads as the panel ignoring them.
  const all = world.physical.incidents || [];
  const incidents = visibleIncidents(all);
  if (incidents.length === 0) {
    el("decision").hidden = true;
    el("decision-empty").hidden = false;
    el("decision-empty").textContent = all.length
      ? "No incident matches the current filters."
      : "No incidents yet. Waiting for a gateway sync.";
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
  const reportedPriorities = [...new Set(
    (chosenIncident.evidence || [])
      .map((e) => e.priority)
      .filter(Boolean)
  )];
  const reported = reportedPriorities.length
    ? reportedPriorities.map(priorityLabel).join(", ")
    : "unknown";
  const assessed = priorityLabel(chosenIncident.severity);
  el("decision-when").textContent =
    `Reported ${whenText(chosenIncident.created_at)}`;
  el("decision-sources").textContent =
    `${chosenIncident.evidence.length} source(s) · confidence ` +
    `${Math.round(chosenIncident.confidence * 100)}% · ` +
    (people === null || people === undefined
      ? "headcount unknown"
      : `${people} affected`) +
    ` · reported ${reported}` +
    (reportedPriorities.length === 1 && reportedPriorities[0] === chosenIncident.severity
      ? ""
      : ` · assessed ${assessed}`);

  el("decision-desc").textContent = chosenIncident.description || "(no description)";
  renderEvidence(chosenIncident);

  // Dispatch state follows the incident, so an already-approved one does
  // not invite a second approval.
  const dispatched = chosenIncident.status === "DISPATCHED";
  el("dispatch-button").disabled = dispatched || state.dispatching;
  el("dispatch-button").textContent = dispatched
    ? "DISPATCHED"
    : "APPROVE & DISPATCH";

  const rec = (world.recommendations || {})[chosenIncident.incident_id];
  if (!rec) {
    el("decision-responder").textContent = "—";
    el("decision-reach").textContent = "—";
    el("decision-distance").textContent = "—";
    el("decision-hazard").textContent = "—";
    el("why-text").hidden = true;
    el("decision-flags").innerHTML = "";
    el("decision-alternatives").innerHTML = "";
    el("decision-alternatives").hidden = true;
    // Nothing was recommended, so there is nothing behind the fold and
    // the control should say so rather than invite a click.
    el("alternatives-label").textContent = "No recommendation yet";
    el("alternatives-toggle").disabled = true;
    el("alternatives-toggle").setAttribute("aria-expanded", "false");
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

  const others = (rec.alternatives || []).filter(
    (a) => a.responder_id !== rec.recommended_responder
  );
  const unreachable = others.filter((a) => !a.reachable).length;

  // Summarise what is behind the fold, including how many could not be
  // reached — that is the detail that justifies the recommendation.
  el("alternatives-label").textContent = others.length === 0
    ? "No other responder was available"
    : (state.alternativesOpen ? "Hide" : "Show") +
      ` other responders considered (${others.length}` +
      (unreachable ? `, ${unreachable} unreachable` : "") + ")";
  el("alternatives-toggle").disabled = others.length === 0;
  el("alternatives-toggle").setAttribute("aria-expanded",
    String(state.alternativesOpen));
  alternatives.hidden = !state.alternativesOpen;
  if (!state.alternativesOpen) return;

  for (const alt of others) {
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

function renderSummary(data) {
  const panel = el("summary-panel");
  const text = (data && data.summary) || "";
  // Hidden rather than showing an empty box before anything has happened.
  panel.hidden = !text;
  el("summary-text").textContent = text;
  // written_by is not always the configured engine — a model call that
  // times out falls back to the rules, and crediting the model for a
  // sentence it did not write would be the same misrepresentation the
  // header badge exists to prevent.
  const by = data && data.written_by;
  el("summary-by").textContent = by
    ? (by === "deterministic"
        ? "Written by rules — the model did not answer in time"
        : `Written by ${by}`)
    : "";
}

function renderMetrics(m) {
  el("m-reports").textContent = m.reports_total ?? 0;
  el("m-incidents").textContent = m.incidents_total ?? 0;
  el("m-absorbed").textContent = m.duplicate_reports_absorbed ?? 0;
  el("m-fused").textContent = m.incidents_fused ?? 0;
  el("m-media").textContent = m.media_stored ?? 0;

  const absorbed = m.duplicate_reports_absorbed ?? 0;
  el("m-note").textContent = absorbed
    ? `${m.reports_total} report(s) from the field became ` +
      `${m.incidents_total} incident(s) — ${absorbed} duplicate account(s) ` +
      `of events already known, absorbed rather than shown twice.`
    : "No duplicate reports yet.";
}

function renderEvidence(incident) {
  const box = el("evidence");
  const items = el("evidence-items");
  items.innerHTML = "";

  // Media descriptors live on the evidence of each source report.
  const media = (incident.evidence || []).flatMap((e) => e.media || []);
  box.hidden = media.length === 0;

  // The count is on the button, so a collapsed section never hides the
  // fact that there is something to look at.
  el("evidence-label").textContent = state.evidenceOpen
    ? `Hide evidence (${media.length})`
    : `Show evidence (${media.length})`;
  el("evidence-toggle").setAttribute("aria-expanded",
    String(state.evidenceOpen));
  items.hidden = !state.evidenceOpen;
  if (!state.evidenceOpen) return;

  for (const m of media) {
    if ((m.kind || "IMAGE") === "IMAGE") {
      const link = document.createElement("a");
      link.href = `${API}/api/v1/media/${m.media_id}`;
      link.target = "_blank";
      const img = document.createElement("img");
      img.src = `${API}/api/v1/media/${m.media_id}`;
      img.alt = `Evidence ${m.media_id}`;
      // The record can outlive the file. Say so rather than leaving a
      // broken image, which reads as a bug rather than missing evidence.
      img.onerror = () => {
        link.replaceWith(
          Object.assign(document.createElement("div"), {
            className: "audio",
            textContent: "image not retrievable",
          })
        );
      };
      link.append(img);
      items.append(link);
    } else {
      const chip = document.createElement("div");
      chip.className = "audio";
      chip.textContent = m.duration_s
        ? `voice ${m.duration_s}s`
        : "voice report";
      items.append(chip);
    }
  }
}

async function dispatchSelected() {
  if (!state.selected || state.dispatching) return;
  state.dispatching = true;
  el("dispatch-button").disabled = true;
  el("dispatch-state").textContent = "approving…";

  try {
    const response = await fetch(
      `${API}/api/v1/incidents/${state.selected}/dispatch`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(WRITE_KEY ? { "X-Avertis-Key": WRITE_KEY } : {}),
        },
        body: JSON.stringify({ approved_by: "command centre operator" }),
      }
    );
    if (!response.ok) {
      el("dispatch-state").textContent =
        response.status === 401
          ? "needs the write key — open the dashboard with ?key=…"
          : `could not approve (${response.status})`;
      return;
    }
    const body = await response.json();
    el("dispatch-state").textContent =
      `dispatched ${body.responder_id} at ` +
      new Date(body.approved_at).toLocaleTimeString();
  } catch (error) {
    el("dispatch-state").textContent = "could not reach the backend";
  } finally {
    state.dispatching = false;
    el("dispatch-button").disabled = false;
    refresh();
  }
}

function renderActivity(data) {
  const feed = el("activity-feed");
  feed.innerHTML = "";

  // The API returns newest first; replay reads naturally oldest-first.
  const chronological = [...(data.activity || [])].reverse();
  state.activity = chronological;

  const slider = el("replay-slider");
  slider.max = String(Math.max(0, chronological.length - 1));
  const live = state.replayIndex === null;
  if (live) slider.value = slider.max;

  const upTo = live ? chronological.length : state.replayIndex + 1;
  const visible = chronological.slice(0, upTo).reverse();

  el("replay-live").className = `chip${live ? " chip-on" : ""}`;
  el("replay-at").textContent = live
    ? "following live"
    : chronological[state.replayIndex]
      ? `at ${new Date(chronological[state.replayIndex].at)
          .toLocaleTimeString()} · ${upTo}/${chronological.length}`
      : "";

  for (const entry of visible) {
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
    const [health, world, incidents, activity, metrics] = await Promise.all([
      get("/api/v1/health"),
      get("/api/v1/world"),
      get("/api/v1/incidents"),
      get("/api/v1/activity?limit=60"),
      get("/api/v1/metrics"),
    ]);

    // The summary is fetched separately and never awaited here. On a cache
    // miss it costs a model call — measured at 14 seconds — and inside the
    // batch above that left the whole dashboard blank for the duration,
    // which reads as a broken page rather than a pending sentence.
    void get("/api/v1/summary").then(renderSummary).catch(() => {});

    link.textContent = `backend up · ${world.network.nodes_total} nodes`;
    link.className = "badge badge-model";

    state.last = { health, world, incidents, activity, metrics };
    rerender();

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

el("evidence-toggle").onclick = () => {
  state.evidenceOpen = !state.evidenceOpen;
  rerender();
};
el("alternatives-toggle").onclick = () => {
  state.alternativesOpen = !state.alternativesOpen;
  rerender();
};

el("incident-search").oninput = (event) => {
  state.search = event.target.value;
  rerender();
};
for (const button of document.querySelectorAll("[data-sev]")) {
  button.onclick = () => { state.severity = button.dataset.sev; rerender(); };
}
for (const button of document.querySelectorAll("[data-status]")) {
  button.onclick = () => { state.status = button.dataset.status; rerender(); };
}

el("dispatch-button").onclick = dispatchSelected;

el("replay-slider").oninput = (event) => {
  const index = Number(event.target.value);
  // Dragging to the end means "follow live" again, which is what a
  // scrubber at its right-hand stop should mean.
  state.replayIndex =
    index >= state.activity.length - 1 ? null : index;
  rerender();
};
el("replay-live").onclick = () => {
  state.replayIndex = null;
  rerender();
};

el("filter-all").onclick = () => {
  state.nodeFilter = "all";
  rerender();
};
el("filter-devices").onclick = () => {
  state.nodeFilter = "devices";
  rerender();
};

el("why-button").onclick = () => {
  state.whyOpen = !state.whyOpen;
  el("why-text").hidden = !state.whyOpen;
};

/* -- the topology: inspecting a node, and seeing it full size -- */

function selectNodeFrom(canvas, event) {
  const node = nodeAt(canvas, event.clientX, event.clientY);
  // Clicking empty space clears, so there is a way back out without
  // hunting for a close button.
  state.selectedNode = node ? node.node_id : null;
  rerender();
}

function hoverOn(canvas, tooltip) {
  canvas.onmousemove = (event) => {
    const node = nodeAt(canvas, event.clientX, event.clientY);
    canvas.style.cursor = node ? "pointer" : "default";
    if (!node) {
      tooltip.hidden = true;
      return;
    }
    const network = state.networkView || { links: [] };
    const links = (network.links || []).filter(
      (l) => l.a === node.node_id || l.b === node.node_id
    );
    tooltip.innerHTML =
      `<strong>${node.node_id}</strong> · ${node.role.toLowerCase()}` +
      `<br>${node.source === "DEVICE" ? "real handset" : "simulated"}` +
      ` · ${node.reachable ? "reachable" : "gone quiet"}` +
      `<br>battery ${
        node.battery === null || node.battery === undefined
          ? "not reported"
          : Math.round(node.battery * 100) + "%"
      } · ${links.length} link(s)` +
      `<br>${
        node.role === "GATEWAY" || node.gateway_distance === 0
          ? "is a gateway"
          : node.gateway_distance
            ? node.gateway_distance + " hop(s) to a gateway"
            : "no route to a gateway"
      }`;
    const rect = canvas.getBoundingClientRect();
    tooltip.hidden = false;
    // Keep it inside the canvas, so a node near the right edge does not
    // push the tooltip off the panel.
    const tipWidth = tooltip.offsetWidth || 190;
    const x = Math.min(
      rect.width - tipWidth - 8,
      Math.max(8, event.clientX - rect.left + 14)
    );
    tooltip.style.left = `${x}px`;
    tooltip.style.top = `${event.clientY - rect.top + 14}px`;
  };
  canvas.onmouseleave = () => {
    tooltip.hidden = true;
  };
}

for (const [canvasId, tipId] of [
  ["topology", "topology-tip"],
  ["topology-large", "topology-large-tip"],
]) {
  const canvas = el(canvasId);
  canvas.onclick = (event) => selectNodeFrom(canvas, event);
  hoverOn(canvas, el(tipId));
}

function setTopologyExpanded(open) {
  state.topologyExpanded = open;
  el("topology-overlay").hidden = !open;
  document.body.classList.toggle("no-scroll", open);
  rerender();
}

el("topology-expand").onclick = () => setTopologyExpanded(true);
el("topology-close").onclick = () => setTopologyExpanded(false);
el("topology-overlay").onclick = (event) => {
  // Only the backdrop closes it. A click inside is aimed at the diagram.
  if (event.target === el("topology-overlay")) setTopologyExpanded(false);
};
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && state.topologyExpanded) {
    setTopologyExpanded(false);
  }
});

// The canvas is sized from its element, so a resized window needs a redraw
// or the picture stays at the old width and goes soft again.
let resizeTimer = null;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(rerender, 120);
});

refresh();
setInterval(refresh, POLL_MS);
