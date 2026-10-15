"use strict";

// Investigation controls extend the existing graph/preview, without another search engine or frontend framework.
const GraphTools = {
  initInvestigation() {
    this.investigation = new GS.InvestigationState(); this.modality = "all"; this.showRejected = false;
    this.layout = "force"; this.countGeneration = 0; this.searchGeneration = 0; this.omnibar = "";
    this.evidenceCache = new Map(); this.hashCache = new Map(); this.hashPending = new Set(); this.saveQueue = Promise.resolve();
    this.annotationsReady = this.invoke("graph_annotations").then((value) => {
      this.investigation = new GS.InvestigationState(value);
    }).catch((error) => { this.annotationLoadError = String(error); this.storageError = String(error); });
    this.el("graph-inspector-close").onclick = () => { this.inspectorOpen = false; this.stopInspectionMedia(); this.renderInspectorVisibility(); };
    this.el("graph-omnibar").oninput = (event) => {
      this.omnibar = event.target.value; this.semanticMatches = null; this.semanticThreshold = null; this.searchBusy = false; this.searchError = null; this.searchGeneration++; this.applySearchDimming(); this.renderInvestigation();
    };
    this.el("graph-search-form").onsubmit = (event) => { event.preventDefault(); this.semanticTask = this.semanticSearch(); };
    this.el("graph-omnibar").onkeydown = (event) => {
      if (event.key === "Escape") { event.stopPropagation(); event.target.value = ""; event.target.dispatchEvent(new Event("input", { bubbles: true })); }
    };
    for (const button of document.querySelectorAll("[data-graph-modality]")) button.onclick = () => {
      this.modality = button.dataset.graphModality; this.pathResult = null; this.render(); this.refreshCounts();
    };
    this.el("graph-show-rejected").onchange = (event) => { this.showRejected = event.target.checked; this.pathResult = null; this.render(); };
    this.el("graph-layout").onchange = (event) => { this.layout = event.target.value; this.applyLayout(); this.render(); };
    this.el("graph-restore-hidden").onclick = () => {
      for (const node of this.model.nodes.values()) if (node.hidden) { this.investigation.annotate(node, this.code, { hidden: false }); this.model.applyAnnotation(node); }
      this.persistAnnotations(); this.render();
    };
    this.el("graph-path-find").onclick = () => this.findPath(this.el("graph-path-target").value);
    this.el("graph-path-cancel").onclick = () => { this.pathStart = null; this.pathResult = null; this.el("graph-path-tools").hidden = true; this.render(); };
    this.el("graph-confirm").onclick = () => this.verifyEdge("confirmed");
    this.el("graph-reject").onclick = () => this.verifyEdge("rejected");
    this.el("graph-unverify").onclick = () => this.verifyEdge("unverified");
    this.el("graph-hash").onclick = () => this.computeHash();
    this.el("graph-evidence-retry").onclick = () => {
      const node = this.model.nodes.get(this.selected); if (!node) return;
      this.evidenceCache.delete(GS.nodeKey(node, this.code)); this.renderMetadata(node);
    };
    this.el("graph-retry-save").onclick = () => this.persistAnnotations();
    document.addEventListener("pointerdown", (event) => { if (!event.target.closest("#graph-context")) this.hideContext(); });
    document.addEventListener("keydown", (event) => {
      if (!this.el("graph-context").hidden && event.key === "Escape") { event.preventDefault(); event.stopPropagation(); this.hideContext(true); }
    });
    this.svg.addEventListener("pointerdown", (event) => {
      const group = event.target.closest("[data-node]");
      if (!group || event.button !== 0 || event.target.closest("[data-node-tool]")) return;
      const node = this.model.nodes.get(group.dataset.path);
      this.nodeDrag = { path: node.path, x: event.clientX, y: event.clientY, origin: { x: node.x, y: node.y } };
      this.svg.setPointerCapture(event.pointerId);
    });
    this.svg.addEventListener("pointermove", (event) => {
      if (!this.nodeDrag) return;
      const drag = this.nodeDrag, node = this.model.nodes.get(drag.path), dx = event.clientX - drag.x, dy = event.clientY - drag.y;
      if (!drag.moved && Math.hypot(dx, dy) < 4) return;
      drag.moved = true; node.x = drag.origin.x + dx / this.zoom; node.y = drag.origin.y + dy / this.zoom;
      if (Number.isFinite(node.fx)) { node.fx = node.x; node.fy = node.y; }
      if (!this.nodeFrame) this.nodeFrame = requestAnimationFrame(() => { this.nodeFrame = null; if (this.visible) this.draw(); });
    });
    const endDrag = () => {
      if (!this.nodeDrag) return;
      const { path, moved } = this.nodeDrag; this.nodeDrag = null;
      if (moved) {
        this.lastNodeDrag = performance.now(); const node = this.model.nodes.get(path);
        if (Number.isFinite(node.fx)) { this.investigation.annotate(node, this.code, { pinned: { x: node.fx, y: node.fy } }); this.persistAnnotations(); }
        if (this.layout === "force") this.forcePositions.set(path, { x: node.x, y: node.y });
      }
    };
    for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) this.svg.addEventListener(event, endDrag);
  },
  pageKey(path, modality = this.modality) { return JSON.stringify([path, modality, this.minimum]); },
  availableWidth() {
    return Math.max(240, this.svg.clientWidth - (this.inspectorOpen ? this.el("graph-inspector").getBoundingClientRect().width : 0));
  },
  stopInspectionMedia() { this.el("graph-inspector").querySelectorAll("audio,video").forEach((player) => player.pause()); },
  persistAnnotations() {
    if (this.annotationLoadError) { this.storageError = this.annotationLoadError; this.renderInvestigation(); return this.saveQueue; }
    const snapshot = this.investigation.serialize(), sequence = this.saveSequence = (this.saveSequence || 0) + 1;
    this.saving = true; this.storageError = null; this.renderInvestigation();
    this.saveQueue = this.saveQueue.catch(() => {}).then(() => this.invoke("save_graph_annotations", { state: snapshot }))
      .then(() => { if (sequence === this.saveSequence) { this.saving = false; this.storageError = null; this.renderInvestigation(); } })
      .catch((error) => { if (sequence === this.saveSequence) { this.saving = false; this.storageError = String(error); this.renderInvestigation(); } });
    return this.saveQueue;
  },
  async refreshCounts() {
    const token = ++this.countGeneration, generation = this.generation;
    const nodes = [...this.model.nodes.values()].filter((n) => !n.hidden);
    for (const node of nodes) node.unexpandedCount = undefined;
    this.draw();
    for (let i = 0; i < nodes.length; i += 8) {
      if (!this.visible || generation !== this.generation || token !== this.countGeneration) return;
      try {
        const reply = await this.ask({ op: "related_counts", code: this.code, minimum_cosine: this.minimum,
          nodes: nodes.slice(i, i + 8).map((n) => ({ path: n.path, segment: this.anchors.has(n.path) ? this.anchors.get(n.path) : n.segment_id })),
          visible: [...this.model.nodes.keys()], ...(this.modality === "all" ? {} : { match_types: [this.modality] }) });
        if (!this.visible || generation !== this.generation || token !== this.countGeneration) return;
        if (reply.ok === false) throw new Error(reply.error);
        if (reply.vector_source !== this.model.source) throw new Error("The index model changed. Start a new graph.");
        for (const count of reply.counts) { const n = this.model.nodes.get(count.path); if (n) { n.unexpandedCount = count.unexpanded_count; n.neighborTotal = count.total; } }
        this.countError = null; this.draw();
      } catch (error) { if (token === this.countGeneration && generation === this.generation && this.visible) { this.countError = String(error.message || error); this.renderInvestigation(); } return; }
    }
  },
  restoreForce() {
    for (const node of this.model.nodes.values()) {
      const position = this.forcePositions.get(node.path); if (position) Object.assign(node, position);
      this.model.applyAnnotation(node);
    }
  },
  applyLayout() {
    if (this.layout === "force") { this.restoreForce(); return; }
    for (const [path, point] of GS.timelineLayout(this.model.nodes.values())) Object.assign(this.model.nodes.get(path), point);
  },
  async semanticSearch() {
    const q = this.el("graph-omnibar").value.trim(), token = ++this.searchGeneration, generation = this.generation;
    if (!q) { this.semanticMatches = null; this.applySearchDimming(); return; }
    this.searchBusy = true; this.searchError = null; this.renderInvestigation();
    try {
      const reply = await this.ask({ op: "graph_search", q, code: this.code, paths: [...this.model.nodes.keys()] });
      if (token !== this.searchGeneration || generation !== this.generation || !this.visible) return;
      if (reply.ok === false) throw new Error(reply.error);
      this.semanticMatches = new Set(reply.hits.map((hit) => hit.path)); this.semanticThreshold = reply.minimum_cosine; this.applySearchDimming();
    } catch (error) { if (token === this.searchGeneration) this.searchError = String(error.message || error); }
    finally { if (token === this.searchGeneration) { this.searchBusy = false; this.renderInvestigation(); } }
  },
  applySearchDimming() {
    const q = GS.fold(this.omnibar), paths = this.pathResult?.nodes;
    const active = new Set(GS.visibleEdges(this.model, this).flatMap((edge) => [edge.from, edge.to]));
    let matches = 0;
    for (const group of this.svg.querySelectorAll("[data-node]")) {
      const path = group.dataset.path;
      const match = (!q || GS.fold(this.nameOf(path)).includes(q) || this.semanticMatches?.has(path))
        && (!paths || paths.has(path)) && (this.modality === "all" || active.has(path));
      group.style.opacity = match ? "1" : "0.25"; if (match) matches++;
    }
    this.el("graph-search-status").textContent = q ? t("{count} canvas files match", { count: matches }) + (Number.isFinite(this.semanticThreshold) ? " · " + t("Query cosine ≥ {value}", { value: this.semanticThreshold.toFixed(3) }) : "") : "";
  },
  modalityLabel(type) { return t(({ all: "All", visual: "Scene", face: "Faces", audio: "Audio", ocr: "Text / OCR", metadata: "EXIF", semantic: "Semantic" })[type] || type); },
  modalityIcon(type) {
    return ({ visual: "M1 1H13V13H1Z M1 10L5 6L8 9L11 5L13 8 M4 4h.1", face: "M3 2Q7-1 11 2V7Q11 12 7 13Q3 12 3 7Z M5 5h.1 M9 5h.1 M5 9Q7 11 9 9",
      audio: "M1 5V9 M4 2V12 M7 0V14 M10 3V11 M13 5V9", ocr: "M1 3V1H5 M9 1H13V3 M1 11V13H5 M9 13H13V11 M4 5H10 M7 5V10",
      metadata: "M3 1H10L13 4V13H3Z M9 1V5H13 M6 8H10 M6 10H10", semantic: "M6 4L8 2Q12-1 14 3Q15 6 11 8 M8 10L6 12Q2 15 0 11Q-1 8 3 6 M4 9L10 3" })[type];
  },
  appendNodeTools(group, node, create) {
    const tool = (title, x, y, action) => {
      const button = create("g", { "data-node-tool": "true", transform: `translate(${x},${y})`, class: "graph-node-tool", tabindex: "0", role: "button", "aria-label": title });
      button.append(create("title", {}, title), create("rect", { x: -12, y: -12, width: 24, height: 24, rx: 6, fill: "#303942", "fill-opacity": .95 }));
      button.onclick = (event) => { event.stopPropagation(); action(); };
      button.onkeydown = (event) => { if (["Enter", " "].includes(event.key)) { event.preventDefault(); event.stopPropagation(); action(); } };
      group.append(button); return button;
    };
    const pinned = Number.isFinite(node.fx), pin = tool(t(pinned ? "Unpin node" : "Pin node"), 106, 17, () => this.togglePin(node.path));
    pin.append(create("path", { d: "M-4-7H4L3-3L6 1H-6L-3-3Z M0 1V8", fill: pinned ? "#e6bd8c" : "none", stroke: pinned ? "#e6bd8c" : "#b3bfcc", "stroke-width": 1.2 }));
    if (node.unexpandedCount > 0) {
      const label = `+${node.unexpandedCount}`, badge = tool(t("{count} unexpanded neighbors", { count: node.unexpandedCount }), 96, -36, () => { this.select(node.path); this.expand(); });
      const width = Math.max(36, label.length * 7 + 12), rect = badge.querySelector("rect"); rect.setAttribute("x", -width / 2); rect.setAttribute("width", width); rect.setAttribute("height", 20); rect.setAttribute("y", -10); rect.setAttribute("rx", 10); rect.setAttribute("stroke", "#7d8b98");
      badge.append(create("text", { "text-anchor": "middle", y: 4, fill: "#ecf1f5", "font-size": 11, "font-family": "Segoe UI, sans-serif" }, label));
    }
  },
  togglePin(path) {
    const node = this.model.nodes.get(path); if (!node) return;
    this.investigation.annotate(node, this.code, { pinned: Number.isFinite(node.fx) ? null : { x: node.x, y: node.y } });
    this.model.applyAnnotation(node); this.persistAnnotations(); this.render();
  },
  hideNode(path) {
    const node = this.model.nodes.get(path); if (!node) return;
    this.investigation.annotate(node, this.code, { hidden: true }); this.model.applyAnnotation(node);
    this.selectedEdge = null; this.pathResult = null;
    if (this.selected === path) this.selected = [...this.model.nodes.values()].find((n) => !n.hidden)?.path ?? null;
    this.persistAnnotations(); this.render();
  },
  showContext(path, x, y) {
    this.contextPath = path;
    const menu = this.el("graph-context"); menu.replaceChildren(); menu.hidden = false;
    const add = (label, action, disabled = false) => {
      const button = document.createElement("button"); button.type = "button"; button.role = "menuitem"; button.textContent = label; button.disabled = disabled;
      button.onclick = () => { this.hideContext(); action(); }; menu.append(button);
    };
    const expand = (type) => { this.select(path); this.modality = type; this.render(); this.expand(true, type); };
    add(t("Expand all links"), () => expand("all"), this.loading);
    const label = document.createElement("p"); label.textContent = t("Expand by modality"); menu.append(label);
    for (const type of ["face", "visual", "audio", "ocr"]) add(this.modalityLabel(type), () => expand(type), type === "face" || this.loading);
    add(t("Find shortest path to…"), () => this.beginPath(path));
    add(t(Number.isFinite(this.model.nodes.get(path).fx) ? "Unpin node" : "Pin node"), () => this.togglePin(path));
    add(t("Hide node"), () => this.hideNode(path));
    menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - 260))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - menu.offsetHeight - 8))}px`;
    menu.onkeydown = (event) => {
      if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
      event.preventDefault(); const buttons = [...menu.querySelectorAll("button:not(:disabled)")], current = buttons.indexOf(document.activeElement);
      buttons[event.key === "Home" ? 0 : event.key === "End" ? buttons.length - 1 : (current + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length]?.focus();
    };
    menu.querySelector("button:not(:disabled)")?.focus();
  },
  hideContext(restoreFocus = false) {
    this.el("graph-context").hidden = true;
    if (restoreFocus && this.contextPath) [...this.svg.querySelectorAll("[data-path]")].find((n) => n.dataset.path === this.contextPath)?.focus();
  },
  beginPath(path) {
    this.pathStart = path; this.pathResult = null; this.el("graph-path-tools").hidden = false;
    const select = this.el("graph-path-target"); select.replaceChildren();
    for (const node of this.model.nodes.values()) if (!node.hidden && node.path !== path) {
      const option = document.createElement("option"); option.value = node.path; option.textContent = this.nameOf(node.path); select.append(option);
    }
    this.el("graph-path-source").textContent = this.nameOf(path); select.focus();
  },
  findPath(to) {
    const paths = GS.shortestPath(this.model, this.pathStart, to, this);
    this.pathResult = paths ? { nodes: new Set(paths), edges: new Set(paths.slice(1).map((p, i) => GS.pairKey(paths[i], p))) } : null;
    this.el("graph-path-result").textContent = paths ? t("{count} hops in the expanded graph", { count: paths.length - 1 }) : t("No path in the expanded graph. Expand neighbors first. Rejected links are excluded.");
    this.draw();
  },
  selectEdge(id) {
    if (!this.model.edges.has(id)) return;
    this.stopInspectionMedia(); this.selectedEdge = id; this.inspectorOpen = true; this.render();
  },
  verifyEdge(status) {
    const edge = this.model.edges.get(this.selectedEdge); if (!edge) return;
    this.investigation.verify(edge.reviewKey, status); edge.status = status; this.pathResult = null;
    this.persistAnnotations(); this.render();
  },
  formatDate(value) { return Number.isFinite(value) ? new Date(value * 1000).toLocaleString(I18n.locale()) : t("Not available"); },
  renderInvestigation() {
    if (!this.investigation) return;
    const edge = this.model.edges.get(this.selectedEdge), node = this.model.nodes.get(this.selected);
    this.el("graph-node-inspection").hidden = !!edge; this.el("graph-match-inspection").hidden = !edge;
    this.el("graph-inspector-heading").textContent = t(edge ? "Analyze overlap" : "File inspector");
    this.el("graph-search-submit").disabled = !!this.searchBusy;
    this.el("graph-show-rejected").checked = this.showRejected; this.el("graph-layout").value = this.layout;
    for (const button of document.querySelectorAll("[data-graph-modality]")) button.setAttribute("aria-pressed", String(button.dataset.graphModality === this.modality));
    const hidden = [...this.model.nodes.values()].filter((n) => n.hidden).length;
    this.el("graph-restore-hidden").hidden = !hidden; this.el("graph-restore-hidden").textContent = t("Restore hidden ({count})", { count: hidden });
    this.el("graph-state-message").textContent = this.storageError ? t("Annotations are not saved. {error}", { error: this.storageError }) : this.saving ? t("Saving locally…") : t("Annotations saved locally");
    this.el("graph-state-message").classList.toggle("error", !!this.storageError); this.el("graph-retry-save").hidden = !this.storageError || !!this.annotationLoadError;
    this.el("graph-analysis-message").textContent = this.searchError ? t(this.searchError) : this.countError ? t("Neighbor counts unavailable. Refresh to retry.") : "";
    const legend = this.el("graph-timeline-legend"); legend.hidden = this.layout !== "timeline";
    if (!legend.hidden) {
      const dates = [...this.model.nodes.values()].filter((n) => !n.hidden && Number.isFinite(n.modified)).map((n) => n.modified);
      legend.textContent = t("Date modified") + `: ${this.formatDate(Math.min(...dates))} — ${this.formatDate(Math.max(...dates))}. ` + t("Pinned nodes keep their coordinates.");
    }
    if (edge) this.renderMatch(edge); else if (node) this.renderMetadata(node);
  },
  renderMetadata(node) {
    const key = GS.nodeKey(node, this.code), cached = this.evidenceCache.get(key), info = { ...node.info, ...cached?.info };
    const list = this.el("graph-metadata"); list.replaceChildren();
    const row = (label, value) => { const dt = document.createElement("dt"), dd = document.createElement("dd"); dt.textContent = t(label); dd.textContent = value || t("Not available"); list.append(dt, dd); };
    row("Date modified", this.formatDate(node.modified)); row("File size", `${(node.size / 1024).toLocaleString(I18n.locale(), { maximumFractionDigits: 1 })} KiB`);
    row("Resolution", info?.width && info?.height ? `${info.width} × ${info.height}` : null);
    row("EXIF capture date", info?.taken);
    row("SHA-256", this.hashCache.get(key) || t("Compute on demand"));
    row("Objects", t("Not extracted by this index")); row("Faces", t("Not extracted by this index"));
    row("Text / OCR", cached?.failed ? t("Could not load indexed evidence. Retry reading it.") : !cached || cached.loading ? t("Loading indexed evidence…") : cached.ocr?.map((item) => item.text).join("\n\n") || t("No indexed OCR text"));
    this.el("graph-evidence-retry").hidden = !cached?.failed;
    this.el("graph-hash").disabled = this.hashPending.has(key); this.el("graph-hash").textContent = t(this.hashPending.has(key) ? "Hashing locally…" : "Compute SHA-256");
    if (!this.evidenceCache.has(key)) {
      this.evidenceCache.set(key, { loading: true }); const generation = this.generation;
      this.ask({ op: "file_evidence", path: node.path, code: this.code }).then((reply) => {
        this.evidenceCache.set(key, reply.ok === false ? { failed: true } : reply);
        if (generation === this.generation && this.visible && this.selected === node.path && !this.selectedEdge) this.renderMetadata(node);
      }).catch(() => { this.evidenceCache.set(key, { failed: true }); if (generation === this.generation && this.visible && this.selected === node.path && !this.selectedEdge) this.renderMetadata(node); });
    }
  },
  async computeHash() {
    const node = this.model.nodes.get(this.selected); if (!node) return;
    const key = GS.nodeKey(node, this.code), generation = this.generation; if (this.hashPending.has(key)) return;
    this.hashPending.add(key); this.renderMetadata(node);
    try {
      const reply = await this.ask({ op: "media_details", path: node.path, code: this.code });
      if (reply.ok === false) throw new Error(reply.error);
      if (reply.size !== node.size || Math.abs(reply.modified - node.modified) > .001) throw new Error("The file changed in the index. Refresh search results.");
      this.hashCache.set(key, reply.sha256);
    } catch (error) { if (generation === this.generation) this.searchError = String(error.message || error); }
    finally { this.hashPending.delete(key); if (generation === this.generation && this.visible) this.renderInvestigation(); }
  },
  renderMatch(edge) {
    const previewKey = edge.reviewKey + I18n.language;
    if (this.matchPreviewKey !== previewKey) {
      this.el("graph-match-previews").querySelectorAll("audio,video").forEach((player) => player.pause());
      this.matchPreviewKey = previewKey; const previews = this.el("graph-match-previews"); previews.replaceChildren();
      for (const path of [edge.evidenceFrom, edge.evidenceFrom === edge.from ? edge.to : edge.from]) {
        const hit = this.model.nodes.get(path), cell = document.createElement("section"), label = document.createElement("h4");
        label.textContent = this.nameOf(path); label.title = path; cell.append(this.previewFor(hit, this.code), label); previews.append(cell);
      }
    }
    this.el("graph-match-status").textContent = t(edge.status);
    const detail = this.el("graph-match-evidence"); detail.replaceChildren();
    const note = document.createElement("p"); note.textContent = t("Cosines are independent scores, not probabilities or percentage contributions."); detail.append(note);
    if (!edge.evidence.length) { const p = document.createElement("p"); p.textContent = t("Semantic similarity only. No modality-specific evidence for this link."); detail.append(p); }
    for (const evidence of edge.evidence) {
      const section = document.createElement("section"), title = document.createElement("h4"), text = document.createElement("p");
      title.textContent = this.modalityLabel(evidence.type);
      text.textContent = evidence.type === "metadata" ? t("Exact EXIF capture date: {value}", { value: evidence.value }) :
        t("Cosine {value} ({percent} / 100 scale)", { value: evidence.cosine.toFixed(3), percent: (evidence.cosine * 100).toFixed(1) });
      section.append(title, text);
      for (const [field, path, label] of [["seed_loc", edge.evidenceFrom, "Source time"], ["loc", edge.evidenceFrom === edge.from ? edge.to : edge.from, "Target time"]]) {
        const hit = this.model.nodes.get(path), location = evidence[field];
        if (hit?.kind === "video" || hit?.kind === "audio") {
          const time = document.createElement("button"); time.type = "button"; time.className = "quiet-button";
          time.textContent = t(label) + ": " + (Number.isFinite(location) ? `${Math.floor(location / 60)}:${String(Math.floor(location % 60)).padStart(2, "0")}` : t("File mean; no exact time"));
          time.disabled = !Number.isFinite(location); time.onclick = () => {
            const index = path === edge.evidenceFrom ? 0 : 1, cell = this.el("graph-match-previews").children[index];
            cell.querySelectorAll("audio,video").forEach((p) => p.pause());
            cell.replaceChildren(this.previewFor({ ...hit, loc: location, segment_id: evidence[field === "loc" ? "segment" : "seed_segment"] || hit.segment_id,
              segment: evidence.type === "audio" ? "audio" : "frame" }, this.code), cell.querySelector("h4"));
          }; section.append(time);
        }
      }
      detail.append(section);
    }
    for (const [id, status] of [["graph-confirm", "confirmed"], ["graph-reject", "rejected"], ["graph-unverify", "unverified"]]) this.el(id).disabled = edge.status === status;
  },
  investigationDebug() {
    return { mode: this.selectedEdge ? "edge" : "node", selectedEdge: this.selectedEdge, modality: this.modality, showRejected: this.showRejected,
      layout: this.layout, storageError: this.storageError, countError: this.countError, searchError: this.searchError, saving: this.saving, visibleEdges: GS.visibleEdges(this.model, this).map((e) => ({ id: e.id, status: e.status, matchTypes: e.matchTypes })),
      pinned: [...this.model.nodes.values()].filter((n) => Number.isFinite(n.fx)).map((n) => ({ path: n.path, fx: n.fx, fy: n.fy })),
      counts: [...this.model.nodes.values()].map((n) => ({ path: n.path, unexpandedCount: n.unexpandedCount })),
      inspectorWidth: this.el("graph-inspector").getBoundingClientRect().width,
      hash: this.hashCache.get(GS.nodeKey(this.model.nodes.get(this.selected) || { path: "" }, this.code)) };
  },
};
