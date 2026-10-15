"use strict";

// Computed evidence, view state and user decisions are independent. No document data leaves this process.
const GraphState = (() => {
  const matchTypes = Object.freeze(["visual", "face", "audio", "ocr", "metadata"]);
  const statuses = new Set(["unverified", "confirmed", "rejected"]);
  const pairKey = (from, to) => JSON.stringify([from, to].sort());
  const fileVersion = (node) => [node.path, node.modified ?? null, node.size ?? null];
  const nodeKey = (node, code = false) => JSON.stringify([!!code, ...fileVersion(node)]);
  const evidenceOf = (hit) => (hit.match_evidence || []).filter((e) => matchTypes.includes(e.type)
    && (e.type === "metadata" ? typeof e.value === "string" && !!e.value : Number.isFinite(e.cosine) && e.cosine >= -1 && e.cosine <= 1));
  const reviewKey = (edge, nodes, source, code = false) => JSON.stringify([!!code, source,
    fileVersion(nodes.get(edge.from)), fileVersion(nodes.get(edge.to)), edge.similarityScore,
    edge.anchorSegment ?? null, edge.evidenceFrom, edge.evidence]);
  const fold = (value) => String(value).normalize("NFKC").toLocaleLowerCase();

  class InvestigationState {
    constructor(data = { schemaVersion: 1, nodes: {}, edges: {} }) {
      if (data.schemaVersion !== 1) throw new Error("Unsupported investigation state");
      this.nodes = new Map(Object.entries(data.nodes || {})); this.edges = new Map(Object.entries(data.edges || {}));
    }
    annotation(node, code) { return this.nodes.get(nodeKey(node, code)); }
    annotate(node, code, patch) {
      const key = nodeKey(node, code), value = { hidden: false, pinned: null, ...this.nodes.get(key), ...patch };
      if (!value.hidden && !value.pinned) this.nodes.delete(key); else this.nodes.set(key, value);
      return value;
    }
    status(key) { const value = this.edges.get(key); return statuses.has(value) ? value : "unverified"; }
    verify(key, status) {
      if (!statuses.has(status)) throw new Error("Invalid edge status");
      if (status === "unverified") this.edges.delete(key); else this.edges.set(key, status);
    }
    serialize() { return { schemaVersion: 1, nodes: Object.fromEntries(this.nodes), edges: Object.fromEntries(this.edges) }; }
  }

  function visibleEdges(model, { modality = "all", showRejected = false } = {}) {
    return [...model.edges.values()].filter((e) => !model.nodes.get(e.from)?.hidden && !model.nodes.get(e.to)?.hidden
      && (showRejected || e.status !== "rejected") && (modality === "all" || e.matchTypes.includes(modality)));
  }

  function shortestPath(model, from, to, options = {}) {
    if (!model.nodes.has(from) || !model.nodes.has(to) || model.nodes.get(from).hidden || model.nodes.get(to).hidden) return null;
    const adjacency = new Map();
    for (const edge of visibleEdges(model, options).filter((e) => e.status !== "rejected")) {
      for (const [a, b] of [[edge.from, edge.to], [edge.to, edge.from]]) {
        if (!adjacency.has(a)) adjacency.set(a, []); adjacency.get(a).push(b);
      }
    }
    const previous = new Map([[from, null]]), queue = [from];
    for (let i = 0; i < queue.length; i++) {
      const current = queue[i]; if (current === to) break;
      for (const next of adjacency.get(current) || []) if (!previous.has(next)) { previous.set(next, current); queue.push(next); }
    }
    if (!previous.has(to)) return null;
    const paths = []; for (let at = to; at !== null; at = previous.get(at)) paths.push(at);
    return paths.reverse();
  }

  function timelineLayout(nodes) {
    const values = [...nodes].filter((n) => !n.hidden), known = values.filter((n) => Number.isFinite(n.modified) && n.modified > 0);
    const low = Math.min(...known.map((n) => n.modified)), high = Math.max(...known.map((n) => n.modified));
    const span = Math.max(900, values.length * 140), lanes = [];
    const sorted = values.slice().sort((a, b) => (a.modified || Infinity) - (b.modified || Infinity) || a.path.localeCompare(b.path));
    const result = new Map();
    for (const node of sorted) {
      if (Number.isFinite(node.fx) && Number.isFinite(node.fy)) { result.set(node.path, { x: node.fx, y: node.fy }); continue; }
      const x = !Number.isFinite(node.modified) || node.modified <= 0 ? span / 2 + 380 : high > low ? (node.modified - low) / (high - low) * span - span / 2 : 0;
      let lane = lanes.findIndex((last) => x - last >= 330); if (lane < 0) lane = lanes.length;
      lanes[lane] = x;
      const y = (lane % 2 ? -1 : 1) * Math.ceil(lane / 2) * 140;
      // Fixed cards remain fixed; route movable timeline cards to another lane if needed.
      let point = { x, y };
      const occupied = [...result.values(), ...values.filter((n) => Number.isFinite(n.fx) && Number.isFinite(n.fy)).map((n) => ({ x: n.fx, y: n.fy }))];
      while (occupied.some((p) => Math.abs(p.x - point.x) < 320 && Math.abs(p.y - point.y) < 124)) point.y += 140;
      result.set(node.path, point);
    }
    return result;
  }
  return { InvestigationState, matchTypes, pairKey, nodeKey, reviewKey, evidenceOf, visibleEdges, shortestPath, timelineLayout, fold };
})();
if (typeof module !== "undefined") module.exports = GraphState;
