"use strict";
const GS = typeof module !== "undefined" ? require("./graph-state.js") : GraphState;

const GRAPH_CARD = Object.freeze({ width: 244, height: 72, gapX: 76, gapY: 52 });
const separated = (a, b, pad = true) => Math.abs(a.x - b.x) >= GRAPH_CARD.width + (pad ? GRAPH_CARD.gapX : 0)
  || Math.abs(a.y - b.y) >= GRAPH_CARD.height + (pad ? GRAPH_CARD.gapY : 0);

// Bounded force relaxation with radial anchors; existing nodes stay pinned between expansions.
// Positions are topology, never a metric interpretation of cosine similarity.
function settleGraph(nodes, edges, added) {
  const all = [...nodes.values()], moving = all.filter((n) => added.has(n.path) && !Number.isFinite(n.fx));
  for (let tick = 0; tick < 40; tick++) {
    for (const node of moving) {
      let fx = (node.anchor.x - node.x) * 0.08, fy = (node.anchor.y - node.y) * 0.08;
      for (const other of all) {
        if (other === node) continue;
        const dx = node.x - other.x, dy = node.y - other.y, d2 = Math.max(1600, dx * dx + dy * dy);
        fx += dx * 600 / d2; fy += dy * 600 / d2;
      }
      for (const edge of edges.values()) {
        const path = edge.from === node.path ? edge.to : edge.to === node.path ? edge.from : null;
        if (!path) continue;
        const other = nodes.get(path), dx = other.x - node.x, dy = other.y - node.y, distance = Math.hypot(dx, dy) || 1;
        const spring = (distance - 350) * 0.03 / distance;
        fx += dx * spring; fy += dy * spring;
      }
      const cooling = 1 - tick / 50, magnitude = Math.max(1, Math.hypot(fx, fy) / 10);
      node.x += fx / magnitude * cooling; node.y += fy / magnitude * cooling;
    }
  }
  // Hard separation after relaxation. This also handles dense/cyclic neighborhoods deterministically.
  const placed = all.filter((n) => !added.has(n.path) || Number.isFinite(n.fx));
  for (const node of moving) {
    if (placed.some((other) => !separated(node, other))) {
      for (let step = 0; step < 4000; step++) {
        const ring = Math.floor(step / 8), angle = step % 8 * Math.PI / 4;
        const candidate = { x: node.anchor.x + ring * 160 * Math.cos(angle), y: node.anchor.y + ring * 115 * Math.sin(angle) };
        if (placed.every((other) => separated(candidate, other))) { Object.assign(node, candidate); break; }
      }
    }
    placed.push(node);
  }
}

class GraphModel {
  constructor(cap = 120, investigation = new GS.InvestigationState(), code = false) {
    this.cap = cap; this.nodes = new Map(); this.edges = new Map(); this.source = undefined; this.omitted = 0;
    this.investigation = investigation; this.code = code;
  }
  applyAnnotation(node) {
    const annotation = this.investigation.annotation(node, this.code);
    node.hidden = !!annotation?.hidden; node.fx = annotation?.pinned?.x; node.fy = annotation?.pinned?.y;
    if (Number.isFinite(node.fx) && Number.isFinite(node.fy)) { node.x = node.fx; node.y = node.fy; }
  }
  merge(reply) {
    if (this.source !== undefined && this.source !== reply.vector_source) throw new Error("The index model changed. Start a new graph.");
    this.source = reply.vector_source;
    const root = reply.seed;
    if (!root) throw new Error("This file has no indexed vectors yet.");
    const previousRoot = this.nodes.get(root.path) || { x: 0, y: 0, depth: 0 };
    this.nodes.set(root.path, { ...previousRoot, ...root, x: previousRoot.x, y: previousRoot.y });
    this.applyAnnotation(this.nodes.get(root.path));
    const origin = this.nodes.get(root.path), added = new Set();
    reply.hits.forEach((hit, index) => {
      if (!Number.isFinite(hit.cosine) || hit.path === root.path) return;
      if (!this.nodes.has(hit.path)) {
        if (this.nodes.size >= this.cap) { this.omitted++; return; }
        const ring = Math.floor(index / 6), angle = index % 6 * Math.PI / 3;
        const anchor = { x: origin.x + (410 + ring * 240) * Math.cos(angle), y: origin.y + (260 + ring * 160) * Math.sin(angle) };
        this.nodes.set(hit.path, { ...hit, ...anchor, anchor, depth: (origin.depth || 0) + 1 }); added.add(hit.path);
      } else {
        const position = this.nodes.get(hit.path);
        this.nodes.set(hit.path, { ...position, ...hit, x: position.x, y: position.y });
      }
      this.applyAnnotation(this.nodes.get(hit.path));
      const pair = [root.path, hit.path].sort(), key = GS.pairKey(...pair), previous = this.edges.get(key);
      const evidence = GS.evidenceOf(hit), edge = { id: key, from: pair[0], to: pair[1], cosine: hit.cosine, similarityScore: hit.cosine,
        evidence, evidenceFrom: root.path, anchorSegment: reply.basis === "matched_fragment" ? root.segment_id : null,
        matchTypes: [...new Set(evidence.map((e) => e.type))], status: "unverified" };
      edge.reviewKey = GS.reviewKey(edge, this.nodes, this.source, this.code);
      edge.status = this.investigation.status(edge.reviewKey);
      if (!previous || previous.cosine < hit.cosine || previous.reviewKey !== edge.reviewKey) this.edges.set(key, edge);
    });
    settleGraph(this.nodes, this.edges, added);
  }
}

