"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict"), vm = require("node:vm");
const { readFileSync } = require("node:fs"), path = require("node:path");
const PeopleState = require("../shell/ui/people-state.js");
const context = { module: { exports: {} }, PeopleState, t: (s) => s };
vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people-exclusion.js"), "utf8"), context);
function review(ask) {
  const view = Object.create(context.module.exports.prototype);
  Object.assign(view, { active: true, generation: 1, personId: "person", peopleRevision: 4, indexRevision: 7,
    minimum: .5, seed: { face_id: 10 }, hits: [], people: { ask }, render() {} });
  return view;
}
const reply = { ok: true, hits: [{ face_id: 20, path: "D:\\Фото\\Ё.jpg", modified: 1, size: 100 }], total: 100, observation_count: 170, next_offset: 40, has_more: true };
test("a late preview cannot replace a newer chosen face", async () => {
  const pending = [], view = review(() => new Promise((resolve) => pending.push(resolve)));
  const old = view.matches(); view.seed = { face_id: 11 }; const current = view.matches();
  pending[1]({ ...reply, hits: [{ ...reply.hits[0], face_id: 30 }] }); await current;
  pending[0](reply); await old;
  assert.equal(view.hits[0].face_id, 30); assert.equal(view.busy, false);
});
test("a closed review ignores its outstanding query", async () => {
  let finish; const view = review(() => new Promise((resolve) => { finish = resolve; }));
  const pending = view.matches(); view.active = false; view.generation++;
  finish(reply); await pending; assert.equal(view.hits.length, 0); assert.equal(view.reply, null);
});
test("bulk apply sends the seed, threshold and reviewed revisions regardless of loaded rows", async () => {
  const view = review(), requests = []; let closed = false;
  view.reply = reply; view.hits = reply.hits;
  view.people.mutate = async (request) => { requests.push(JSON.parse(JSON.stringify(request))); return { ok: true }; };
  view.close = () => { closed = true; };
  await view.apply(); assert.equal(closed, true);
  assert.deepEqual(requests, [{ op: "person_exclude_similar", person_id: "person", face_id: 10,
    minimum_cosine: .5, index_revision: 7, people_revision: 4 }]);
});
test("a failed or unfinished review cannot apply a previous successful result", async () => {
  const view = review(async () => { throw new Error("People changed. Refresh before applying this action."); });
  view.reply = reply; let mutations = 0; view.people.mutate = async () => { mutations++; };
  await view.matches(); assert.match(view.error, /People changed/); assert.equal(view.busy, false);
  await view.apply(); assert.equal(mutations, 0);
  view.error = null; view.reply = reply; view.busy = true; await view.apply(); assert.equal(mutations, 0);
});
