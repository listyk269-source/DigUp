"use strict";

// Face identity is a versioned observation, never a name or a whole-file average.
const FaceState = (() => {
  const mediaKinds = new Set(["image", "screenshot", "video"]);
  const faceKey = (face) => String(face.id ?? face.face_id);
  function boxOf(face) {
    const box = face.bbox;
    if (!Array.isArray(box) || box.length !== 4 || !box.every(Number.isFinite)) return null;
    const [x, y, width, height] = box;
    if (width <= 0 || height <= 0 || x < 0 || y < 0 || x >= 1 || y >= 1) return null;
    return [x, y, Math.min(width, 1 - x), Math.min(height, 1 - y)];
  }
  class Selection {
    constructor() { this.generation = 0; this.clear(); }
    clear() { this.generation++; this.seed = null; this.hits = []; this.total = 0; this.offset = 0; this.hasMore = false; this.indexRevision = null; }
    select(face) { this.clear(); this.seed = face; return this.generation; }
    merge(reply, generation, { replace = false } = {}) {
      if (generation !== this.generation || !this.seed) return false;
      if (reply.seed && faceKey(reply.seed) !== faceKey(this.seed)) throw new Error("The selected face changed. Select it again.");
      if (reply.seed?.model_id && this.seed.model_id && reply.seed.model_id !== this.seed.model_id) throw new Error("The face model changed. Reindex faces and select again.");
      if (!replace && this.indexRevision !== null && reply.index_revision !== this.indexRevision) throw new Error("Face index changed. Run the face search again.");
      if (replace) { this.hits = []; this.offset = 0; }
      this.indexRevision = Number.isSafeInteger(reply.index_revision) ? reply.index_revision : null;
      const known = new Set(this.hits.map(faceKey));
      for (const hit of reply.hits || []) {
        if (known.has(faceKey(hit)) || !Number.isFinite(hit.cosine) || !boxOf(hit)) continue;
        known.add(faceKey(hit)); this.hits.push(hit);
      }
      const next = Number(reply.next_offset);
      // A broken/expired cursor cannot spin forever or create uncontrolled duplicates.
      this.hasMore = !!reply.has_more && Number.isSafeInteger(next) && next > this.offset;
      this.offset = Number.isSafeInteger(next) ? next : this.offset;
      this.total = Math.max(this.hits.length, Number(reply.total) || 0);
      return true;
    }
  }
  function graphReply(seed, page) {
    const best = new Map();
    for (const hit of page.hits || []) if (hit.path !== seed.path && (!best.has(hit.path) || hit.cosine > best.get(hit.path).cosine)) best.set(hit.path, hit);
    return { seed: { ...seed, face_id: seed.id ?? seed.face_id }, hits: [...best.values()].map((hit) => ({ ...hit,
      match_types: ["face"], match_evidence: [{ type: "face", cosine: hit.cosine, seed_loc: seed.loc, loc: hit.loc,
        seed_face_id: seed.id ?? seed.face_id, face_id: hit.face_id, seed_bbox: seed.bbox, bbox: hit.bbox }] })),
      vector_source: `faces:${seed.model_id}`, basis: "selected_face", total: page.total, has_more: page.has_more, next_offset: page.next_offset, index_revision: page.index_revision };
  }
  return { Selection, boxOf, faceKey, graphReply, isMedia: (hit) => mediaKinds.has(hit?.kind) };
})();
if (typeof module !== "undefined") module.exports = FaceState;