function graphBounds(nodes) {
  const values = [...nodes];
  const left = Math.min(-450, ...values.map((n) => n.x - GRAPH_CARD.width / 2)) - 60;
  const top = Math.min(-270, ...values.map((n) => n.y - GRAPH_CARD.height / 2)) - 60;
  const right = Math.max(450, ...values.map((n) => n.x + GRAPH_CARD.width / 2)) + 60;
  const bottom = Math.max(270, ...values.map((n) => n.y + GRAPH_CARD.height / 2)) + 60;
  return { x: left, y: top, width: right - left, height: bottom - top };
}
function curvePoint(curve, t) {
  const u = 1 - t;
  return { x: u ** 3 * curve.a.x + 3 * u * u * t * curve.b.x + 3 * u * t * t * curve.c.x + t ** 3 * curve.d.x,
    y: u ** 3 * curve.a.y + 3 * u * u * t * curve.b.y + 3 * u * t * t * curve.c.y + t ** 3 * curve.d.y };
}
function insideCard(point, node, padding = 10) {
  return Math.abs(point.x - node.x) < GRAPH_CARD.width / 2 + padding && Math.abs(point.y - node.y) < GRAPH_CARD.height / 2 + padding;
}
// Choose a smooth route around other cards; reserve a legible gap for the real cosine label.
function graphCurve(from, to, nodes, labels = [], labelWidth = 90) {
  const dx = to.x - from.x, dy = to.y - from.y, length = Math.hypot(dx, dy) || 1;
  const port = Math.min(dx ? (GRAPH_CARD.width / 2 + 7) / Math.abs(dx) : Infinity,
    dy ? (GRAPH_CARD.height / 2 + 7) / Math.abs(dy) : Infinity);
  const a = { x: from.x + dx * port, y: from.y + dy * port }, d = { x: to.x - dx * port, y: to.y - dy * port };
  const all = [...nodes];
  const others = all.filter((n) => n.path !== from.path && n.path !== to.path);
  let best;
  for (const bend of [length * 0.12, -length * 0.12, 100, -100, 220, -220, 400, -400]) {
    const nx = -dy / length * bend, ny = dx / length * bend;
    const curve = { a, b: { x: a.x + (d.x - a.x) / 3 + nx, y: a.y + (d.y - a.y) / 3 + ny },
      c: { x: d.x - (d.x - a.x) / 3 + nx, y: d.y - (d.y - a.y) / 3 + ny }, d };
    let score = 0;
    for (let i = 1; i < 24; i++) score += others.filter((n) => insideCard(curvePoint(curve, i / 24), n)).length * 100;
    for (const t of [.5]) {
      const point = curvePoint(curve, t);
      const collides = all.some((n) => Math.abs(point.x - n.x) < GRAPH_CARD.width / 2 + labelWidth / 2 + 8 && Math.abs(point.y - n.y) < GRAPH_CARD.height / 2 + 20)
        || labels.some((l) => Math.abs(l.x - point.x) < (labelWidth + (l.width || 90)) / 2 + 8 && Math.abs(l.y - point.y) < 28);
      if (!collides) { curve.label = { ...point, width: labelWidth }; break; }
    }
    if (!curve.label) { curve.label = curvePoint(curve, .5); score += 10000; }
    if (!best || score < best.score) best = { ...curve, score };
    if (!score) break;
  }
  best.drawing = `M ${a.x} ${a.y} C ${best.b.x} ${best.b.y}, ${best.c.x} ${best.c.y}, ${d.x} ${d.y}`;
  return best;
}

