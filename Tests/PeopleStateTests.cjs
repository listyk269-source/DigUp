"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const state = require("../shell/ui/people-state.js");
const query = { seed_face_id: 7, minimum_cosine: .5, index_revision: 12 };
test("opaque person UUIDs remain exact in selected-face assignment and person paging", async () => {
  const { readFileSync } = require("node:fs"), vm = require("node:vm"), path = require("node:path");
  const context = { module: { exports: {} }, PeopleState: state, t: (key) => key };
  vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people.js"), "utf8"), context);
  const view = Object.create(context.module.exports.prototype), id = "D8422F9A-5361-467B-81F8-EE9DD7FD65C1";
  let sent;
  view.faceTarget = id; view.peopleRevision = 1; view.faceSearch = { selection: { seed: { id: 7 }, indexRevision: 12 } };
  view.mutate = async (request) => { sent = JSON.parse(JSON.stringify(request)); return {}; };
  await view.assignSeed();
  assert.equal(sent.person_id, id);
  assert.deepEqual(sent.face_ids, [7]);
  const page = new state.PersonPage(), generation = page.open(id, "assigned");
  assert.equal(page.request().person_id, id);
  assert.equal(page.merge({ person: { id }, hits: [], index_revision: 12, people_revision: 1 }, generation), true);
  assert.equal(state.samePerson(id, "E8422F9A-5361-467B-81F8-EE9DD7FD65C1"), false);
});
test("an empty person tab clears a previous preview even after its cache key was invalidated", () => {
  const { readFileSync } = require("node:fs"), vm = require("node:vm"), path = require("node:path");
  const context = { module: { exports: {} }, PeopleState: state, t: (key) => key };
  vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people.js"), "utf8"), context);
  const view = Object.create(context.module.exports.prototype), host = { children: ["previous crew photograph"], replaceChildren(...children) { this.children = children; } };
  let stopped = 0;
  view.page = { hits: [], mode: "suggestions" }; view.selectedPreview = null; view.previewKey = null;
  view.el = () => host; view.stopPreview = () => { stopped++; }; view.text = (_tag, _class, text) => ({ text });
  view.renderPreview();
  assert.equal(stopped, 1);
  assert.deepEqual(host.children, [{ text: "No observation selected" }]);
});
test("all-matches assignment covers unloaded pages, source and explicit exclusions", () => {
  const bulk = new state.BulkSelection(); bulk.sync(query); bulk.everything(); bulk.toggle(20, false);
  assert.equal(bulk.count(104), 104);
  assert.equal(bulk.checked(900), true);
  assert.equal(bulk.checked(20), false);
  assert.deepEqual(bulk.request(2, "assign", 3), { op: "face_label", action: "assign", person_id: 2, ...query, people_revision: 3, include_seed: true, exclude_face_ids: [20] });
});
test("selected rows do not implicitly label the source or unloaded observations", () => {
  const bulk = new state.BulkSelection(); bulk.sync(query); bulk.loaded([{ face_id: 10 }, { face_id: 11 }]); bulk.toggle(10, false);
  assert.deepEqual(bulk.request(2, "reject", 3).face_ids, [11]);
  assert.equal(bulk.request(2, "reject", 3).include_seed, undefined);
  assert.equal(bulk.checked(90), false);
});
test("query threshold, seed or backfill revision changes invalidate bulk selection", () => {
  for (const change of [{ seed_face_id: 8 }, { minimum_cosine: .65 }, { index_revision: 13 }]) {
    const bulk = new state.BulkSelection(); bulk.sync(query); bulk.everything();
    assert.equal(bulk.sync({ ...query, ...change }), true);
    assert.equal(bulk.all, false); assert.equal(bulk.selected.size, 0); assert.equal(bulk.excluded.size, 0);
  }
});
test("a late person or tab response cannot replace the current page", () => {
  const page = new state.PersonPage(), old = page.open(1, "assigned"); page.open(2, "suggestions");
  assert.equal(page.merge({ person: { id: 1 }, hits: [{ face_id: 1 }] }, old), false);
  assert.equal(page.hits.length, 0);
});
test("person paging binds both revisions, deduplicates anchors and retains rows on expiration", () => {
  const page = new state.PersonPage(), generation = page.open(2, "assigned"), hit = { face_id: 4, anchor_key: "original" };
  page.merge({ person: { id: 2 }, hits: [hit], index_revision: 12, people_revision: 4, next_offset: 1, total: 2, has_more: true }, generation);
  assert.deepEqual(page.request().people_revision, 4);
  assert.throws(() => page.merge({ person: { id: 2 }, hits: [], index_revision: 13, people_revision: 4 }, generation), /changed/);
  assert.deepEqual(page.hits, [hit]);
  page.merge({ person: { id: 2 }, hits: [hit, { face_id: 8, anchor_key: "next" }], index_revision: 12, people_revision: 4, next_offset: 2, total: 2, has_more: false }, generation);
  assert.equal(page.hits.length, 2);
});
