"use strict";

// A bounded neighborhood, with stable positions and exact path identity (no Unicode/case folding).
// Coordinates show topology only. Similarity is carried by edges and their numeric values.
class GraphModel {
  constructor(cap = 120) { this.cap = cap; this.nodes = new Map(); this.edges = new Map(); this.source = undefined; this.omitted = 0; }
  merge(reply) {
    if (this.source !== undefined && this.source !== reply.vector_source) throw new Error("The index model changed. Start a new graph.");
    this.source = reply.vector_source;
    const root = reply.seed;
    if (!root) throw new Error("This file has no indexed vectors yet.");
    const rootPosition = this.nodes.get(root.path) || { x: 0, y: 0 };
    this.nodes.set(root.path, { ...root, x: rootPosition.x, y: rootPosition.y });
    const origin = this.nodes.get(root.path);
    reply.hits.forEach((hit, index) => {
      if (!Number.isFinite(hit.cosine) || hit.path === root.path) return;
      if (!this.nodes.has(hit.path)) {
        if (this.nodes.size >= this.cap) { this.omitted++; return; }
        let point;
        for (let step = index; step < index + 2000; step++) {
          const ring = Math.floor(step / 6), angle = (step % 6) * Math.PI / 3;
          point = { x: origin.x + (200 + ring * 110) * Math.cos(angle), y: origin.y + (85 + ring * 70) * Math.sin(angle) };
          if (![...this.nodes.values()].some((node) => Math.abs(node.x - point.x) < 154 && Math.abs(node.y - point.y) < 58)) break;
        }
        this.nodes.set(hit.path, { ...hit, ...point });
      } else {
        const position = this.nodes.get(hit.path);
        this.nodes.set(hit.path, { ...hit, x: position.x, y: position.y });
      }
      const pair = [root.path, hit.path].sort();
      const key = JSON.stringify(pair);
      const previous = this.edges.get(key);
      if (!previous || previous.cosine < hit.cosine) this.edges.set(key, { from: pair[0], to: pair[1], cosine: hit.cosine });
    });
  }
}