class GraphView {
  constructor({ ask, invoke, nameOf, previewFor, thumbnailFor, onSimilar, onVisibility }) {
    Object.assign(this, { ask, invoke, nameOf, previewFor, thumbnailFor, onSimilar, onVisibility });
    this.model = new GraphModel(); this.generation = 0; this.visible = false; this.loading = false;
    this.pages = new Map(); this.anchors = new Map(); this.selected = null; this.error = null;
    this.minimum = 0.75; this.zoom = .75; this.center = { x: 0, y: 0 }; this.trace = [];
    this.thumbnailCache = new Map(); this.thumbnailTasks = new Map(); this.thumbnailQueue = []; this.thumbnailActive = 0;
    this.inspectorOpen = true;
    this.textMeasure = document.createElement("canvas").getContext("2d");
    if (this.textMeasure) this.textMeasure.font = "500 14px Segoe UI, sans-serif";
    this.el = (id) => document.getElementById(id); this.svg = this.el("graph-scene"); this.mini = this.el("graph-map");
    this.el("graph-back").onclick = () => this.close();
    this.el("graph-expand").onclick = () => this.expand();
    this.el("graph-start-here").onclick = () => this.show(this.model.nodes.get(this.selected), this.code);
    this.el("graph-refresh").onclick = () => this.show(this.rootSeed, this.code);
    this.el("graph-similar").onclick = () => this.onSimilar(this.model.nodes.get(this.selected), this.code);
    this.el("graph-open").onclick = () => this.open("open_path"); this.el("graph-reveal").onclick = () => this.open("reveal");
    this.el("graph-minimum").onchange = () => { this.minimum = Number(this.el("graph-minimum").value); this.show(this.rootSeed, this.code); };
    this.el("graph-zoom-in").onclick = () => this.setZoom(this.zoom * 1.2);
    this.el("graph-zoom-out").onclick = () => this.setZoom(this.zoom / 1.2);
    this.el("graph-zoom").oninput = () => this.setZoom(Number(this.el("graph-zoom").value) / 100);
    this.el("graph-center").onclick = () => { const node = this.model.nodes.get(this.selected); if (node) this.center = { x: node.x, y: node.y }; this.updateCamera(); };
    this.el("graph-inspector-toggle").onclick = () => {
      this.inspectorOpen = !this.inspectorOpen; if (!this.inspectorOpen) this.stopInspectionMedia(); this.renderInspectorVisibility();
    };
    this.svg.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || event.target.closest("[data-node],[data-edge]")) return;
      this.drag = { x: event.clientX, y: event.clientY, center: { ...this.center } }; this.svg.setPointerCapture(event.pointerId);
    });
    this.svg.addEventListener("pointermove", (event) => {
      if (!this.drag) return;
      this.center = { x: this.drag.center.x - (event.clientX - this.drag.x) / this.zoom,
        y: this.drag.center.y - (event.clientY - this.drag.y) / this.zoom }; this.scheduleCamera();
    });
    for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) this.svg.addEventListener(event, () => { this.drag = null; });
    this.svg.addEventListener("wheel", (event) => {
      event.preventDefault();
      const rect = this.svg.getBoundingClientRect(), x = event.clientX - rect.x - this.availableWidth() / 2, y = event.clientY - rect.y - rect.height / 2;
      const before = this.zoom, after = Math.min(2, Math.max(.2, before * Math.exp(-event.deltaY * .001)));
      this.center.x += x / before - x / after; this.center.y += y / before - y / after; this.setZoom(after);
    }, { passive: false });
    const panKeys = (event) => {
      const directions = { ArrowLeft: [-100, 0], ArrowRight: [100, 0], ArrowUp: [0, -80], ArrowDown: [0, 80] };
      if (!event.target.hasAttribute("data-node") && directions[event.key]) {
        event.preventDefault(); const [x, y] = directions[event.key]; this.center.x += x / this.zoom; this.center.y += y / this.zoom; this.updateCamera();
      }
    };
    this.svg.addEventListener("keydown", panKeys); this.mini.addEventListener("keydown", panKeys);
    const moveMini = (event) => {
      const matrix = this.mini.getScreenCTM(); if (!matrix) return;
      const point = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
      this.center = { x: point.x, y: point.y }; this.updateCamera();
    };
    this.mini.addEventListener("click", moveMini);
    this.mini.addEventListener("pointerdown", (event) => { if (event.button !== 0) return; this.miniDrag = true; this.mini.setPointerCapture(event.pointerId); moveMini(event); });
    this.mini.addEventListener("pointermove", (event) => { if (this.miniDrag) moveMini(event); });
    for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) this.mini.addEventListener(event, () => { this.miniDrag = false; });
    this.resizeObserver = new ResizeObserver(() => { if (this.visible) this.updateCamera(); }); this.resizeObserver.observe(this.svg);
    this.initInvestigation();
  }
  scheduleCamera() {
    if (this.cameraFrame) return;
    this.cameraFrame = requestAnimationFrame(() => { this.cameraFrame = null; if (this.visible) this.updateCamera(); });
  }
  setZoom(value) { this.zoom = Math.min(2, Math.max(.2, value)); this.updateCamera(); }
  renderInspectorVisibility() {
    this.el("graph-inspector").hidden = !this.inspectorOpen;
    this.el("graph-inspector-toggle").setAttribute("aria-expanded", String(this.inspectorOpen));
    this.el("graph-inspector-toggle").classList.toggle("active", this.inspectorOpen);
    this.el("graph-view").classList.toggle("has-inspector", this.inspectorOpen);
    this.scheduleCamera();
  }

  close() { this.stopInspectionMedia(); this.countGeneration++; this.searchGeneration++; this.hideContext(); this.generation++; if (this.cameraFrame) cancelAnimationFrame(this.cameraFrame); this.cameraFrame = null; this.visible = false; this.loading = false; this.onVisibility(false); }
  async show(seed, code) {
    if (!seed) return;
    await this.annotationsReady;
    this.semanticMatches = null; this.semanticThreshold = null; this.searchBusy = false; this.searchGeneration++;
    this.omnibar = ""; this.el("graph-omnibar").value = ""; this.pathStart = null; this.el("graph-path-tools").hidden = true;
    this.generation++; this.model = new GraphModel(120, this.investigation, code); this.pages.clear(); this.anchors.clear(); this.trace = [];
    this.selectedEdge = null; this.forcePositions = new Map(); this.pathResult = null; this.countGeneration++;
    this.error = null; this.loading = false; this.selected = seed.path; this.rootSeed = seed; this.code = code;
    this.anchors.set(seed.path, seed.segment_id); this.model.nodes.set(seed.path, { ...seed, x: 0, y: 0 });
    this.model.applyAnnotation(this.model.nodes.get(seed.path));
    this.visible = true; this.zoom = .75; this.center = { x: 0, y: 0 }; this.onVisibility(true);
    return this.expand();
  }
  async expand(all = false, modality = this.modality, target = this.selected) {
    if (this.loading || !this.visible) return;
    const node = this.model.nodes.get(target), generation = this.generation;
    if (!node || (this.model.nodes.size >= this.model.cap && !this.pages.has(this.pageKey(node.path, modality)))) return;
    const pageKey = this.pageKey(node.path, modality), page = this.pages.get(pageKey);
    if (page && !page.has_more) return;
    this.loading = true; this.error = null; this.render();
    try {
      const reply = await this.ask({ op: "related_files", path: node.path, code: this.code,
        segment: this.anchors.has(node.path) ? this.anchors.get(node.path) : node.segment_id,
        offset: page?.next_offset ?? 0, limit: all ? 40 : 6, minimum_cosine: this.minimum,
        ...(modality === "all" ? {} : { match_types: [modality] }) });
      if (generation !== this.generation || !this.visible) return;
      if (reply.ok === false) throw new Error(reply.error);
      if (this.layout === "timeline") this.restoreForce();
      this.model.merge(reply); this.pages.set(pageKey, reply);
      this.forcePositions = new Map([...this.model.nodes].map(([path, n]) => [path, { x: n.x, y: n.y }]));
      this.applyLayout();
      this.anchors.set(node.path, reply.basis === "file_mean" ? undefined : reply.seed.segment_id);
      this.trace.push({ files: this.model.nodes.size, links: this.model.edges.size, total: reply.total, basis: reply.basis });
    } catch (error) { if (generation === this.generation) this.error = String(error.message || error); }
    finally { if (generation === this.generation) { this.loading = false; this.render(); } }
    if (all && !this.error && this.pages.get(pageKey)?.has_more && this.model.nodes.size < this.model.cap && generation === this.generation && this.visible) return this.expand(true, modality, target);
    if (generation === this.generation && this.visible) this.refreshCounts();
  }
  select(path) { if (!this.model.nodes.has(path) || this.model.nodes.get(path).hidden) return; this.stopInspectionMedia(); this.selectedEdge = null; this.selected = path; this.inspectorOpen = true; this.render(); }
  open(command) {
    const node = this.model.nodes.get(this.selected);
    if (node) this.invoke(command, { path: node.path }).catch((error) => { this.error = String(error); this.render(); });
  }
  render() {
    this.el("graph-view").hidden = !this.visible;
    const node = this.model.nodes.get(this.selected), page = this.pages.get(this.pageKey(this.selected));
    this.el("graph-status").textContent = (this.error ? t(this.error) : null) || (this.loading ? t("Finding related files…") :
      t("{files} files · {links} similarity links", { files: [...this.model.nodes.values()].filter((n) => !n.hidden).length, links: GS.visibleEdges(this.model, this).length }) + (this.model.nodes.size >= this.model.cap ? t(" · View limit reached. Use Start here to explore further.") : ""));
    this.el("graph-title").textContent = node ? this.nameOf(node.path) : t("Related files");
    this.el("graph-path").textContent = node?.path ?? "";
    this.el("graph-basis").textContent = page ? (page.basis === "matched_fragment" ? t("Based on the matched fragment") : t("Based on the file’s average meaning")) + t(" · {count} indexed neighbors above the threshold", { count: page.total }) : t("Select Expand links to explore this file");
    this.el("graph-expand").textContent = page ? t("More links") : t("Expand links");
    for (const id of ["graph-refresh", "graph-minimum", "graph-start-here"]) this.el(id).disabled = this.loading;
    this.el("graph-expand").disabled = this.loading || !node || this.model.nodes.size >= this.model.cap || (page && !page.has_more);
    this.el("graph-similar").disabled = !node;
    const previewKey = JSON.stringify([node?.path, node?.segment_id, this.code, I18n.language]);
    if (previewKey !== this.previewKey) {
      this.previewKey = previewKey;
      this.el("graph-preview").replaceChildren(...(node ? [this.previewFor(node, this.code)] : []));
    }
    this.el("graph-open").disabled = !node; this.el("graph-reveal").disabled = !node;
    const list = this.el("graph-neighbors"); list.replaceChildren();
    for (const edge of GS.visibleEdges(this.model, this).filter((e) => e.from === this.selected || e.to === this.selected).sort((a, b) => b.cosine - a.cosine)) {
      const path = edge.from === this.selected ? edge.to : edge.from;
      const button = document.createElement("button"); button.type = "button";
      button.textContent = `${this.nameOf(path)} · ${t("{value} similarity", { value: edge.cosine.toFixed(3) })}`; button.title = path;
      button.onclick = () => this.select(path); list.append(button);
    }
    if (!list.children.length && !this.loading) { const text = document.createElement("p"); text.textContent = t("No links at this threshold. Try a lower minimum similarity."); list.append(text); }
    this.el("graph-neighbor-count").textContent = String(list.querySelectorAll("button").length);
    this.draw();
    this.renderInvestigation();
  }

  queueThumbnail(hit, image) {
    if (!this.thumbnailFor) return;
    const key = JSON.stringify([hit.path, hit.modified, hit.kind, hit.loc]);
    const cached = this.thumbnailCache.get(key);
    const attach = (record) => { image.onload = () => { image.dataset.loaded = "true"; }; image.onerror = () => image.remove(); image.setAttribute("href", record.url); };
    if (cached) { attach(cached); return; }
    let task = this.thumbnailTasks.get(key);
    if (!task) { task = { key, hit, targets: [], started: false }; this.thumbnailTasks.set(key, task); this.thumbnailQueue.push(task); }
    task.targets.push({ image, attach });
  }
  pumpThumbnails() {
    while (this.thumbnailActive < 2 && this.thumbnailQueue.length) {
      const task = this.thumbnailQueue.shift();
      task.targets = task.targets.filter(({ image }) => image.isConnected);
      if (!task.targets.length) { this.thumbnailTasks.delete(task.key); continue; }
      task.started = true; this.thumbnailActive++;
      Promise.resolve().then(() => this.thumbnailFor(task.hit)).then((record) => {
        if (!record?.url) return;
        this.thumbnailCache.set(task.key, record);
        while (this.thumbnailCache.size > 240) this.thumbnailCache.delete(this.thumbnailCache.keys().next().value);
        task.targets.forEach(({ image, attach }) => { if (image.isConnected) attach(record); });
      }).catch(() => {}).finally(() => { this.thumbnailTasks.delete(task.key); this.thumbnailActive--; this.pumpThumbnails(); });
    }
  }
  updateCamera() {
    const width = Math.max(1, this.svg.clientWidth), height = Math.max(1, this.svg.clientHeight);
    this.camera = { x: this.center.x - this.availableWidth() / (2 * this.zoom), y: this.center.y - height / (2 * this.zoom), width: width / this.zoom, height: height / this.zoom };
    this.svg.setAttribute("viewBox", `${this.camera.x} ${this.camera.y} ${this.camera.width} ${this.camera.height}`);
    for (const node of this.svg.querySelectorAll(".graph-backdrop")) {
      for (const [name, value] of Object.entries(this.camera)) node.setAttribute(name, value);
    }
    const percent = Math.round(this.zoom * 100);
    this.el("graph-zoom").value = percent; this.el("graph-zoom-value").textContent = `${percent}%`;
    const viewport = this.mini.querySelector(".graph-map-viewport");
    if (viewport) for (const [name, value] of Object.entries(this.camera)) viewport.setAttribute(name, value);
  }
  draw() {
    const ns = "http://www.w3.org/2000/svg", svg = this.svg;
    const focus = document.activeElement?.closest?.("[data-node],[data-edge]"), focusPath = focus?.dataset.path, focusEdge = focus?.dataset.edge;
    const create = (tag, attributes = {}, text) => {
      const node = document.createElementNS(ns, tag);
      for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
      if (text !== undefined) node.textContent = text; return node;
    };
    const defs = create("defs");
    const pattern = create("pattern", { id: "graph-grid", width: 48, height: 48, patternUnits: "userSpaceOnUse" });
    pattern.append(create("path", { d: "M 48 0 H 0 V 48", fill: "none", stroke: "#dce6ef", "stroke-opacity": .055, "stroke-width": 1 })); defs.append(pattern);
    const plate = create("linearGradient", { id: "graph-plate", x1: 0, y1: 0, x2: 0, y2: 1 });
    plate.append(create("stop", { offset: 0, "stop-color": "#454b52", "stop-opacity": .86 }), create("stop", { offset: 1, "stop-color": "#2b3036", "stop-opacity": .95 })); defs.append(plate);
    for (const [id, color] of [["amber", "#ee9a3f"], ["blue", "#70b8de"]]) {
      const filter = create("filter", { id: `graph-glow-${id}`, x: "-30%", y: "-70%", width: "160%", height: "240%" });
      filter.append(create("feGaussianBlur", { in: "SourceAlpha", stdDeviation: 5, result: "blur" }),
        create("feFlood", { "flood-color": color, "flood-opacity": .38, result: "color" }),
        create("feComposite", { in: "color", in2: "blur", operator: "in", result: "glow" }));
      const merge = create("feMerge"); merge.append(create("feMergeNode", { in: "glow" }), create("feMergeNode", { in: "SourceGraphic" })); filter.append(merge); defs.append(filter);
    }
    svg.replaceChildren(create("title", {}, t("Local file similarity graph. Select a file, expand its links, or pan the background.")), defs,
      create("rect", { class: "graph-backdrop", fill: "#202429" }), create("rect", { class: "graph-backdrop", fill: "url(#graph-grid)" }));
    const labels = [], nodes = [...this.model.nodes.values()].filter((n) => !n.hidden), edges = GS.visibleEdges(this.model, this);
    const geometryKey = JSON.stringify([nodes.map((n) => [n.path, n.x, n.y]), edges.map((e) => [e.id, e.matchTypes.length])]);
    const cachedRoutes = this.routeCache?.key === geometryKey ? this.routeCache.curves : new Map();
    this.routeCache = { key: geometryKey, curves: cachedRoutes };
    this.routes = [];
    let edgeIndex = 0;
    for (const edge of edges) {
      const icons = edge.matchTypes.length ? edge.matchTypes : ["semantic"], badgeWidth = 48 + icons.length * 18;
      const from = this.model.nodes.get(edge.from), to = this.model.nodes.get(edge.to);
      const curve = cachedRoutes.get(edge.id) || graphCurve(from, to, nodes, labels, badgeWidth); cachedRoutes.set(edge.id, curve);
      const active = edge.id === this.selectedEdge || edge.from === this.selected || edge.to === this.selected;
      let stroke = edge.status === "confirmed" ? "#83cda2" : edge.status === "rejected" ? "#d99c99" : "#8d979f";
      if (active && edge.status === "unverified") {
        const selected = edge.from === this.selected ? from : to, other = selected === from ? to : from;
        const id = `graph-link-${edgeIndex}`, gradient = create("linearGradient", { id, gradientUnits: "userSpaceOnUse", x1: selected.x, y1: selected.y, x2: other.x, y2: other.y });
        gradient.append(create("stop", { offset: 0, "stop-color": "#f2a34a" }), create("stop", { offset: 1, "stop-color": "#a18c72", "stop-opacity": .6 })); defs.append(gradient); stroke = `url(#${id})`;
      }
      const routed = this.pathResult?.edges.has(edge.id), width = edge.status === "confirmed" || routed ? 3 : 1.5;
      const group = create("g", { "data-edge": edge.id, class: `graph-connection ${edge.status}`, tabindex: "0", role: "button",
        "aria-label": `${t("Analyze overlap")}: ${this.nameOf(edge.from)} / ${this.nameOf(edge.to)}, ${t(edge.status)}, ${edge.cosine.toFixed(3)}` });
      group.append(create("path", { d: curve.drawing, class: "graph-edge-hit", fill: "none", stroke: "transparent", "stroke-width": 18 }));
      const path = create("path", { d: curve.drawing, class: "graph-edge" + (active ? " active" : ""), fill: "none", stroke: routed ? "#f0a048" : stroke,
        "stroke-width": width, "stroke-opacity": edge.status === "confirmed" ? .95 : active ? .85 : .45,
        "stroke-dasharray": edge.status === "confirmed" ? "none" : edge.status === "rejected" ? "2 7" : "6 6" });
      path.append(create("title", {}, t("Similarity {value}", { value: edge.cosine.toFixed(3) }))); group.append(path);
      const label = create("g", { transform: `translate(${curve.label.x},${curve.label.y})`, class: "graph-score", "data-cosine": edge.cosine });
      label.append(create("rect", { x: -badgeWidth / 2, y: -12, width: badgeWidth, height: 24, rx: 12, fill: "#293039", stroke: edge.status === "confirmed" ? "#83cda2" : "#65717d", "stroke-width": .8 }));
      icons.forEach((type, i) => label.append(create("path", { d: this.modalityIcon(type), transform: `translate(${-badgeWidth / 2 + 8 + i * 18},-7)`,
        fill: "none", stroke: edge.status === "confirmed" ? "#a5dfbe" : "#c2ccd6", "stroke-width": 1.2, "stroke-linecap": "round", "stroke-linejoin": "round" })));
      label.append(create("text", { x: badgeWidth / 2 - 8, y: 4, "text-anchor": "end", fill: active ? "#e6bd8c" : "#d2dbe4", "font-size": 11, "font-family": "Segoe UI, sans-serif" }, edge.cosine.toFixed(2)));
      label.append(create("title", {}, `${icons.map((type) => this.modalityLabel(type)).join(", ")} · ${t(edge.status)}`));
      group.append(label); group.onclick = () => this.selectEdge(edge.id);
      group.onkeydown = (event) => { if (["Enter", " "].includes(event.key)) { event.preventDefault(); event.stopPropagation(); this.selectEdge(edge.id); } };
      svg.append(group);
      labels.push(curve.label); this.routes.push({ from: edge.from, to: edge.to, score: curve.score, label: curve.label }); edgeIndex++;
    }
    let nodeIndex = 0;
    const iconPaths = {
      image: "M-108-13H-76V13H-108Z M-108 8L-99-1L-91 6L-85 0L-76 9 M-101-7h.1",
      video: "M-108-14H-76V14H-108Z M-100-14V14 M-84-14V14 M-108-6H-100 M-108 6H-100 M-84-6H-76 M-84 6H-76 M-96-6L-88 0L-96 6Z",
      audio: "M-107-2V2 M-101-9V9 M-95-15V15 M-89-7V7 M-83-12V12 M-77-3V3",
      code: "M-98-9L-107 0L-98 9 M-86-9L-77 0L-86 9 M-89-14L-96 14",
      doc: "M-103-17H-87L-79-9V17H-103Z M-87-17V-9H-79 M-97-3H-85 M-97 3H-85 M-97 9H-89",
    };
    for (const node of nodes) {
      const selected = node.path === this.selected, video = node.kind === "video", color = selected ? "#efa246" : video ? "#82bbd6" : "#c0c8d1";
      const group = create("g", { transform: `translate(${node.x},${node.y})`, class: "graph-node" + (selected ? " selected" : "") + (video ? " video" : ""),
        "data-node": "true", "data-path": node.path, tabindex: "0", role: "button", "aria-label": `${this.nameOf(node.path)}, ${t(({ image: "Image", screenshot: "Screenshot", doc: "Document", pdf: "PDF", audio: "Audio", video: "Video", code: "Code" })[node.kind] || node.kind)}` });
      group.append(create("title", {}, node.path));
      const rect = create("rect", { class: "graph-card", x: -122, y: -36, width: 244, height: 72, rx: 10,
        fill: selected ? "#483827" : video ? "#293b47" : "url(#graph-plate)", stroke: selected ? "#f0a048" : video ? "#77acc5" : "#969da5",
        "stroke-opacity": selected ? 1 : video ? .85 : .55, "stroke-width": selected ? 1.8 : 1 });
      if (selected || video) rect.setAttribute("filter", `url(#graph-glow-${selected ? "amber" : "blue"})`);
      group.append(rect, create("path", { d: iconPaths[node.kind === "screenshot" ? "image" : node.kind] || iconPaths.doc, fill: "none", stroke: color,
        "stroke-width": 1.6, "stroke-linecap": "round", "stroke-linejoin": "round" }));
      if (["image", "screenshot", "video", "pdf"].includes(node.kind)) {
        const id = `graph-thumb-${nodeIndex}`, clip = create("clipPath", { id }); clip.append(create("rect", { x: -110, y: -20, width: 40, height: 40, rx: 5 })); defs.append(clip);
        const image = create("image", { x: -110, y: -20, width: 40, height: 40, "clip-path": `url(#${id})`, preserveAspectRatio: "xMidYMid slice", class: "graph-thumbnail" });
        group.append(image); this.queueThumbnail(node, image);
      }
      const name = this.nameOf(node.path), letters = [...name];
      let short = name;
      const measure = (text) => this.textMeasure?.measureText(text).width ?? [...text].length * 8;
      for (let keep = Math.min(30, letters.length - 1); measure(short) > 166 && keep >= 2; keep--) {
        short = letters.slice(0, Math.ceil(keep / 2)).join("") + "…" + letters.slice(-Math.floor(keep / 2)).join("");
      }
      group.append(create("text", { x: -60, y: -5, class: "graph-node-name", fill: "#f0f2f5", "font-size": 14, "font-family": "Segoe UI, sans-serif", "font-weight": 500 }, short),
        create("text", { x: -60, y: 17, class: "graph-node-kind", fill: selected ? "#d6bd9b" : video ? "#a9cadc" : "#afb8c1", "font-size": 12.5, "font-family": "Segoe UI, sans-serif" }, t(({ image: "Image", screenshot: "Screenshot", doc: "Document", pdf: "PDF", audio: "Audio", video: "Video", code: "Code" })[node.kind] || node.kind)));
      this.appendNodeTools(group, node, create);
      group.onclick = () => { if (performance.now() - (this.lastNodeDrag || -1000) > 150) this.select(node.path); };
      group.oncontextmenu = (event) => { event.preventDefault(); this.showContext(node.path, event.clientX, event.clientY); };
      group.onkeydown = (event) => {
        if (event.key === "ContextMenu" || event.shiftKey && event.key === "F10") { event.preventDefault(); const r = group.getBoundingClientRect(); this.showContext(node.path, r.left, r.bottom); }
        else if (["Enter", " "].includes(event.key)) { event.preventDefault(); event.stopPropagation(); this.select(node.path); }
      };
      svg.append(group); nodeIndex++;
    }
    // Newly appended images are now connected; process only two local render requests at a time.
    this.pumpThumbnails();
    const bounds = graphBounds(nodes); this.mini.setAttribute("viewBox", `${bounds.x} ${bounds.y} ${bounds.width} ${bounds.height}`);
    this.mini.replaceChildren(create("title", {}, t("Minimap. Click to move the camera.")));
    for (const edge of edges) {
      const from = this.model.nodes.get(edge.from), to = this.model.nodes.get(edge.to);
      this.mini.append(create("line", { x1: from.x, y1: from.y, x2: to.x, y2: to.y, stroke: "#77828c", "stroke-width": 9, "stroke-opacity": .6 }));
    }
    for (const node of nodes) this.mini.append(create("rect", { class: "graph-map-node", x: node.x - 122, y: node.y - 36, width: 244, height: 72, rx: 12,
      fill: node.path === this.selected ? "#f0a048" : node.kind === "video" ? "#82bbd6" : "#a5b0bc" }));
    this.mini.append(create("rect", { class: "graph-map-viewport", fill: "#c5d8ed", "fill-opacity": .07, stroke: "#b7cce3", "stroke-width": 8 }));
    this.renderInspectorVisibility(); this.updateCamera();
    this.applySearchDimming();
    if (focusPath || focusEdge) [...svg.querySelectorAll("[data-node],[data-edge]")].find((n) => focusPath ? n.dataset.path === focusPath : n.dataset.edge === focusEdge)?.focus({ preventScroll: true });
  }
  debug() {
    const clone = this.svg.cloneNode(true); clone.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    clone.setAttribute("width", this.svg.clientWidth); clone.setAttribute("height", this.svg.clientHeight);
    const mini = this.mini.cloneNode(true); mini.setAttribute("xmlns", "http://www.w3.org/2000/svg"); mini.setAttribute("width", "190"); mini.setAttribute("height", "108");
    return { visible: this.visible, preview: { text: this.el("graph-preview").textContent.slice(0, 160), tag: this.el("graph-preview").querySelector("img,video,audio,.passage")?.tagName, loaded: !!this.el("graph-preview").querySelector("img")?.naturalWidth },
      loading: this.loading, error: this.error, files: this.model.nodes.size, links: this.model.edges.size,
      nodes: [...this.model.nodes.values()], edges: [...this.model.edges.values()], trace: this.trace, routes: this.routes,
      drawnNodes: this.svg.querySelectorAll(".graph-node").length, drawnLinks: this.svg.querySelectorAll(".graph-edge").length,
      labels: [...this.svg.querySelectorAll(".graph-score text")].map((node) => node.textContent),
      thumbnails: [...this.svg.querySelectorAll(".graph-thumbnail")].map((node) => ({ loaded: node.dataset.loaded === "true", url: node.getAttribute("href") })),
      thumbnailSources: [...this.thumbnailCache.values()], minimapNodes: this.mini.querySelectorAll(".graph-map-node").length,
      camera: { zoom: this.zoom, center: { ...this.center }, ...this.camera }, inspectorOpen: this.inspectorOpen,
      investigation: this.investigationDebug(),
      stageBounds: this.svg.getBoundingClientRect().toJSON(), minimapBounds: this.mini.closest("details").getBoundingClientRect().toJSON(),
      cardBounds: [...this.svg.querySelectorAll(".graph-card")].map((node) => node.getBoundingClientRect().toJSON()),
      viewport: { width: this.svg.clientWidth, height: this.svg.clientHeight, windowHeight: window.innerHeight, windowWidth: window.innerWidth },
      minimap: new XMLSerializer().serializeToString(mini), svg: new XMLSerializer().serializeToString(clone) };
  }
}
if (typeof window !== "undefined") Object.assign(GraphView.prototype, GraphTools);
if (typeof module !== "undefined") module.exports = { GraphModel, GRAPH_CARD, separated, graphBounds, graphCurve, curvePoint };
