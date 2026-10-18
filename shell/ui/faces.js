"use strict";

class FaceSearchView {
  constructor({ ask, invoke, rendered, fileURL, picture, nameOf, clock, onVisibility, onGraph }) {
    Object.assign(this, { ask, invoke, rendered, fileURL, picture, nameOf, clock, onVisibility, onGraph });
    this.el = (id) => document.getElementById(id);
    this.visible = false; this.selection = new FaceState.Selection(); this.fileGeneration = 0; this.statusGeneration = 0; this.openGeneration = 0;
    this.statusHistory = [];
    this.fileFaces = []; this.fileOffset = 0; this.imageTasks = new Map(); this.minimum = .5;
    this.cropLoads = new Map();
    this.cropObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) {
        const load = this.cropLoads.get(entry.target); this.cropLoads.delete(entry.target); this.cropObserver.unobserve(entry.target);
        if (load) { entry.target.dataset.requested = "true"; load(); }
      }
    }, { rootMargin: "120px" });
    this.deviceReady = this.invoke("face_device").then((device) => { this.el("face-device").value = ["auto", "cpu", "gpu"].includes(device) ? device : "auto"; })
      .catch(() => { this.deviceSaveError = true; }).finally(() => { this.deviceLoaded = true; if (this.visible) this.renderStatus(); });
    this.el("face-device").onchange = () => this.saveDevice();
    this.el("face-back").onclick = () => this.close();
    this.el("face-refresh").onclick = () => { this.refreshTask = this.refresh(); };
    this.el("face-start").onclick = () => this.start();
    this.el("face-cancel").onclick = () => this.cancel();
    this.el("face-file-more").onclick = () => this.loadFile(true);
    this.el("face-search-more").onclick = () => this.search(this.searchExpired ? false : true);
    this.el("face-minimum").onchange = () => {
      this.minimum = Number(this.el("face-minimum").value);
      if (this.selection.seed) this.choose(this.selection.seed);
    };
    this.el("face-show-graph").onclick = () => {
      if (!this.selection.seed || !this.selection.hits.length) return;
      const seed = { ...this.file, ...this.selection.seed }, reply = { hits: this.selection.hits, total: this.selection.total,
        next_offset: this.selection.offset, has_more: this.selection.hasMore, index_revision: this.selection.indexRevision };
      this.close(false); this.onGraph(seed, reply, this.minimum);
    };
    document.addEventListener("ui-language-changed", () => { if (this.visible) this.render(); this.updateGraphAvailability(); });
  }
  async status() {
    const generation = ++this.statusGeneration;
    try {
      const reply = await this.ask({ op: "face_status" });
      if (generation !== this.statusGeneration) return;
      if (reply.ok === false) throw new Error(reply.error);
      const previous = this.index;
      this.index = reply; this.statusError = null;
      const progress = { state: reply.state, done: reply.done, total: reply.total, faces: reply.faces, frames: reply.frames, device: reply.device_active || reply.device };
      if (JSON.stringify(progress) !== JSON.stringify(this.statusHistory.at(-1))) this.statusHistory.push(progress);
      if (this.statusHistory.length > 100) this.statusHistory.shift();
      this.updateGraphAvailability();
      this.auto?.statusChanged(reply);
      if (this.visible) {
        this.renderStatus();
        if (this.file && previous?.state !== reply.state && ["completed", "cancelled", "paused", "error"].includes(reply.state)) {
          if (this.selection.seed) { this.autoFileChanged = true; this.renderSource(); }
          else await this.loadFile();
        }
      }
      return reply;
    } catch (error) {
      if (generation === this.statusGeneration) { this.statusError = String(error.message || error); this.auto?.render(); if (this.visible) this.renderStatus(); }
    }
  }
  updateGraphAvailability() {
    const button = document.querySelector('[data-graph-modality="face"]');
    if (!button) return;
    button.disabled = !(this.index?.models_ready && this.index?.worker_available);
    const title = button.disabled ? "Face models are not ready. Open Faces to set up the local index." : "Choose a face in the selected file";
    button.dataset.i18nTitle = title; button.title = t(title);
  }
  async open(file = null) {
    const generation = ++this.openGeneration;
    if (file && !FaceState.isMedia(file)) file = null;
    const changed = this.file?.path !== file?.path;
    this.visible = true; this.file = file; this.onVisibility(true);
    if (changed) { this.fileGeneration++; this.selection.clear(); this.fileFaces = []; this.fileReply = null; this.fileError = null; this.resultPreviewKey = null; this.people?.faceSelected(); }
    this.render(); clearInterval(this.pollTimer);
    if (!this.auto) this.pollTimer = setInterval(() => { if (!document.hidden) this.status(); }, 1200);
    await Promise.all([this.status(), this.deviceReady]);
    if (this.visible && generation === this.openGeneration && file) await this.loadFile();
  }
  close(restore = true) {
    this.cropObserver.disconnect(); this.cropLoads.clear();
    this.visible = false; this.fileGeneration++; this.selection.generation++; this.statusGeneration++; this.openGeneration++;
    this.searchBusy = false;
    clearInterval(this.pollTimer); this.stopMedia(); this.onVisibility(false, restore);
  }
  stopMedia() { this.el("faces-view").querySelectorAll("video,audio").forEach((player) => player.pause()); }
  async saveDevice() {
    const device = this.el("face-device").value;
    this.deviceSaving = true; this.deviceSaveError = false; this.renderStatus();
    try { await this.invoke("set_face_device", { device }); if (this.index?.auto_enabled === true) await this.auto?.setEnabled(true); }
    catch { this.deviceSaveError = true; }
    finally { this.deviceSaving = false; if (this.visible) this.renderStatus(); }
  }
  async refresh() {
    await this.status();
    if (!this.visible) return;
    this.autoFileChanged = false;
    const seed = this.selection.seed;
    if (this.file) await this.loadFile();
    if (seed && this.fileFaces.some((face) => FaceState.faceKey(face) === FaceState.faceKey(seed))) this.choose(seed);
  }
  async start() {
    if (this.actionBusy) return;
    this.actionBusy = true; this.statusError = null; this.renderStatus();
    try {
      const reply = await this.ask({ op: "face_start", download: true, device: this.el("face-device").value, sample_seconds: 2 });
      if (reply.ok === false) throw new Error(reply.error);
      this.statusGeneration++; this.index = reply; this.updateGraphAvailability(); this.auto?.statusChanged(reply);
    } catch (error) { this.statusError = String(error.message || error); }
    finally { this.actionBusy = false; if (this.visible) this.renderStatus(); }
  }
  async cancel() {
    if (this.actionBusy) return;
    this.actionBusy = true; this.renderStatus();
    try {
      const reply = await this.ask({ op: "face_cancel" });
      if (reply.ok === false) throw new Error(reply.error);
      this.statusGeneration++; this.index = reply; this.auto?.statusChanged(reply);
    } catch (error) { this.statusError = String(error.message || error); }
    finally { this.actionBusy = false; if (this.visible) this.renderStatus(); }
  }
  renderStatus() {
    const index = this.index || {}, busy = index.active === true || ["running", "downloading", "cancelling"].includes(index.state);
    const states = { idle: "Face index is ready to start", downloading: "Downloading face models…", running: "Indexing faces…", paused: "Face indexing paused",
      cancelled: "Face indexing paused", completed: "Face indexing complete", error: "Face indexing stopped with an error", cancelling: "Pausing face indexing…" };
    this.el("face-index-title").textContent = this.statusError ? t("Face index unavailable") :
      t(index.state === "completed" && index.failed > 0 ? "Face indexing completed with issues" : states[index.state] || "Checking the face index…");
    this.el("face-index-count").textContent = this.index ? t("{done} / {total} files · {faces} face observations · {failed} failed", {
      done: index.done ?? 0, total: index.total ?? 0, faces: index.faces ?? 0, failed: index.failed ?? 0 }) : "";
    const progress = this.el("face-index-progress"); progress.hidden = !busy;
    if (index.state === "downloading" && index.download_total > 0) { progress.max = index.download_total; progress.value = Math.min(index.download_total, index.download_bytes || 0); }
    else if (busy && index.total > 0) { progress.max = index.total; progress.value = Math.min(index.total, index.done || 0); }
    else progress.removeAttribute("value");
    const detail = this.el("face-index-detail"); detail.classList.toggle("face-error", !!this.statusError || !!index.error);
    detail.textContent = this.statusError || index.error ? t(this.statusError || index.error) : (!index.worker_available ? t("The face runtime is missing. Reinstall the complete DigUp package.") :
      !index.models_ready ? t("Download verified YuNet and SFace weights, then index photos and sampled video frames locally. Your media stays on this computer.") :
        t("Video sampling: every 2 seconds. Existing indexed files are retained; unchanged face observations are reused."));
    if (index.state === "running" && index.total_frames > 0) detail.textContent += " " + t("Current video: {done} / {total} frames", { done: index.current_frame || 0, total: index.total_frames });
    const start = this.el("face-start"); start.hidden = busy;
    start.disabled = !!this.actionBusy || !!this.deviceSaving || !this.deviceLoaded || !index.worker_available || !!this.statusError;
    start.textContent = t(!index.models_ready ? "Download models and index faces" : ["paused", "cancelled", "error"].includes(index.state) ? "Resume face indexing" : "Index faces");
    const cancel = this.el("face-cancel"); cancel.hidden = !busy; cancel.disabled = !!this.actionBusy || index.state === "cancelling";
    this.el("face-device").disabled = busy || !!this.actionBusy || !!this.deviceSaving || !this.deviceLoaded;
    const active = index.device_active || index.device;
    this.el("face-device-status").textContent = active && active !== "unknown" ? t("Active: {device}", { device: active }) + (index.fallback_reason ? " · " + t("CPU fallback: {reason}", { reason: index.fallback_reason }) : "") :
      t("GPU acceleration uses DirectML when available; otherwise CPU.");
    if (this.deviceSaveError) this.el("face-device-status").textContent += " " + t("Could not save the face processing device. Check access to settings and select it again.");
    this.el("face-device-status").classList.toggle("face-error", !!this.deviceSaveError);
  }
  async loadFile(more = false) {
    if (!this.file || this.fileBusy && more) return;
    const generation = more ? this.fileGeneration : ++this.fileGeneration, file = this.file;
    this.fileBusy = true; this.fileError = null;
    if (!more) { this.fileFaces = []; this.fileOffset = 0; this.fileReply = null; }
    this.renderSource();
    try {
      const reply = await this.ask({ op: "face_file", path: file.path, offset: more ? this.fileOffset : 0, limit: 60 });
      if (generation !== this.fileGeneration || !this.visible) return;
      if (reply.ok === false) throw new Error(reply.error);
      const previousOffset = this.fileOffset;
      const existing = new Set(this.fileFaces.map(FaceState.faceKey));
      this.fileFaces.push(...(reply.faces || []).filter((face) => FaceState.boxOf(face) && !existing.has(FaceState.faceKey(face)) && existing.add(FaceState.faceKey(face))));
      this.fileReply = reply; this.fileOffset = reply.next_offset || this.fileFaces.length;
      this.fileMore = !!reply.has_more && this.fileOffset > previousOffset;
      if (!more && this.selection.seed && !this.fileFaces.some((face) => FaceState.faceKey(face) === FaceState.faceKey(this.selection.seed))) {
        this.selection.clear(); this.resultPreviewKey = null; this.renderMatches();
      }
    } catch (error) { if (generation === this.fileGeneration) this.fileError = String(error.message || error); }
    finally { if (generation === this.fileGeneration) { this.fileBusy = false; if (this.visible) this.renderSource(); } }
  }
  render() { this.renderStatus(); this.renderSource(); this.renderMatches(); }
  sourceFace() { return this.selection.seed || this.fileFaces[0] || { loc: this.file?.loc ?? null }; }
  renderSource() {
    this.el("face-source-title").textContent = this.file ? this.nameOf(this.file.path) : t("Choose a photo or video from search results");
    this.el("face-source-title").title = this.file?.path || "";
    const face = this.sourceFace();
    this.el("face-source-time").textContent = this.file?.kind === "video" && Number.isFinite(face.loc) ? this.clock(face.loc) : "";
    const message = this.el("face-file-message"); message.classList.toggle("face-error", !!this.fileError || !!this.fileReply?.stale);
    message.textContent = this.fileError || (!this.file ? t("Open a photo or video, then choose Faces. You can prepare the face index here first.") :
      this.fileBusy ? t("Loading face observations…") : !this.fileReply?.indexed ? t("This file has not been processed for faces. Start or resume face indexing above.") :
      this.fileReply?.stale ? t("This file changed. Run face indexing again before searching its faces.") :
      !this.fileFaces.length ? t("No usable face was detected in this file. Small, blurred or briefly visible faces can be missed.") :
      t("Choose one face in the picture or below. Each video observation has its own timestamp."));
    if (this.autoFileChanged && !this.fileBusy) message.textContent += " " + t("Face indexing updated. Refresh to update observations; your current query is unchanged.");
    const choices = this.el("face-choices"); choices.replaceChildren();
    for (const [index, observation] of this.fileFaces.entries()) {
      const button = document.createElement("button"); button.type = "button"; button.className = "face-choice";
      button.dataset.faceId = FaceState.faceKey(observation); button.setAttribute("aria-pressed", String(FaceState.faceKey(observation) === FaceState.faceKey(this.selection.seed || {})));
      button.disabled = !!this.fileReply?.stale;
      const label = this.file.kind === "video" ? `${this.clock(observation.loc ?? 0)} · ${index + 1}` : t("Face {number}", { number: index + 1 });
      button.setAttribute("aria-label", label); button.append(this.crop({ ...this.file, ...observation }), this.text("span", "", label));
      button.onclick = () => this.choose(observation); choices.append(button);
    }
    this.el("face-file-more").hidden = !this.fileMore; this.el("face-file-more").disabled = !!this.fileBusy;
    this.showSourceImage(face);
  }
  imageFor(hit, pixels = 720) {
    const kind = hit.kind === "video" ? "video" : "image", loc = kind === "video" ? hit.loc ?? 0 : null;
    const key = JSON.stringify([hit.path, hit.modified, hit.size, kind, loc, pixels]);
    if (!this.imageTasks.has(key)) {
      const task = this.rendered(hit.path, kind, loc, pixels, { modified: hit.modified, size: hit.size }).then((path) => {
        if (!path) throw new Error("Preview unavailable"); return this.fileURL(path);
      }).finally(() => { this.imageTasks.delete(key); });
      this.imageTasks.set(key, task);
      // Only in-flight tasks are shared. The native versioned cache owns completed-path reuse and eviction.
      if (this.imageTasks.size > 350) this.imageTasks.delete(this.imageTasks.keys().next().value);
    }
    return this.imageTasks.get(key);
  }
  showSourceImage(face) {
    const host = this.el("face-source-image");
    if (!this.file) { host.replaceChildren(this.text("p", "", t("No file selected"))); this.sourceImageKey = null; return; }
    const file = { ...this.file, loc: face.loc }, key = JSON.stringify([this.file.path, face.loc, this.fileReply?.stale, this.fileGeneration]);
    if (this.sourceImageKey === key) { this.renderBoxes(); return; }
    this.sourceImageKey = key;
    const content = this.text("div", "face-image-content"), image = document.createElement("img"); image.alt = this.nameOf(file.path);
    content.append(image); host.replaceChildren(content);
    image.onload = () => { if (key === this.sourceImageKey) this.renderBoxes(); };
    image.onerror = () => { if (key === this.sourceImageKey) host.replaceChildren(this.text("p", "", t("Preview unavailable. Open the file in its default app."))); };
    this.imageFor(file).then((url) => { if (key === this.sourceImageKey) image.src = url; }).catch(() => { if (key === this.sourceImageKey) image.onerror(); });
  }
  renderBoxes() {
    const content = this.el("face-source-image").querySelector(".face-image-content"); if (!content) return;
    content.querySelectorAll(".face-box").forEach((box) => box.remove());
    const location = this.sourceFace().loc;
    this.fileFaces.forEach((face, index) => {
      if (this.fileReply?.stale || (this.file.kind === "video" && face.loc !== location)) return;
      const box = FaceState.boxOf(face); if (!box) return;
      const button = document.createElement("button"); button.type = "button"; button.className = "face-box"; button.dataset.faceId = FaceState.faceKey(face);
      const label = t("Face {number}", { number: index + 1 }); button.setAttribute("aria-label", label);
      button.setAttribute("aria-pressed", String(FaceState.faceKey(face) === FaceState.faceKey(this.selection.seed || {})));
      Object.assign(button.style, { left: `${box[0] * 100}%`, top: `${box[1] * 100}%`, width: `${box[2] * 100}%`, height: `${box[3] * 100}%` });
      button.append(this.text("span", "", String(index + 1))); button.onclick = () => this.choose(face); content.append(button);
    });
  }
  crop(hit, { defer } = {}) {
    const crop = this.text("span", "face-crop"); crop.setAttribute("aria-hidden", "true");
    const box = FaceState.boxOf(hit); if (!box) return crop;
    const load = () => this.imageFor(hit, 1600).then(async (url) => {
      const image = new Image(); image.src = url; await image.decode();
      const portrait = FaceState.portrait(hit, image.naturalWidth, image.naturalHeight);
      if (!portrait) throw new Error("Preview unavailable");
      crop.style.backgroundImage = `url(${JSON.stringify(url)})`;
      crop.style.backgroundSize = portrait.size;
      crop.style.backgroundPosition = portrait.position;
      crop.dataset.portrait = JSON.stringify(portrait);
      crop.dataset.loaded = "true";
      crop.dataset.imageUrl = url;
    }).catch(() => { crop.classList.add("unavailable"); });
    if (defer) defer(load, crop);
    else {
      this.cropLoads.set(crop, load); this.cropObserver.observe(crop);
      if (!this.cropCleanup) {
        this.cropCleanup = true;
        queueMicrotask(() => {
          this.cropCleanup = false;
          for (const node of this.cropLoads.keys()) if (!node.isConnected) { this.cropObserver.unobserve(node); this.cropLoads.delete(node); }
        });
      }
    }
    return crop;
  }
  choose(face) {
    if (this.fileReply?.stale) return;
    this.stopMedia(); this.selection.select({ ...this.file, ...face }); this.searchError = null; this.searchExpired = false; this.searchRestartNotice = false; this.selectedResult = null; this.resultPreviewKey = null;
    this.people?.faceSelected();
    this.renderSource(); this.renderMatches(); return this.search();
  }
  async search(more = false) {
    const seed = this.selection.seed, generation = this.selection.generation;
    if (!seed || this.searchBusy && more) return;
    this.searchBusy = true; this.searchError = null; this.renderMatches();
    try {
      let offset = more ? this.selection.offset : 0, revision = more ? this.selection.indexRevision : null, restarted = false;
      for (let attempt = 0; attempt < 2; attempt++) {
        const reply = await this.ask({ op: "face_search", face_id: seed.id ?? seed.face_id, minimum_cosine: this.minimum, offset, limit: 40,
          ...(offset > 0 ? { index_revision: revision } : {}) });
        if (generation !== this.selection.generation || !this.visible) return;
        if (reply.expired) {
          this.searchExpired = true;
          if (attempt === 0) { restarted = true; this.searchRestarting = true; this.renderMatches(); offset = 0; revision = null; continue; }
        }
        if (reply.ok === false) throw new Error(reply.error);
        this.selection.merge(reply, generation, { replace: restarted || !more });
        this.searchExpired = false; this.searchRestartNotice = restarted || this.searchRestartNotice;
        if (!this.selection.hits.some((hit) => FaceState.faceKey(hit) === this.selectedResult)) {
          this.stopMedia(); this.selectedResult = this.selection.hits.length ? FaceState.faceKey(this.selection.hits[0]) : null;
        }
        return;
      }
    } catch (error) { if (generation === this.selection.generation) this.searchError = String(error.message || error); }
    finally { if (generation === this.selection.generation) { this.searchBusy = false; this.searchRestarting = false; if (this.visible) this.renderMatches(); } }
  }
  renderMatches() {
    const selection = this.selection, message = this.el("face-search-message");
    message.classList.toggle("face-error", !!this.searchError);
    message.textContent = this.searchError ? t(this.searchError) : (this.searchRestarting ? t("Face index changed. Restarting the face search…") : this.searchBusy ? t("Comparing face observations locally…") : !selection.seed ? t("Select one face to find matching observations.") :
      selection.hits.length ? t("{loaded} of {total} face observations loaded · cosine ≥ {minimum}", { loaded: selection.hits.length, total: selection.total, minimum: this.minimum.toFixed(3) }) :
      t("No face observations meet this threshold. Try 0.363 or index more files."));
    if (this.searchRestartNotice && !this.searchBusy && !this.searchError) message.textContent += " " + t("The index changed; results restarted from the first page.");
    this.el("face-show-graph").disabled = !selection.hits.length || !!this.searchBusy;
    this.el("face-search-more").hidden = !selection.hasMore && !this.searchExpired;
    this.el("face-search-more").textContent = t(this.searchExpired ? "Refresh matches" : "Show more");
    this.el("face-search-more").disabled = !!this.searchBusy;
    const list = this.el("face-results-list"), scroll = list.scrollTop; list.replaceChildren();
    for (const hit of selection.hits) {
      const button = document.createElement("button"); button.type = "button"; button.className = "face-result";
      button.dataset.faceId = FaceState.faceKey(hit); button.setAttribute("aria-pressed", String(this.selectedResult === FaceState.faceKey(hit)));
      const text = this.text("span", "face-result-text"); text.append(this.text("strong", "", this.nameOf(hit.path)),
        this.text("span", "", t("Cosine {value}", { value: hit.cosine.toFixed(3) }) + (hit.kind === "video" && Number.isFinite(hit.loc) ? ` · ${this.clock(hit.loc)}` : "")));
      button.append(this.crop(hit), text); button.onclick = () => { this.stopMedia(); this.selectedResult = FaceState.faceKey(hit); this.renderMatches(); };
      const line = this.text("div", "face-result-line"), check = document.createElement("input"); check.type = "checkbox"; check.dataset.faceId = FaceState.faceKey(hit);
      check.setAttribute("aria-label", t("Select observation in {name}", { name: this.nameOf(hit.path) }));
      check.onchange = () => { this.people?.faceBulk.toggle(check.dataset.faceId, check.checked); if (this.people) this.people.bulkResetNotice = false; this.people?.renderFaceControls(); };
      line.append(check, button); list.append(line);
    }
    list.scrollTop = scroll; this.renderMatchPreview(); this.people?.renderFaceControls();
  }
  renderMatchPreview() {
    const hit = this.selection.hits.find((item) => FaceState.faceKey(item) === this.selectedResult), key = hit ? FaceState.faceKey(hit) + I18n.language : null;
    if (this.resultPreviewKey === key) return;
    this.resultPreviewKey = key; const host = this.el("face-match-preview"); host.querySelectorAll("audio,video").forEach((player) => player.pause()); host.replaceChildren();
    if (!hit) return;
    host.append(this.picture(hit, { code: false, query: "" }), this.text("h3", "", this.nameOf(hit.path)),
      this.text("p", "", t("Cosine {value}", { value: hit.cosine.toFixed(3) })),
      this.text("p", "", hit.kind === "video" && Number.isFinite(hit.loc) ? t("Matched frame at {time}", { time: this.clock(hit.loc) }) : t("Matched face in photograph")));
    const actions = this.text("div", "graph-actions");
    const add = (label, action) => { const button = this.text("button", "quiet-button", label); button.type = "button"; button.onclick = action; actions.append(button); };
    add(t("Open"), () => this.invoke("open_path", { path: hit.path }).catch((error) => { this.searchError = String(error); this.renderMatches(); }));
    add(t("Show in Explorer"), () => this.invoke("reveal", { path: hit.path }).catch((error) => { this.searchError = String(error); this.renderMatches(); }));
    add(t("Choose another face in this file"), () => this.open(hit));
    host.append(actions);
  }
  text(tag, className, value) { const node = document.createElement(tag); node.className = className; if (value != null) node.textContent = value; return node; }
  debug() {
    return { visible: this.visible, status: this.index, statusError: this.statusError, file: this.file?.path, faces: this.fileFaces,
      fileReply: this.fileReply, fileError: this.fileError, seed: this.selection.seed, matches: this.selection.hits,
      total: this.selection.total, offset: this.selection.offset, hasMore: this.selection.hasMore, indexRevision: this.selection.indexRevision, searchBusy: this.searchBusy,
      progressHistory: this.statusHistory,
      error: this.searchError, selectedResult: this.selectedResult,
      sourceLoaded: !!this.el("face-source-image").querySelector("img")?.naturalWidth,
      loadedCrops: this.el("faces-view").querySelectorAll('[data-loaded="true"]').length };
  }
  autoDebug() { return this.auto?.debug() || null; }
}

