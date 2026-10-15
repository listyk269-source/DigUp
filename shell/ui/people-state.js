"use strict";

// A bulk selection refers to a fixed face-query snapshot. "All" is server-side,
// so its meaning never shrinks to the rows that happen to be loaded in the UI.
const PeopleState = (() => {
  const idOf = (face) => String(face.face_id ?? face.id);
  const samePerson = (left, right) => left != null && right != null && String(left) === String(right);
  const queryKey = (query) => JSON.stringify([query.seed_face_id, query.minimum_cosine, query.index_revision]);
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
    open(id, mode) { this.generation++; this.personId = id; this.mode = mode; this.hits = []; this.offset = 0; this.total = 0; this.hasMore = false; this.indexRevision = null; this.peopleRevision = null; return this.generation; }
    merge(reply, generation) {
      if (generation !== this.generation || !samePerson(reply.person?.id, this.personId)) return false;
      if (this.offset && (reply.index_revision !== this.indexRevision || reply.people_revision !== this.peopleRevision)) throw new Error("People or face index changed. Refresh this list.");
      const key = (face) => face.anchor_key || idOf(face), known = new Set(this.hits.map(key));
      this.hits.push(...(reply.hits || []).filter((face) => !known.has(key(face)) && known.add(key(face))));
      this.indexRevision = reply.index_revision; this.peopleRevision = reply.people_revision;
      const next = Number(reply.next_offset); this.hasMore = !!reply.has_more && Number.isSafeInteger(next) && next > this.offset;
      this.offset = Number.isSafeInteger(next) ? next : this.offset; this.total = reply.total || 0; return true;
    }
    request(minimum = .5) { return { op: "person_faces", person_id: this.personId, mode: this.mode, offset: this.offset, limit: 40, minimum_cosine: minimum,
      ...(this.offset ? { index_revision: this.indexRevision, people_revision: this.peopleRevision } : {}) }; }
  }
  return { BulkSelection, PersonPage, idOf, queryKey, samePerson };
})();
if (typeof module !== "undefined") module.exports = PeopleState;
