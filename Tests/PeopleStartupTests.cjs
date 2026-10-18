"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict");
const vm = require("node:vm"), { readFileSync } = require("node:fs"), path = require("node:path");
const state = require("../shell/ui/people-state.js");
const context = { module: { exports: {} }, PeopleState: state };
vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people.js"), "utf8"), context);
function view(ask) {
  const result = Object.create(context.module.exports.prototype);
  Object.assign(result, { ask, directoryGeneration: 0, people: [], page: { personId: null }, renderDirectory() {}, renderFaceControls() {}, renderStatus() {} });
  return result;
}
const reply = (name = "Человек") => ({ ok: true, people: [{ id: "person", name, assigned_file_count: 43 }], people_revision: 4, index_revision: 7 });

test("startup and an immediate People opening share one metadata request; cached names remain available", async () => {
  let finish, calls = 0;
  const people = view((request) => { assert.equal(request.op, "people_list"); calls++; return new Promise((resolve) => { finish = resolve; }); });
  const startup = people.preload(), opening = people.refreshDirectory({ force: false });
  assert.equal(calls, 1); assert.equal(people.directoryBusy, true);
  finish(reply()); assert.equal(await startup, true); await opening;
  assert.equal(people.directoryLoaded, true); assert.equal(people.directoryBusy, false);
  assert.equal(people.startupDirectory.people[0].files, 43);
  await people.preload(); await people.refreshDirectory({ force: false }); assert.equal(calls, 1);
});
test("folder invalidation prevents an old startup response from repopulating the new selection", async () => {
  const pending = [], people = view(() => new Promise((resolve) => pending.push(resolve)));
  const old = people.preload(); people.invalidateDirectory();
  const current = people.refreshDirectory({ force: false });
  pending[1](reply("Новый")); await current; pending[0](reply("Старый")); await old;
  assert.equal(people.people[0].name, "Новый"); assert.equal(people.directoryLoaded, true); assert.equal(people.directoryBusy, false);
});
test("a failed preload is recoverable and never leaves People permanently busy", async () => {
  let calls = 0;
  const people = view(async () => { if (++calls === 1) throw new Error("temporarily unavailable"); return reply(); });
  assert.equal(await people.preload(), false); assert.equal(people.directoryBusy, false); assert.equal(people.directoryLoaded, false);
  assert.equal(await people.refreshDirectory({ force: false }), true);
  assert.equal(people.directoryError, null); assert.equal(people.people.length, 1);
});
test("opening a warm directory starts the album before background metadata validation completes", async () => {
  const people = view(); let album = 0, validations = 0;
  Object.assign(people, { directoryLoaded: true, people: reply().people, onVisibility() {}, render() {},
    selectPerson: async (id, mode) => { assert.equal(id, "person"); assert.equal(mode, "gallery"); album++; },
    refreshDirectory: () => { validations++; return new Promise(() => {}); } });
  await people.open(); assert.equal(album, 1); assert.equal(validations, 1); assert.equal(people.visible, true);
});
test("startup retries one real IPC revision rejection and bounds retries during continuous publication", async () => {
  let calls = 0;
  const error = "People or face index changed. Refresh before continuing.";
  const people = view(async () => { if (++calls === 1) throw new Error(error); return reply(); });
  assert.equal(await people.preload(), true); assert.equal(calls, 2);
  calls = 0;
  const publishing = view(async () => { calls++; throw new Error(error); });
  assert.equal(await publishing.preload(), false); assert.equal(calls, 2); assert.equal(publishing.directoryBusy, false);
});