// The helper schedules work. This controller only observes local state and sends
// explicit preference changes; it never starts inference or downloads on a timer.
class FaceAutoStatus {
  constructor({ faces, people, ask }) {
    Object.assign(this, { faces, people, ask }); this.el = (id) => document.getElementById(id);
    this.summaryGeneration = 0; this.history = []; this.summaryHistory = []; this.summary = null;
    this.el("face-auto-enabled").onchange = () => { this.actionTask = this.preferenceTask = this.setEnabled(this.el("face-auto-enabled").checked); };
    this.el("face-auto-open").onclick = () => {
      if (this.faces.index?.active) { this.pauseTask = this.faces.cancel(); return; }
      if (!this.faces.visible) this.el("faces-toggle").click();
    };
    this.timer = setInterval(() => { if (!document.hidden) this.refresh(false); }, 2000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) this.refresh(); });
    document.addEventListener("ui-language-changed", () => { this.render(); this.renderSummary(); });
    window.addEventListener("pagehide", () => clearInterval(this.timer), { once: true });
    window.__TAURI__?.event.listen("search-scope-changed", () => this.invalidateScope()).catch(() => {});
    this.ready = Promise.resolve().then(() => this.refresh());
  }
  async refresh(force = true) {
    if (this.refreshBusy) return this.refreshTask;
    this.refreshBusy = true;
    this.refreshTask = (async () => {
      await this.faces.status();
      if (force || Date.now() >= (this.summaryDue || 0)) await this.refreshSummary();
    })().finally(() => { this.refreshBusy = false; });
    return this.refreshTask;
  }
  statusChanged(status) {
    const progress = { state: status.state, auto_state: status.auto_state, enabled: status.auto_enabled, pending: status.auto_pending,
      done: status.done, total: status.total, faces: status.faces, frames: status.frames, active: status.active };
    if (JSON.stringify(progress) !== JSON.stringify(this.history.at(-1))) this.history.push(progress);
    if (this.history.length > 120) this.history.shift();
    if (this.lastState && this.lastState !== status.state) this.summaryDue = 0;
    this.lastState = status.state; this.render();
  }
  async setEnabled(enabled) {
    if (this.preferenceBusy) return;
    this.preferenceBusy = true; this.preferenceError = null; this.render();
    try {
      const reply = await this.ask({ op: "face_auto", enabled, device: this.faces.el("face-device").value });
      if (reply.ok === false) throw new Error(reply.error);
      this.faces.statusGeneration++; this.faces.index = reply; this.faces.statusError = null; this.statusChanged(reply);
      if (this.faces.visible) this.faces.renderStatus();
      await this.refreshSummary();
    } catch (error) { this.preferenceError = String(error.message || error); }
    finally { this.preferenceBusy = false; this.render(); }
  }
  render() {
    const state = this.faces.index || {}, busy = state.active || ["running", "downloading", "cancelling"].includes(state.state), enabled = state.auto_enabled === true;
    const error = this.preferenceError || this.faces.statusError || state.auto_error || (state.state === "error" ? state.error : null);
    const checkbox = this.el("face-auto-enabled"); checkbox.checked = enabled; checkbox.disabled = this.preferenceBusy || !this.faces.index || !this.faces.deviceLoaded;
    const message = this.el("face-auto-message"); message.classList.toggle("face-error", !!error);
    const descriptions = { waiting_for_index: "Faces: waiting for new indexed media", waiting_for_models: "Faces: model setup required", waiting_for_runtime: "Faces: runtime unavailable",
      waiting: "Faces: waiting for new indexed media", paused: "Automatic face indexing is paused", idle: "Faces: waiting for new indexed media", ready: "Faces: preparing pending media" };
    message.textContent = error ? t(error) : busy ? t("Faces: {done} / {total} files · {faces} observations", { done: state.done || 0, total: state.total || 0, faces: state.faces || 0 }) :
      !state.models_ready ? t("Faces: model setup required") : !enabled ? t(state.auto_paused ? "Automatic face indexing is paused" : "Automatic face indexing is off") :
      t(descriptions[state.auto_state] || "Faces: waiting for new indexed media");
    if (enabled && Number.isFinite(state.auto_pending) && state.auto_pending > 0) message.textContent += " · " + t("{count} media files waiting", { count: state.auto_pending });
    if (!busy && state.failed > 0) message.textContent += " · " + t("{count} face files failed", { count: state.failed });
    message.title = message.textContent;
    const bar = this.el("face-auto-progress"); bar.hidden = !busy;
    if (busy && state.total > 0) { bar.max = state.total; bar.value = Math.min(state.total, state.done || 0); } else bar.removeAttribute("value");
    const open = this.el("face-auto-open"); open.disabled = this.preferenceBusy || !!this.faces.actionBusy || state.state === "cancelling";
    open.textContent = t(busy ? "Pause indexing" : state.models_ready && state.worker_available ? "Faces" : "Set up Faces");
    document.dispatchEvent(new Event("background-status-changed"));
  }
  async refreshSummary(retry = false) {
    if (this.summaryBusy) {
      if (!retry) return this.summaryTask;
      await this.summaryTask;
      return this.refreshSummary(true);
    }
    this.summaryBusy = true; const generation = ++this.summaryGeneration;
    this.summaryTask = this.readSummary(generation, retry); return this.summaryTask;
  }
  async readSummary(generation, retry = false) {
    try {
      const reply = await this.ask({ op: "people_suggestions", minimum_cosine: .5, ...(retry ? { refresh: true } : {}) });
      if (generation !== this.summaryGeneration) return;
      if (reply.ok === false) throw new Error(reply.error);
      this.summary = reply; this.summaryError = null; this.summaryDue = Date.now() + (reply.state === "computing" ? 2000 : 10000);
      const entry = { state: reply.state, total: reply.total, index_revision: reply.index_revision, people_revision: reply.people_revision, scope_revision: reply.scope_revision };
      if (JSON.stringify(entry) !== JSON.stringify(this.summaryHistory.at(-1))) this.summaryHistory.push(entry);
      if (this.summaryHistory.length > 120) this.summaryHistory.shift();
      this.renderSummary(); this.people.backgroundSummary(reply);
    } catch (error) {
      if (generation === this.summaryGeneration) {
        this.summary = null; this.summaryError = String(error.message || error); this.summaryDue = Date.now() + 10000; this.renderSummary();
        this.people.backgroundSummary({ state: "error", people: [], total: null });
      }
    } finally { this.summaryBusy = false; }
  }
  renderSummary() {
    const badge = this.el("people-pending-badge"), summary = this.summary;
    badge.hidden = !this.summaryError && (!summary || summary.state === "idle" || summary.state === "ready" && summary.total === 0);
    badge.textContent = summary?.state === "ready" ? Number(summary.total || 0).toLocaleString(I18n.locale()) : summary?.state === "error" || this.summaryError ? "!" : "…";
    const title = summary?.state === "ready" ? t("{count} pending person-observation suggestions", { count: summary.total || 0 }) : summary?.state === "error" || this.summaryError ?
      t("Suggestion counts unavailable. Open People and refresh.") : t("Calculating pending person-observation suggestions…");
    badge.title = title; this.el("people-toggle").setAttribute("aria-label", t("People") + ": " + title);
    document.dispatchEvent(new Event("background-status-changed"));
  }
  invalidateScope() {
    this.summaryGeneration++; this.summary = null; this.summaryDue = 0; this.people.backgroundSummaryKey = null;
    this.renderSummary(); this.refresh();
  }
  debug() { return { status: this.faces.index, index: this.faces.index, error: this.preferenceError || this.faces.statusError, history: this.history, statusHistory: this.history, summaryHistory: this.summaryHistory, summary: this.summary,
    summaryError: this.summaryError, enabled: this.el("face-auto-enabled").checked, message: this.el("face-auto-message").textContent,
    badge: this.el("people-pending-badge").textContent, badgeVisible: !this.el("people-pending-badge").hidden,
    protectedReview: this.people.backgroundProtected, refreshNotice: this.people.backgroundNotice }; }
}
if (typeof module !== "undefined") module.exports = { FaceSearchView, FaceAutoStatus };
