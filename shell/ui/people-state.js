"use strict";

// A bulk selection refers to a fixed face-query snapshot. "All" is server-side,
// so its meaning never shrinks to the rows that happen to be loaded in the UI.
const PeopleState = (() => {
  const idOf = (face) => String(face.face_id ?? face.id);
  const fileKey = (file) => JSON.stringify([file.path, file.size, file.modified]);
  const galleryOptions = (value) => ({
    sort: ["date_desc", "date_asc"].includes(value?.sort) ? value.sort : "date_desc",
    media: ["all", "photo", "video"].includes(value?.media) ? value.media : "all",
  });
  const viewerTarget = (page, index, delta) => {
    const target = index + delta;
    return { index: target >= 0 && target < page.hits.length ? target : index,
      loadMore: delta > 0 && target >= page.hits.length && page.hasMore };
  };
  const samePerson = (left, right) => left != null && right != null && String(left) === String(right);
  const queryKey = (query) => JSON.stringify([query.seed_face_id, query.minimum_cosine, query.index_revision]);
  const revisionKey = (snapshot) => snapshot ? JSON.stringify([snapshot.scope_revision ?? null, snapshot.index_revision ?? null, snapshot.people_revision ?? null, snapshot.minimum_cosine ?? .5]) : null;
  // Only visible/nearby thumbnails enter this queue. Cancelling an old album discards its waiting work while
  // already running requests finish normally and remain reusable in the native preview cache.
  class ThumbnailQueue {
    constructor(limit = 2) { this.limit = limit; this.running = 0; this.waiting = []; this.generation = 0; }
    reset() { this.generation++; for (const task of this.waiting.splice(0)) task.resolve(null); }
    add(load) {
      const generation = this.generation;
      return new Promise((resolve, reject) => { this.waiting.push({ load, resolve, reject, generation }); this.pump(); });
    }
    pump() {
      while (this.running < this.limit && this.waiting.length) {
        const task = this.waiting.shift();
        if (task.generation !== this.generation) { task.resolve(null); continue; }
        this.running++;
        Promise.resolve().then(task.load).then(task.resolve, task.reject).finally(() => { this.running--; this.pump(); });
      }
    }
  }
  function backgroundRefreshPolicy({ visible, mode, checked = 0, editing = false, busy = false, previewTouched = false, playing = false, offset = 0 }) {
    if (!visible || mode !== "suggestions") return "none";
    return checked || editing || busy || previewTouched || playing || offset > 40 ? "hold" : "refresh";
  }
  class BulkSelection {
    constructor() { this.reset(null); }
    reset(query) { this.query = query; this.key = query ? queryKey(query) : null; this.all = false; this.selected = new Set(); this.excluded = new Set(); }
    sync(query) {
      const key = query ? queryKey(query) : null;
      if (key === this.key) return false;
      const changed = this.all || this.selected.size > 0; this.reset(query); return changed;
    }
    toggle(id, checked) {
      id = String(id);
      if (this.all) { if (checked) this.excluded.delete(id); else this.excluded.add(id); }
      else { if (checked) this.selected.add(id); else this.selected.delete(id); }
    }
    checked(id) { return this.all ? !this.excluded.has(String(id)) : this.selected.has(String(id)); }
    loaded(hits) { this.all = false; this.excluded.clear(); this.selected = new Set(hits.map(idOf)); }
    everything() { if (!this.query) return; this.all = true; this.selected.clear(); this.excluded.clear(); }
    clear() { this.all = false; this.selected.clear(); this.excluded.clear(); }
    count(total) { return this.all ? Math.max(0, total + 1 - this.excluded.size) : this.selected.size; }
    request(personId, action, peopleRevision) {
      if (!this.query || !this.count(0) && !this.all) throw new Error("Select face observations first.");
      const request = { op: "face_label", action, person_id: personId, index_revision: this.query.index_revision, people_revision: peopleRevision };
      if (this.all) return { ...request, ...this.query, include_seed: true, exclude_face_ids: [...this.excluded].map(Number) };
      return { ...request, face_ids: [...this.selected].map(Number) };
    }
  }
  class PersonPage {
    constructor() { this.generation = 0; this.open(null, "assigned"); }
    open(id, mode, options) { this.generation++; this.personId = id; this.mode = mode; this.gallery = galleryOptions(options); this.hits = []; this.offset = 0; this.total = 0; this.hasMore = false; this.indexRevision = null; this.peopleRevision = null; return this.generation; }
    merge(reply, generation) {
      if (generation !== this.generation || !samePerson(reply.person?.id, this.personId)) return false;
      if (this.mode === "gallery" && (reply.gallery_sort != null && reply.gallery_sort !== this.gallery.sort || reply.gallery_media != null && reply.gallery_media !== this.gallery.media)) throw new Error("Gallery filters changed. Refresh this gallery.");
      if (this.offset && (reply.index_revision !== this.indexRevision || reply.people_revision !== this.peopleRevision)) throw new Error("People or face index changed. Refresh this list.");
      const key = this.mode === "gallery" ? fileKey : (face) => face.anchor_key || idOf(face), known = new Set(this.hits.map(key));
      this.hits.push(...(reply.hits || []).filter((face) => !known.has(key(face)) && known.add(key(face))));
      this.indexRevision = reply.index_revision; this.peopleRevision = reply.people_revision;
      const next = Number(reply.next_offset); this.hasMore = !!reply.has_more && Number.isSafeInteger(next) && next > this.offset;
      this.offset = Number.isSafeInteger(next) ? next : this.offset; this.total = reply.total || 0; return true;
    }
    request(minimum = .5) { return { op: "person_faces", person_id: this.personId, mode: this.mode, offset: this.offset, limit: 40, minimum_cosine: minimum,
      ...(this.mode === "gallery" ? { gallery_sort: this.gallery.sort, gallery_media: this.gallery.media } : {}),
      ...(this.offset ? { index_revision: this.indexRevision, people_revision: this.peopleRevision } : {}) }; }
  }
  return { BulkSelection, PersonPage, ThumbnailQueue, idOf, fileKey, galleryOptions, viewerTarget, queryKey, samePerson, revisionKey, backgroundRefreshPolicy };
})();
if (typeof module !== "undefined") module.exports = PeopleState;
