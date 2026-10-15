"use strict";

class PeopleView {
  constructor({ ask, faceSearch, invoke, picture, nameOf, clock, onVisibility, onFace }) {
    Object.assign(this, { ask, faceSearch, invoke, picture, nameOf, clock, onVisibility, onFace });
    this.el = (id) => document.getElementById(id); this.people = []; this.page = new PeopleState.PersonPage(); this.faceBulk = new PeopleState.BulkSelection();
    this.selectedFaces = new Set(); this.visible = false; this.directoryGeneration = 0; this.faceLabelGeneration = 0;
    faceSearch.people = this;
    this.el("people-back").onclick = () => this.close();
    this.el("people-refresh").onclick = () => { this.refreshTask = this.refresh(); };
    this.el("people-filter").oninput = () => this.renderDirectory();
    this.el("people-create").onsubmit = (event) => { event.preventDefault(); this.createTask = this.create(this.el("people-new-name")); };
    this.el("face-person-create").onsubmit = (event) => { event.preventDefault(); this.createTask = this.create(this.el("face-person-name"), true); };
    this.el("face-person").onchange = () => { this.faceTarget = this.el("face-person").value; this.renderFaceControls(); };
    this.el("face-assign-seed").onclick = () => { this.mutationTask = this.assignSeed(); };
    this.el("face-select-loaded").onclick = () => { this.faceBulk.loaded(this.faceSearch.selection.hits); this.bulkResetNotice = false; this.renderFaceControls(); };
    this.el("face-select-all").onclick = () => { this.faceBulk.everything(); this.bulkResetNotice = false; this.renderFaceControls(); };
    this.el("face-clear-selected").onclick = () => { this.faceBulk.clear(); this.bulkResetNotice = false; this.renderFaceControls(); };
    this.el("face-assign-matches").onclick = () => { this.mutationTask = this.mutateFaceBulk("assign"); };
    this.el("face-reject-matches").onclick = () => { this.mutationTask = this.mutateFaceBulk("reject"); };
    for (const button of document.querySelectorAll("[data-person-mode]")) button.onclick = () => { this.pageTask = this.selectPerson(this.page.personId, button.dataset.personMode); };
    this.el("person-more").onclick = () => { this.pageTask = this.loadPage(true); };
    this.el("person-select-loaded").onclick = () => {
      const keys = this.page.hits.map((face) => face.anchor_key || PeopleState.idOf(face));
      this.selectedFaces = this.selectedFaces.size === keys.length ? new Set() : new Set(keys); this.renderPage();
    };
    this.el("person-assign").onclick = () => { this.mutationTask = this.mutatePersonFaces("assign"); };
    this.el("person-reject").onclick = () => { this.mutationTask = this.mutatePersonFaces("reject"); };
    this.el("person-remove").onclick = () => { this.mutationTask = this.mutatePersonFaces("remove"); };
    this.el("person-rename-toggle").onclick = () => { this.el("person-rename").hidden = false; this.el("person-name").value = this.person()?.name || ""; this.el("person-name").focus(); };
    this.el("person-rename-cancel").onclick = () => { this.el("person-rename").hidden = true; this.el("person-rename-toggle").focus(); };
    this.el("person-rename").onsubmit = (event) => { event.preventDefault(); this.mutationTask = this.rename(); };
    for (const id of ["people-undo", "face-label-undo"]) this.el(id).querySelector("button").onclick = () => { this.mutationTask = this.undo(); };
    document.addEventListener("ui-language-changed", () => { this.renderFaceControls(); if (this.visible) this.render(); });
    this.auto = new FaceAutoStatus({ faces: faceSearch, people: this, ask }); faceSearch.auto = this.auto; faceSearch.background = this.auto; window.faceAuto = this.auto;
  }
  text(tag, className, value) { const node = document.createElement(tag); node.className = className; if (value != null) node.textContent = value; return node; }
  person() { return this.people.find((person) => PeopleState.samePerson(person.id, this.page.personId)); }
  async open(personId = this.page.personId) {
    this.visible = true; this.onVisibility(true); this.render();
    await this.refreshDirectory(); if (!this.visible) return;
    const selected = this.people.find((person) => PeopleState.samePerson(person.id, personId)) || this.people[0];
    if (selected) await this.selectPerson(selected.id, "assigned");
  }
  close() { this.visible = false; this.page.generation++; this.directoryGeneration++; this.stopPreview(); this.onVisibility(false); }
  stopPreview() { this.el("person-preview").querySelectorAll("audio,video").forEach((player) => player.pause()); }
  async refreshDirectory() {
    const generation = ++this.directoryGeneration;
    try {
      const reply = await this.ask({ op: "people_list" });
      if (generation !== this.directoryGeneration) return;
      if (reply.ok === false) throw new Error(reply.error);
      this.people = reply.people || []; this.peopleRevision = reply.people_revision; this.indexRevision = reply.index_revision; this.directoryError = null;
      this.renderDirectory(); this.renderFaceControls();
    } catch (error) { if (generation === this.directoryGeneration) { this.directoryError = String(error.message || error); this.renderStatus(); this.renderFaceControls(); } }
  }
  async refresh() {
    await this.refreshDirectory();
    if (this.visible && this.page.personId) await this.selectPerson(this.page.personId, this.page.mode);
    await this.auto?.refreshSummary(true);
  }
  async selectPerson(id, mode = "assigned") {
    this.page.open(id, mode); this.pageBusy = false; this.selectedFaces.clear(); this.selectedPreview = null; this.previewKey = null; this.pageError = null; this.expired = false;
    this.previewTouched = false; this.backgroundNotice = false; this.backgroundProtected = false;
    this.el("person-rename").hidden = true; this.render(); return this.loadPage();
  }
  async loadPage(more = false) {
    if (!this.page.personId || this.pageBusy) return;
    if (!more) this.page.offset = 0;
    const generation = this.page.generation; this.pageBusy = true; this.pageError = null; this.renderPage();
    try {
      const reply = await this.ask(this.page.request());
      if (generation !== this.page.generation || !this.visible) return;
      if (reply.ok === false) { this.expired = !!reply.expired; throw new Error(reply.error); }
      this.page.merge(reply, generation); this.counts = reply.counts || {}; this.peopleRevision = reply.people_revision;
      if (reply.person) this.people = this.people.map((person) => PeopleState.samePerson(person.id, reply.person.id) ? { ...person, ...reply.person } : person);
      if (!this.selectedPreview && this.page.hits.length) this.selectedPreview = this.faceRowKey(this.page.hits[0]);
    } catch (error) { if (generation === this.page.generation) this.pageError = String(error.message || error); }
    finally { if (generation === this.page.generation) { this.pageBusy = false; if (this.visible) this.render(); } }
  }
  faceRowKey(face) { return face.anchor_key || PeopleState.idOf(face); }
  render() { this.renderStatus(); this.renderDirectory(); this.renderPage(); this.renderUndo(); }
  renderStatus() {
    this.el("people-status").textContent = this.mutationError ? t(this.mutationError) : this.directoryError ? t(this.directoryError) : this.notice ? (this.undoOperation ? t("Changes saved locally") : this.notice) : "";
    if (!this.mutationError && !this.directoryError && this.auto?.summary) {
      const summary = this.auto.summary;
      const pending = summary.state === "ready" ? t("Pending person-observation suggestions: {count}", { count: summary.total || 0 }) :
        summary.state === "computing" ? t("Calculating pending person-observation suggestions…") : summary.state === "error" ? t("Suggestion counts unavailable. Open People and refresh.") : "";
      if (pending) this.el("people-status").textContent += (this.el("people-status").textContent ? " · " : "") + pending;
    }
    if (!this.mutationError && !this.directoryError && this.auto?.summaryError) this.el("people-status").textContent += " " + t("Suggestion counts unavailable. Open People and refresh.");
    this.el("people-status").classList.toggle("face-error", !!this.mutationError || !!this.directoryError);
    this.el("people-refresh").disabled = !!this.mutationBusy;
    for (const form of ["people-create", "face-person-create", "person-rename"]) for (const control of this.el(form).querySelectorAll("input,button")) control.disabled = !!this.mutationBusy;
  }
  renderDirectory() {
    const list = this.el("people-list"), query = this.el("people-filter").value.normalize("NFKC").toLocaleLowerCase(); list.replaceChildren();
    const people = this.people.filter((person) => person.name.normalize("NFKC").toLocaleLowerCase().includes(query));
    for (const person of people) {
      const button = this.text("button", ""); button.type = "button"; button.dataset.personId = String(person.id); button.setAttribute("aria-pressed", String(PeopleState.samePerson(person.id, this.page.personId)));
      button.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="7" r="4"/><path d="M4 22V19A8 8 0 0 1 20 19V22"/></svg>';
      const label = this.text("span", ""); label.append(this.text("strong", "", person.name), this.text("small", "", t("{count} assigned observations", { count: person.assigned_count || 0 })));
      const summary = this.auto?.summary, pending = summary?.state === "ready" ? summary.people?.find((item) => PeopleState.samePerson(item.person_id, person.id))?.pending_count : null;
      if (Number.isFinite(pending) && pending > 0) label.append(this.text("small", "people-person-pending", t("{count} pending observations", { count: pending })));
      button.append(label); button.onclick = () => { this.pageTask = this.selectPerson(person.id); }; list.append(button);
    }
    if (!people.length) list.append(this.text("p", "", t(query ? "No matching person labels" : "Create a person label, then assign confirmed face observations.")));
  }
  renderPage() {
    const person = this.person(), mode = this.page.mode;
    this.el("person-title").textContent = person?.name || t("Choose a person");
    this.el("person-rename-toggle").disabled = !person || !!this.mutationBusy;
    for (const button of document.querySelectorAll("[data-person-mode]")) { button.setAttribute("aria-pressed", String(button.dataset.personMode === mode)); button.disabled = !person || !!this.pageBusy; }
    const messages = { assigned: "Assigned by you. Select an observation to preview it or remove its label.", suggestions: "Suggestions require your confirmation. Similarity is not proof of identity.",
      rejected: "Excluded observations are not suggested again for this person. Remove the exclusion to reconsider them.", stale: "The original file or face observation changed. These labels need review; they are not used to suggest new faces." };
    const message = this.el("person-message"); message.classList.toggle("face-error", !!this.pageError);
    message.textContent = this.pageError ? t(this.pageError) : this.pageBusy ? t("Loading person observations…") : !person ? t("Choose a person") :
      t(messages[mode]) + " " + t("{loaded} of {total} observations loaded", { loaded: this.page.hits.length, total: this.page.total });
    if (this.backgroundNotice && !this.pageBusy) message.textContent += " " + t("New face-index changes are available. Refresh to update this review; your current selection is unchanged.");
    const list = this.el("person-faces"), scroll = list.scrollTop; list.replaceChildren();
    for (const hit of this.page.hits) {
      const key = this.faceRowKey(hit), row = this.text("div", "people-face-row"), check = document.createElement("input");
      check.type = "checkbox"; check.dataset.faceKey = key; check.checked = this.selectedFaces.has(key); check.disabled = !!this.mutationBusy;
      check.setAttribute("aria-label", t("Select observation in {name}", { name: this.nameOf(hit.path) }));
      check.onchange = () => {
        if (check.checked) this.selectedFaces.add(key); else this.selectedFaces.delete(key); this.renderPage();
        [...list.querySelectorAll("input")].find((input) => input.dataset.faceKey === key)?.focus({ preventScroll: true });
      };
      const button = this.text("button", "face-result"); button.type = "button"; button.dataset.faceId = PeopleState.idOf(hit); button.setAttribute("aria-pressed", String(this.selectedPreview === key));
      const label = this.text("span", "face-result-text"); label.append(this.text("strong", "", this.nameOf(hit.path)),
        this.text("span", "", hit.kind === "video" && Number.isFinite(hit.loc) ? this.clock(hit.loc) : t("Photograph")));
      if (Number.isFinite(hit.cosine)) label.append(this.text("span", "", t("Cosine {value}", { value: hit.cosine.toFixed(3) })));
      if (hit.person && !PeopleState.samePerson(hit.person.id, person?.id)) label.append(this.text("span", "", t("Already labelled: {name}", { name: hit.person.name })));
      button.append(mode === "stale" ? this.text("span", "face-crop") : this.faceSearch.crop(hit), label); button.onclick = () => { this.stopPreview(); this.previewTouched = true; this.selectedPreview = key; this.renderPage(); }; row.append(check, button); list.append(row);
    }
    list.scrollTop = scroll;
    const selected = this.selectedFaces.size; this.el("person-selection-count").textContent = t("{count} selected", { count: selected });
    this.el("person-select-loaded").disabled = !this.page.hits.length || !!this.mutationBusy;
    for (const id of ["person-assign", "person-reject", "person-remove"]) this.el(id).disabled = !selected || !!this.mutationBusy || !!this.pageBusy;
    this.el("person-assign").hidden = mode !== "suggestions"; this.el("person-reject").hidden = mode !== "suggestions" && mode !== "assigned";
    this.el("person-remove").hidden = mode === "suggestions";
    this.el("person-remove").textContent = t(mode === "rejected" ? "Remove exclusion" : "Remove label");
    this.el("person-more").hidden = !this.page.hasMore; this.el("person-more").disabled = !!this.pageBusy || !!this.mutationBusy || this.expired;
    this.renderPreview();
  }
  renderPreview() {
    const hit = this.page.hits.find((face) => this.faceRowKey(face) === this.selectedPreview), key = hit ? `${this.faceRowKey(hit)}:${I18n.language}:${this.page.mode}` : null;
    const host = this.el("person-preview");
    if (!hit) { this.previewKey = null; this.stopPreview(); host.replaceChildren(this.text("p", "", t("No observation selected"))); return; }
    if (key === this.previewKey) return; this.previewKey = key; this.stopPreview(); host.replaceChildren();
    if (this.page.mode !== "stale") host.append(this.picture(hit, { code: false, query: "" }));
    host.append(this.text("h3", "", this.nameOf(hit.path)), this.text("p", "", hit.kind === "video" && Number.isFinite(hit.loc) ? t("Matched frame at {time}", { time: this.clock(hit.loc) }) : t("Matched face in photograph")));
    if (this.page.mode === "stale") return;
    const actions = this.text("div", "graph-actions"), open = this.text("button", "quiet-button", t("Open")), faces = this.text("button", "quiet-button", t("Find faces"));
    open.type = faces.type = "button"; open.onclick = () => this.invoke("open_path", { path: hit.path }).catch((error) => { this.mutationError = String(error); this.renderStatus(); });
    faces.onclick = () => this.onFace(hit); actions.append(open, faces); host.append(actions);
  }
  async create(input, fromFaces = false) {
    const name = input.value.trim(); if (!name || this.mutationBusy) return;
    const reply = await this.mutate({ op: "person_save", name, people_revision: this.peopleRevision }, t("Person label created"));
    if (!reply?.person) return; input.value = ""; this.faceTarget = String(reply.person.id); this.renderFaceControls();
    if (!fromFaces && this.visible) await this.selectPerson(reply.person.id);
  }
  async rename() {
    const name = this.el("person-name").value.trim(); if (!name || !this.person()) return;
    const reply = await this.mutate({ op: "person_save", person_id: this.page.personId, name, people_revision: this.peopleRevision }, t("Person label renamed"));
    if (reply) this.el("person-rename").hidden = true;
  }
  async mutate(request, message) {
    if (this.mutationBusy) return; this.mutationBusy = true; this.mutationError = null; this.renderStatus(); this.renderFaceControls(); if (this.visible) this.renderPage();
    try {
      const reply = await this.ask(request); if (reply.ok === false) throw new Error(reply.error);
      this.lastMutation = reply; this.peopleRevision = reply.people_revision;
      this.notice = message;
      if (Number.isFinite(reply.changed)) this.notice += " " + t("Changed: {changed} · conflicts skipped: {conflicts} · stale skipped: {stale} · excluded: {excluded}", { changed: reply.changed, conflicts: reply.skipped_conflicts || 0, stale: reply.skipped_stale || 0, excluded: reply.excluded || 0 });
      if (reply.operation_id) this.undoOperation = { id: reply.operation_id, message: this.notice };
      await this.refreshDirectory();
      if (this.visible && this.page.personId) { this.pageBusy = false; await this.selectPerson(this.page.personId, this.page.mode); }
      if (this.faceSearch.selection.seed) await this.loadFaceLabel();
      return reply;
    } catch (error) { this.mutationError = String(error.message || error); return null; }
    finally { this.mutationBusy = false; this.renderStatus(); this.renderFaceControls(); if (this.visible) this.renderPage(); this.renderUndo(); this.auto?.refreshSummary(); }
  }
  async undo() {
    if (!this.undoOperation) return;
    const reply = await this.mutate({ op: "people_undo", operation_id: this.undoOperation.id }, t("Last label change undone"));
    if (reply) { this.undoOperation = null; this.renderUndo(); }
  }
  renderUndo() {
    for (const id of ["people-undo", "face-label-undo"]) {
      const host = this.el(id); host.hidden = !this.undoOperation; host.querySelector("span").textContent = this.undoOperation?.message || ""; host.querySelector("button").disabled = !!this.mutationBusy;
    }
  }
  async faceSelected() {
    this.faceBulk.reset(null); this.faceLabel = null; this.faceLabelError = null; this.bulkResetNotice = false;
    this.renderFaceControls(); await this.refreshDirectory(); return this.loadFaceLabel();
  }
  async loadFaceLabel() {
    const face = this.faceSearch.selection.seed, generation = ++this.faceLabelGeneration;
    if (!face) { this.faceLabel = null; this.renderFaceControls(); return; }
    try {
      const reply = await this.ask({ op: "face_people", face_id: Number(PeopleState.idOf(face)) });
      if (generation !== this.faceLabelGeneration || PeopleState.idOf(this.faceSearch.selection.seed || {}) !== PeopleState.idOf(face)) return;
      if (reply.ok === false) throw new Error(reply.error);
      this.faceLabel = reply; this.peopleRevision = reply.people_revision; this.faceLabelError = null;
      if (reply.person) this.faceTarget = String(reply.person.id);
    } catch (error) { if (generation === this.faceLabelGeneration) this.faceLabelError = String(error.message || error); }
    finally { if (generation === this.faceLabelGeneration) this.renderFaceControls(); }
  }
  renderFaceControls() {
    const faces = this.faceSearch, selection = faces.selection, seed = selection.seed;
    const query = seed && Number.isSafeInteger(selection.indexRevision) ? { seed_face_id: Number(PeopleState.idOf(seed)), minimum_cosine: faces.minimum, index_revision: selection.indexRevision } : null;
    if (this.faceBulk.sync(query)) this.bulkResetNotice = true;
    const select = this.el("face-person"), current = this.faceTarget || select.value; select.replaceChildren(); const placeholder = this.text("option", "", t("Choose person")); placeholder.value = ""; select.append(placeholder);
    for (const person of this.people) { const option = this.text("option", "", person.name); option.value = String(person.id); select.append(option); }
    select.value = current; this.faceTarget = select.value;
    select.disabled = !!this.mutationBusy; this.el("face-assign-seed").disabled = !query || !this.faceTarget || !!this.mutationBusy || !!this.faceLabelError;
    this.el("face-person-status").textContent = this.mutationError ? t(this.mutationError) : this.faceLabelError ? t(this.faceLabelError) : this.directoryError ? t(this.directoryError) :
      this.faceLabel?.person ? t("Labelled: {name}", { name: this.faceLabel.person.name }) : t("Select a face and assign your own local person label.");
    if (this.notice && !this.mutationError && !this.faceLabelError) this.el("face-person-status").textContent += " " + (this.undoOperation ? t("Changes saved locally") : this.notice);
    this.el("face-person-status").classList.toggle("face-error", !!this.mutationError || !!this.faceLabelError || !!this.directoryError);
    const total = selection.total, count = this.faceBulk.count(total);
    this.el("face-selected-count").textContent = this.bulkResetNotice ? t("The face query changed; the selection was cleared.") : this.faceBulk.all ? t("All {count} observations, including unloaded matches and source", { count }) : t("{count} selected", { count });
    for (const id of ["face-select-loaded", "face-select-all", "face-clear-selected"]) this.el(id).disabled = !query || !!faces.searchBusy || !!this.mutationBusy;
    for (const id of ["face-assign-matches", "face-reject-matches"]) this.el(id).disabled = !count || !this.faceTarget || !!faces.searchBusy || !!this.mutationBusy;
    for (const check of this.el("face-results-list").querySelectorAll('input[data-face-id]')) { check.checked = this.faceBulk.checked(check.dataset.faceId); check.disabled = !!this.mutationBusy || !!faces.searchBusy; }
    this.renderUndo();
  }
  async assignSeed() {
    const seed = this.faceSearch.selection.seed; if (!seed || !this.faceTarget) return;
    return this.mutate({ op: "face_label", action: "assign", person_id: this.faceTarget, face_ids: [Number(PeopleState.idOf(seed))],
      index_revision: this.faceSearch.selection.indexRevision, people_revision: this.peopleRevision }, t("Face labels updated"));
  }
  async mutateFaceBulk(action) {
    if (!this.faceTarget) return;
    let request; try { request = this.faceBulk.request(this.faceTarget, action, this.peopleRevision); } catch (error) { this.mutationError = String(error.message); this.renderFaceControls(); return; }
    const reply = await this.mutate(request, t(action === "reject" ? "Observations excluded for this person" : "Face labels updated"));
    if (reply) { this.faceBulk.clear(); this.renderFaceControls(); }
    return reply;
  }
  async mutatePersonFaces(action) {
    const chosen = this.page.hits.filter((face) => this.selectedFaces.has(this.faceRowKey(face)));
    const request = { op: "face_label", action, person_id: this.page.personId, index_revision: this.page.indexRevision, people_revision: this.peopleRevision };
    if (this.page.mode === "stale") request.anchor_keys = chosen.map((face) => face.anchor_key);
    else request.face_ids = chosen.map((face) => Number(PeopleState.idOf(face)));
    return this.mutate(request, t(action === "reject" ? "Observations excluded for this person" : "Face labels updated"));
  }
  backgroundPolicy() {
    return PeopleState.backgroundRefreshPolicy({ visible: this.visible, mode: this.page.mode, checked: this.selectedFaces.size,
      editing: !this.el("person-rename").hidden, busy: !!this.mutationBusy || !!this.pageBusy, previewTouched: this.previewTouched,
      playing: [...this.el("person-preview").querySelectorAll("audio,video")].some((player) => !player.paused), offset: this.page.offset });
  }
  async backgroundSummary(summary) {
    const key = PeopleState.revisionKey(summary), changed = this.backgroundSummaryKey !== key;
    this.renderStatus();
    const focus = document.activeElement?.dataset.personId; this.renderDirectory();
    if (focus) [...this.el("people-list").querySelectorAll("button")].find((button) => button.dataset.personId === focus)?.focus({ preventScroll: true });
    if (!changed || summary.state !== "ready") return;
    this.backgroundSummaryKey = key;
    if (!this.visible || this.page.mode !== "suggestions" || !this.page.personId ||
      this.page.indexRevision === summary.index_revision && this.page.peopleRevision === summary.people_revision) return;
    if (this.backgroundPolicy() !== "refresh") { this.backgroundNotice = true; this.backgroundProtected = true; this.renderPage(); return; }
    const generation = this.page.generation, personId = this.page.personId, preview = this.selectedPreview;
    try {
      const fresh = new PeopleState.PersonPage(), token = fresh.open(personId, "suggestions");
      const reply = await this.ask(fresh.request());
      if (generation !== this.page.generation || !this.visible) return;
      if (reply.ok === false) throw new Error(reply.error);
      fresh.merge(reply, token);
      if (this.backgroundPolicy() !== "refresh" || preview && !fresh.hits.some((face) => this.faceRowKey(face) === preview)) {
        this.backgroundNotice = true; this.backgroundProtected = true; this.renderPage(); return;
      }
      fresh.generation = generation + 1; this.page = fresh; this.selectedPreview = preview || (fresh.hits.length ? this.faceRowKey(fresh.hits[0]) : null);
      this.peopleRevision = reply.people_revision; this.backgroundNotice = false; this.backgroundProtected = false; this.renderPage();
    } catch {
      if (generation === this.page.generation) { this.backgroundNotice = true; this.backgroundProtected = true; this.renderPage(); }
    }
  }
  debug() { return { visible: this.visible, people: this.people, personId: this.page.personId, mode: this.page.mode, hits: this.page.hits, total: this.page.total,
    hasMore: this.page.hasMore, indexRevision: this.page.indexRevision, peopleRevision: this.peopleRevision, error: this.mutationError || this.directoryError || this.pageError,
    notice: this.notice, lastMutation: this.lastMutation, undo: this.undoOperation, faceLabel: this.faceLabel, bulkAll: this.faceBulk.all, bulkSelected: [...this.faceBulk.selected], bulkExcluded: [...this.faceBulk.excluded] }; }
}
if (typeof module !== "undefined") module.exports = PeopleView;
