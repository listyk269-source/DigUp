"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const state = require("../shell/ui/people-state.js");
const query = { seed_face_id: 7, minimum_cosine: .5, index_revision: 12 };

test("file gallery deduplicates repeated face/frame observations across pages without normalizing paths", () => {
  const page = new state.PersonPage(), generation = page.open("person", "gallery");
  const first = { face_id: 1, path: "D:/Фото с пробелом/😀 café.jpg", modified: 1, size: 42 };
  const reply = { person: { id: "person" }, index_revision: 1, people_revision: 2, total: 3 };
  page.merge({ ...reply, hits: [first, { ...first, face_id: 2 }], next_offset: 1, has_more: true }, generation);
  assert.equal(page.hits.length, 1); assert.equal(page.request().mode, "gallery");
  page.merge({ ...reply, hits: [{ ...first, face_id: 3 }, { ...first, face_id: 4, path: "D:/Фото с пробелом/😀 cafe\u0301.jpg" },
    { ...first, face_id: 5, path: "D:/Фото с пробелом/video.mp4" }], next_offset: 3 }, generation);
  assert.equal(page.hits.length, 3); assert.equal(page.hasMore, false);
  assert.notEqual(state.fileKey(first), state.fileKey({ ...first, modified: 2 }));
});

test("gallery arrows stop at boundaries and request a page only at the unloaded boundary", () => {
  const page = { hits: [{}, {}], hasMore: true };
  assert.deepEqual(state.viewerTarget(page, 0, -1), { index: 0, loadMore: false });
  assert.deepEqual(state.viewerTarget(page, 0, 1), { index: 1, loadMore: false });
  assert.deepEqual(state.viewerTarget(page, 1, 1), { index: 1, loadMore: true });
  assert.deepEqual(state.viewerTarget({ ...page, hasMore: false }, 1, 1), { index: 1, loadMore: false });
});

test("a delayed gallery page cannot change a viewer closed or switched to another person", async () => {
  const { readFileSync } = require("node:fs"), vm = require("node:vm"), path = require("node:path");
  const context = { module: { exports: {} }, PeopleState: state };
  vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people.js"), "utf8"), context);
  for (const changed of ["closed", "person"]) {
    const view = Object.create(context.module.exports.prototype), dialog = { open: true };
    view.el = () => dialog; view.renderViewer = () => {};
    view.page = { hits: [{}], hasMore: true, generation: 1 }; view.viewerIndex = 0;
    let finish; view.loadPage = () => new Promise((resolve) => { finish = resolve; });
    const task = view.moveViewer(1);
    if (changed === "closed") { dialog.open = false; view.viewerIndex = -1; } else { view.page.generation++; }
    view.page.hits.push({}); finish(); await task;
    assert.equal(view.viewerIndex, changed === "closed" ? -1 : 0); assert.equal(view.viewerBusy, false);
  }
});

test("album thumbnails bound work and discard waiting loads when switching people", async () => {
  const queue = new state.ThumbnailQueue(2), finish = []; let active = 0, peak = 0, calls = 0;
  const load = () => { calls++; active++; peak = Math.max(peak, active); return new Promise((resolve) => finish.push(() => { active--; resolve("image"); })); };
  const tasks = Array.from({ length: 40 }, () => queue.add(load));
  await new Promise(setImmediate); assert.equal(calls, 2); assert.equal(peak, 2);
  queue.reset(); finish.splice(0).forEach((done) => done());
  const replies = await Promise.all(tasks); assert.equal(replies.filter((value) => value === null).length, 38);
  assert.equal(calls, 2);
  assert.equal(await queue.add(() => "next person"), "next person");
});

test("failed thumbnail decoding releases a queue slot for the next photograph", async () => {
  const queue = new state.ThumbnailQueue(1);
  const first = queue.add(() => { throw new Error("bad image"); }), next = queue.add(() => "next image");
  await assert.rejects(first, /bad image/); assert.equal(await next, "next image");
});

test("scroll near the album end loads later pages and stops on expiration or errors", async () => {
  const { readFileSync } = require("node:fs"), vm = require("node:vm"), path = require("node:path");
  const context = { module: { exports: {} }, PeopleState: state };
  vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people.js"), "utf8"), context);
  const view = Object.create(context.module.exports.prototype);
  view.visible = true; view.page = { hasMore: true }; view.el = () => ({ scrollHeight: 2000, clientHeight: 500, scrollTop: 1450 });
  let requests = 0; view.loadPage = async (more) => { assert.equal(more, true); requests++; };
  view.maybeLoadMore(); await view.pageTask; assert.equal(requests, 1);
  for (const protection of ["pageBusy", "mutationBusy", "expired", "pageError"]) {
    view[protection] = true; view.maybeLoadMore(); assert.equal(requests, 1); view[protection] = false;
  }
  view.page.hasMore = false; view.maybeLoadMore(); assert.equal(requests, 1);
});
test("background refresh preserves explicit checks, active previews, rename edits and extra pages", () => {
  const idle = { visible: true, mode: "suggestions", offset: 40 };
  assert.equal(state.backgroundRefreshPolicy(idle), "refresh");
  for (const protection of [{ checked: 1 }, { editing: true }, { busy: true }, { previewTouched: true }, { playing: true }, { offset: 80 }]) {
    assert.equal(state.backgroundRefreshPolicy({ ...idle, ...protection }), "hold");
  }
  assert.equal(state.backgroundRefreshPolicy({ ...idle, visible: false }), "none");
  assert.equal(state.backgroundRefreshPolicy({ ...idle, mode: "assigned" }), "none");
  assert.notEqual(state.revisionKey({ index_revision: 2, people_revision: 1, scope_revision: 1 }), state.revisionKey({ index_revision: 2, people_revision: 1, scope_revision: 2 }));
});
test("a background result arriving after the user checks a face cannot replace the review page", async () => {
  const { readFileSync } = require("node:fs"), vm = require("node:vm"), path = require("node:path");
  const context = { module: { exports: {} }, PeopleState: state, t: (key) => key, document: { activeElement: null } };
  vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people.js"), "utf8"), context);
  const view = Object.create(context.module.exports.prototype), id = "D8422F9A-5361-467B-81F8-EE9DD7FD65C1";
  const page = new state.PersonPage(); page.open(id, "suggestions"); page.indexRevision = 1; page.peopleRevision = 2;
  const oldHit = { face_id: 7, anchor_key: "same-observation" }; page.hits = [oldHit];
  view.page = page; view.visible = true; view.selectedFaces = new Set(); view.selectedPreview = "same-observation";
  view.renderStatus = view.renderDirectory = view.renderPage = () => {};
  view.el = (key) => key === "person-rename" ? { hidden: true } : { querySelectorAll: () => [] };
  let complete;
  view.ask = () => new Promise((resolve) => { complete = resolve; });
  const task = view.backgroundSummary({ state: "ready", index_revision: 2, people_revision: 2, scope_revision: 1 });
  view.selectedFaces.add("same-observation");
  complete({ ok: true, person: { id }, hits: [{ face_id: 8, anchor_key: "new" }], index_revision: 2, people_revision: 2, total: 1, next_offset: 1 });
  await task;
  assert.equal(view.page, page);
  assert.deepEqual(view.page.hits, [oldHit]);
  assert.equal(view.selectedFaces.has("same-observation"), true);
  assert.equal(view.backgroundNotice, true);
});
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