class GraphView {
  constructor({ ask, invoke, nameOf, onVisibility }) {
    Object.assign(this, { ask, invoke, nameOf, onVisibility });
    this.model = new GraphModel(); this.generation = 0; this.visible = false; this.loading = false;
    this.pages = new Map(); this.anchors = new Map(); this.selected = null; this.error = null;
    this.minimum = 0.55; this.zoom = 1; this.center = { x: 0, y: 0 }; this.trace = [];
    this.el = (id) => document.getElementById(id);
    this.svg = this.el("graph-scene");
    this.el("graph-back").onclick = () => this.close();
    this.el("graph-expand").onclick = () => this.expand();
    this.el("graph-start-here").onclick = () => this.show(this.model.nodes.get(this.selected), this.code);
    this.el("graph-refresh").onclick = () => this.show(this.rootSeed, this.code);
    this.el("graph-open").onclick = () => this.open("open_path");
    this.el("graph-reveal").onclick = () => this.open("reveal");
    this.el("graph-minimum").onchange = () => { this.minimum = Number(this.el("graph-minimum").value); this.show(this.rootSeed, this.code); };
    this.el("graph-zoom-in").onclick = () => { this.zoom = Math.min(2, this.zoom * 1.25); this.draw(); };
    this.el("graph-zoom-out").onclick = () => { this.zoom = Math.max(0.75, this.zoom / 1.25); this.draw(); };
    this.el("graph-center").onclick = () => { const node = this.model.nodes.get(this.selected); if (node) this.center = { x: node.x, y: node.y }; this.zoom = 1; this.draw(); };
    this.svg.addEventListener("pointerdown", (event) => {
      if (event.target.closest("[data-node]")) return;
      this.drag = { x: event.clientX, y: event.clientY, center: { ...this.center } }; this.svg.setPointerCapture(event.pointerId);
    });
    this.svg.addEventListener("pointermove", (event) => {
      if (!this.drag) return;
      const scale = 720 / this.svg.getBoundingClientRect().width / this.zoom;
      this.center = { x: this.drag.center.x - (event.clientX - this.drag.x) * scale, y: this.drag.center.y - (event.clientY - this.drag.y) * scale };
      this.draw();
    });
    for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) this.svg.addEventListener(event, () => { this.drag = null; });
    this.svg.addEventListener("keydown", (event) => {
      const directions = { ArrowLeft: [-80, 0], ArrowRight: [80, 0], ArrowUp: [0, -60], ArrowDown: [0, 60] };
      if (!event.target.hasAttribute("data-node") && directions[event.key]) {
        event.preventDefault(); const [x, y] = directions[event.key]; this.center.x += x; this.center.y += y; this.draw();
      }
    });
  }
  close() { this.generation++; this.visible = false; this.loading = false; this.onVisibility(false); }
  async show(seed, code) {
    if (!seed) return;
    this.generation++; this.model = new GraphModel(); this.pages.clear(); this.anchors.clear(); this.trace = [];
    this.error = null; this.loading = false; this.selected = seed.path; this.rootSeed = seed; this.code = code;
    this.anchors.set(seed.path, seed.segment_id); this.model.nodes.set(seed.path, { ...seed, x: 0, y: 0 });
    this.visible = true; this.zoom = 1; this.center = { x: 0, y: 0 }; this.onVisibility(true);
    return this.expand();
  }
  async expand() {
    if (this.loading || !this.visible) return;
    const node = this.model.nodes.get(this.selected), generation = this.generation;
    if (!node || (this.model.nodes.size >= this.model.cap && !this.pages.has(node.path))) return;
    const page = this.pages.get(node.path);
    if (page && !page.has_more) return;
    this.loading = true; this.error = null; this.render();
    try {
      const reply = await this.ask({ op: "related_files", path: node.path, code: this.code,
        segment: this.anchors.has(node.path) ? this.anchors.get(node.path) : node.segment_id,
        offset: page?.next_offset ?? 0, limit: 6, minimum_cosine: this.minimum });
      if (generation !== this.generation || !this.visible) return;
      if (reply.ok === false) throw new Error(reply.error);
      this.model.merge(reply); this.pages.set(node.path, reply);
      this.anchors.set(node.path, reply.basis === "file_mean" ? undefined : reply.seed.segment_id);
      this.trace.push({ files: this.model.nodes.size, links: this.model.edges.size, total: reply.total, basis: reply.basis });
    } catch (error) { if (generation === this.generation) this.error = String(error.message || error); }
    finally { if (generation === this.generation) { this.loading = false; this.render(); } }
  }
  select(path) { if (!this.model.nodes.has(path)) return; this.selected = path; this.render(); }
  open(command) {
    const node = this.model.nodes.get(this.selected);
    if (node) this.invoke(command, { path: node.path }).catch((error) => { this.error = String(error); this.render(); });
  }
  render() {
    this.el("graph-view").hidden = !this.visible;
    const node = this.model.nodes.get(this.selected), page = this.pages.get(this.selected);
    this.el("graph-status").textContent = this.error || (this.loading ? "Finding related files…" :
      `${this.model.nodes.size} files · ${this.model.edges.size} similarity links${this.model.omitted ? " · View limit reached. Use Start here to explore further." : ""}`);
    this.el("graph-title").textContent = node ? this.nameOf(node.path) : "Related files";
    this.el("graph-path").textContent = node?.path ?? "";
    this.el("graph-basis").textContent = page ? (page.basis === "matched_fragment" ? "Based on the matched fragment" : "Based on the file’s average meaning") + ` · ${page.total} indexed neighbors above the threshold` : "Select Expand links to explore this file";
    this.el("graph-expand").textContent = page ? "More links" : "Expand links";
    for (const id of ["graph-refresh", "graph-minimum", "graph-start-here"]) this.el(id).disabled = this.loading;
    this.el("graph-expand").disabled = this.loading || !node || this.model.nodes.size >= this.model.cap || (page && !page.has_more);
    this.el("graph-open").disabled = !node; this.el("graph-reveal").disabled = !node;
    const list = this.el("graph-neighbors"); list.replaceChildren();
    for (const edge of [...this.model.edges.values()].filter((e) => e.from === this.selected || e.to === this.selected).sort((a, b) => b.cosine - a.cosine)) {
      const path = edge.from === this.selected ? edge.to : edge.from;
      const button = document.createElement("button"); button.type = "button";
      button.textContent = `${this.nameOf(path)} · ${edge.cosine.toFixed(3)} similarity`; button.title = path;
      button.onclick = () => this.select(path); list.append(button);
    }
    if (!list.children.length && !this.loading) { const text = document.createElement("p"); text.textContent = "No links at this threshold. Try a lower minimum similarity."; list.append(text); }
    this.draw();
  }
  draw() {
    const svg = this.svg, ns = "http://www.w3.org/2000/svg";
    const create = (tag, attributes, text) => { const node = document.createElementNS(ns, tag); for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value); if (text !== undefined) node.textContent = text; return node; };
    svg.setAttribute("viewBox", `${this.center.x - 360 / this.zoom} ${this.center.y - 125 / this.zoom} ${720 / this.zoom} ${250 / this.zoom}`);
    svg.replaceChildren(create("title", {}, "Local file similarity graph. Select a file, expand its links, or pan the background."));
    for (const edge of this.model.edges.values()) {
      const from = this.model.nodes.get(edge.from), to = this.model.nodes.get(edge.to);
      const line = create("line", { x1: from.x, y1: from.y, x2: to.x, y2: to.y, class: "graph-edge", "stroke-width": 1 + Math.max(0, edge.cosine) * 2 });
      line.append(create("title", {}, `Similarity ${edge.cosine.toFixed(3)}`)); svg.append(line);
    }
    for (const node of this.model.nodes.values()) {
      const group = create("g", { transform: `translate(${node.x},${node.y})`, class: "graph-node" + (node.path === this.selected ? " selected" : ""),
        "data-node": "true", tabindex: "0", role: "button", "aria-label": `${this.nameOf(node.path)}, ${node.kind}` });
      group.append(create("title", {}, node.path), create("rect", { x: -70, y: -22, width: 140, height: 44, rx: 6 }));
      const name = this.nameOf(node.path), short = [...name].length > 16 ? [...name].slice(0, 15).join("") + "…" : name;
      group.append(create("text", { x: 0, y: -2, "text-anchor": "middle", class: "graph-node-name" }, short),
        create("text", { x: 0, y: 14, "text-anchor": "middle", class: "graph-node-kind" }, node.kind));
      group.onclick = () => this.select(node.path);
      group.onkeydown = (event) => { if (["Enter", " "].includes(event.key)) { event.preventDefault(); event.stopPropagation(); this.select(node.path); } };
      svg.append(group);
    }
  }
  debug() {
    const clone = this.svg.cloneNode(true); clone.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    clone.setAttribute("width", "720"); clone.setAttribute("height", "250");
    clone.setAttribute("style", `background:${getComputedStyle(document.documentElement).getPropertyValue("--surface").trim()}`);
    const originals = this.svg.querySelectorAll("*"), copies = clone.querySelectorAll("*");
    originals.forEach((node, i) => { const css = getComputedStyle(node); for (const key of ["fill", "stroke", "font-size", "font-family", "font-weight"]) copies[i].setAttribute(key, css.getPropertyValue(key)); });
    return { visible: this.visible, loading: this.loading, error: this.error, files: this.model.nodes.size, links: this.model.edges.size,
      nodes: [...this.model.nodes.values()], edges: [...this.model.edges.values()], trace: this.trace,
      drawnNodes: this.svg.querySelectorAll(".graph-node").length, drawnLinks: this.svg.querySelectorAll(".graph-edge").length,
      viewport: { width: this.svg.clientWidth, height: this.svg.clientHeight, windowHeight: window.innerHeight },
      svg: new XMLSerializer().serializeToString(clone) };
  }
}
if (typeof module !== "undefined") module.exports = { GraphModel };
