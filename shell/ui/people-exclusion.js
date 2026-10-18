"use strict";

// A review is tied to one person, one chosen face and two revisions. Applying it asks the helper to scan
// the complete snapshot again; DOM pagination never defines which observations are changed.
class PeopleExclusionReview {
  constructor(people) {
    this.people = people; this.el = people.el; this.generation = 0; this.faces = []; this.hits = [];
    const dialog = this.el("people-exclusion");
    this.el("people-exclusion-close").onclick = () => this.close();
    dialog.addEventListener("cancel", (event) => { event.preventDefault(); this.close(); });
    dialog.addEventListener("keydown", (event) => event.stopPropagation());
    dialog.addEventListener("close", () => { if (!dialog.open) { this.generation++; this.active = false; } });
    this.el("people-exclusion-minimum").onchange = () => {
      this.minimum = Number(this.el("people-exclusion-minimum").value); this.task = this.matches();
    };
    this.el("people-exclusion-more").onclick = () => { this.task = this.matches(true); };
    this.el("people-exclusion-faces-more").onclick = () => { this.task = this.loadFaces(true); };
    this.el("people-exclusion-refresh").onclick = () => { this.task = this.open(this.source); };
    this.el("people-exclusion-apply").onclick = () => { this.task = this.apply(); };
    document.addEventListener("ui-language-changed", () => { if (this.active) this.render(); });
  }
  async open(source) {
    if (this.people.mutationBusy) return;
    this.people.closeViewer();
    this.source = source; this.personId = this.people.page.personId; this.personName = this.people.person()?.name || "";
    this.faces = []; this.hits = []; this.seed = null; this.reply = null; this.error = null; this.facesMore = false;
    this.minimum = .5; this.active = true; this.busy = true; const generation = ++this.generation;
    if (!this.el("people-exclusion").open) this.el("people-exclusion").showModal();
    this.el("people-exclusion-minimum").value = String(this.minimum); this.render(); this.el("people-exclusion-close").focus();
    await this.people.refreshDirectory();
    if (!this.active || generation !== this.generation) return;
    this.peopleRevision = this.people.peopleRevision;
    await this.loadFaces();
  }
  close() {
    if (!this.active && !this.el("people-exclusion").open) return;
    if (this.people.mutationBusy) return;
    this.active = false; this.generation++;
    if (this.el("people-exclusion").open) this.el("people-exclusion").close();
    (this.el("person-faces").querySelector("button") || this.el("people-refresh")).focus({ preventScroll: true });
  }
  async loadFaces(more = false) {
    const generation = this.generation; this.busy = true; this.error = null; this.render();
    try {
      const reply = await this.people.ask({ op: "face_file", path: this.source.path, offset: more ? this.faceOffset : 0, limit: 60 });
      if (!this.active || generation !== this.generation) return;
      if (reply.ok === false || reply.stale || !reply.indexed || (more && reply.index_revision !== this.indexRevision)) throw new Error(reply.error || "This face changed or is outside the selected folders. Choose it again.");
      this.indexRevision = reply.index_revision;
      if (!more) this.peopleRevision = reply.people_revision;
      const known = new Set(this.faces.map(PeopleState.idOf));
      this.faces.push(...(reply.faces || []).filter((face) => !known.has(PeopleState.idOf(face)) && known.add(PeopleState.idOf(face))).map((face) => ({ ...this.source, ...face })));
      this.faceOffset = reply.next_offset; this.facesMore = !!reply.has_more;
    } catch (error) { if (generation === this.generation) this.error = String(error.message || error); }
    finally { if (generation === this.generation) { this.busy = false; this.render(); } }
  }
  async choose(face) { this.seed = face; return this.matches(); }
  request(op) {
    return { op, person_id: this.personId, face_id: Number(PeopleState.idOf(this.seed)), minimum_cosine: this.minimum,
      index_revision: this.indexRevision, people_revision: this.peopleRevision };
  }
  async matches(more = false) {
    if (!this.seed || !this.active) return;
    const generation = ++this.generation; this.busy = true; this.error = null;
    if (!more) { this.hits = []; this.reply = null; }
    this.render();
    try {
      const reply = await this.people.ask({ ...this.request("person_exclusion_preview"), offset: more ? this.reply.next_offset : 0, limit: 40 });
      if (!this.active || generation !== this.generation) return;
      if (reply.ok === false) throw new Error(reply.error);
      const known = new Set(this.hits.map(PeopleState.fileKey));
      this.hits.push(...reply.hits.filter((hit) => !known.has(PeopleState.fileKey(hit)) && known.add(PeopleState.fileKey(hit))));
      this.reply = reply;
    } catch (error) { if (generation === this.generation) this.error = String(error.message || error); }
    finally { if (generation === this.generation) { this.busy = false; this.render(); } }
  }
  async apply() {
    if (!this.active || this.busy || this.error || !this.reply || (!this.reply.total && this.reply.persistent_rule_exists) || this.people.mutationBusy) return;
    const task = this.people.mutate(this.request("person_exclude_similar"), t("Similar faces excluded. Person references updated."));
    this.render();
    const reply = await task;
    if (reply) this.close(); else { this.error = this.people.mutationError; this.render(); }
  }
  render() {
    if (!this.active) return;
    const p = this.people, busy = this.busy || p.mutationBusy;
    this.el("people-exclusion-title").textContent = t("Exclude similar faces from {person}", { person: this.personName });
    const choices = this.el("people-exclusion-faces"); choices.replaceChildren();
    for (const [index, face] of this.faces.entries()) {
      const button = p.text("button", "face-choice"); button.type = "button"; button.disabled = busy;
      button.dataset.faceId = PeopleState.idOf(face); button.setAttribute("aria-pressed", String(PeopleState.idOf(face) === PeopleState.idOf(this.seed || {})));
      const label = face.kind === "video" ? `${p.clock(face.loc ?? 0)} · ${index + 1}` : t("Face {number}", { number: index + 1 });
      button.setAttribute("aria-label", label); button.append(p.faceSearch.crop(face), p.text("span", "", label));
      button.onclick = () => { this.task = this.choose(face); }; choices.append(button);
    }
    const message = this.el("people-exclusion-message"); message.classList.toggle("face-error", !!this.error);
    message.textContent = this.error ? t(this.error) : p.mutationBusy ? t("Updating person references…") : this.busy ? t("Comparing face observations locally…") :
      !this.seed ? t("Choose the incorrect face below. Only matches to this face will be excluded.") :
        t("{files} files · {observations} face observations to exclude", { files: this.reply?.total || 0, observations: this.reply?.observation_count || 0 });
    const list = this.el("people-exclusion-results"); list.setAttribute("aria-busy", String(busy)); list.replaceChildren();
    for (const hit of this.hits) {
      const row = p.text("div", "people-exclusion-result"), label = p.text("span", "face-result-text");
      label.append(p.text("strong", "", p.nameOf(hit.path)), p.text("span", "", t("Cosine {value}", { value: hit.cosine.toFixed(3) }) +
        (hit.kind === "video" ? ` · ${p.clock(hit.loc ?? 0)}` : "")));
      row.append(p.faceSearch.crop(hit), label); list.append(row);
    }
    this.el("people-exclusion-apply").disabled = busy || !!this.error || !this.reply || (!this.reply.total && this.reply.persistent_rule_exists);
    this.el("people-exclusion-apply").textContent = this.reply && !this.reply.total ? t(this.reply.persistent_rule_exists ? "Exclusion rule is already saved" : "Do not suggest similar faces again") : t("Exclude and remember in {count} files", { count: this.reply?.total || 0 });
    this.el("people-exclusion-close").disabled = !!p.mutationBusy;
    this.el("people-exclusion-refresh").disabled = busy;
    this.el("people-exclusion-minimum").disabled = busy || !this.seed;
    this.el("people-exclusion-more").hidden = !this.reply?.has_more; this.el("people-exclusion-more").disabled = busy || !!this.error;
    this.el("people-exclusion-faces-more").hidden = !this.facesMore; this.el("people-exclusion-faces-more").disabled = busy || !!this.error;
  }
}
if (typeof module !== "undefined") module.exports = PeopleExclusionReview;
