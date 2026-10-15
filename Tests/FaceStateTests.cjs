"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const faces = require("../shell/ui/face-state.js");
const box = [.1, .2, .3, .4];
test("a late face query cannot replace a newly selected person or file", () => {
  const state = new faces.Selection();
  const old = state.select({ id: 1, model_id: "sface-v1" });
  state.select({ id: 2, model_id: "sface-v1" });
  assert.equal(state.merge({ seed: { id: 1 }, hits: [{ face_id: 3, bbox: box, cosine: .9 }] }, old), false);
  assert.equal(state.hits.length, 0);
  assert.equal(state.seed.id, 2);
  assert.throws(() => state.merge({ seed: { id: 2, model_id: "other" } }, state.generation), /model changed/);
});
test("face pagination retains distinct appearances in the same video and rejects duplicates", () => {
  const state = new faces.Selection(), seed = { id: 8, model_id: "sface-v1" }, generation = state.select(seed);
  const hit = { face_id: 9, path: "D:\\Фото\\Семья.mp4", kind: "video", loc: 2, bbox: box, cosine: .91 };
  state.merge({ seed, hits: [hit], total: 3, next_offset: 1, has_more: true }, generation);
  state.merge({ seed, hits: [hit, { ...hit, face_id: 10, loc: 6 }], total: 3, next_offset: 2, has_more: true }, generation);
  assert.equal(state.hits.length, 2);
  assert.deepEqual(state.hits.map((h) => h.loc), [2, 6]);
  state.merge({ seed, hits: [hit], total: 3, next_offset: 2, has_more: true }, generation);
  assert.equal(state.hasMore, false);
});
test("bounding boxes are normalized, finite and never extend outside the actual image", () => {
  assert.deepEqual(faces.boxOf({ bbox: [.8, .9, .5, .5] }), [.8, .9, 1 - .8, 1 - .9]);
  for (const bbox of [[0, 0, 0, .2], [-1, 0, .3, .3], [0, 0, NaN, .3], [1, .2, .3, .3]]) assert.equal(faces.boxOf({ bbox }), null);
});
test("backfill revision changes cannot mix pagination snapshots and replacement preserves the selected person", () => {
  const state = new faces.Selection(), seed = { id: 8, model_id: "sface-v1" }, generation = state.select(seed);
  const old = { face_id: 9, bbox: box, cosine: .9 }, fresh = { face_id: 10, bbox: box, cosine: .8 };
  state.merge({ seed, index_revision: 1, hits: [old], next_offset: 1, has_more: true }, generation);
  assert.throws(() => state.merge({ seed, index_revision: 2, hits: [fresh], next_offset: 2, has_more: false }, generation), /index changed/);
  assert.deepEqual(state.hits, [old]);
  assert.equal(state.indexRevision, 1);
  state.merge({ seed, index_revision: 2, hits: [fresh], next_offset: 1, has_more: false }, generation, { replace: true });
  assert.deepEqual(state.hits, [fresh]);
  assert.equal(state.indexRevision, 2);
  assert.equal(state.seed.id, 8);
});
test("face graph projects each best observation without averaging people or inventing metadata", () => {
  const seed = { id: 4, path: "Группа.jpg", kind: "image", bbox: box, model_id: "sface-v1", loc: null };
  const target = { path: "Встреча.mp4", face_id: 5, kind: "video", bbox: box, model_id: "sface-v1", loc: 12, cosine: .7 };
  const result = faces.graphReply(seed, { hits: [target, { ...target, face_id: 6, loc: 18, cosine: .9 }], total: 2 });
  assert.equal(result.hits.length, 1);
  assert.equal(result.hits[0].face_id, 6);
  assert.equal(result.hits[0].match_evidence[0].loc, 18);
  assert.equal(result.hits[0].match_evidence[0].seed_face_id, 4);
  assert.deepEqual(result.hits[0].match_types, ["face"]);
  assert.equal(result.vector_source, "faces:sface-v1");
});
