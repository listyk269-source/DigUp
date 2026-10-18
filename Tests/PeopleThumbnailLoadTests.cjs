"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict"), vm = require("node:vm");
const { readFileSync } = require("node:fs"), path = require("node:path");
const context = { module: { exports: {} } };
vm.runInNewContext(readFileSync(path.join(__dirname, "../shell/ui/people.js"), "utf8"), context);
const node = (top, connected = true) => ({ isConnected: connected, dataset: {}, getBoundingClientRect: () => ({ top, bottom: top + 48, height: 48 }) });
test("visible directory and gallery previews queue without hover and each is requested once", () => {
  const view = Object.create(context.module.exports.prototype), queued = [], root = { getBoundingClientRect: () => ({ top: 100, bottom: 500, height: 400, width: 230 }) };
  const cover = node(110), tile = node(440), outside = node(900), removed = node(120, false);
  const queue = { add: (load) => { queued.push(load); return Promise.resolve(); } }, first = () => {}, second = () => {};
  Object.assign(view, { visible: true, directoryLoads: new Map([[cover, first], [outside, () => {}], [removed, () => {}]]),
    thumbnailLoads: new Map([[tile, second]]), directoryThumbnails: queue, thumbnails: queue, el: () => root, thumbnailObserver: { unobserve() {} } });
  view.flushVisibleThumbnails(); view.flushVisibleThumbnails();
  assert.deepEqual(queued, [first, second]); assert.equal(cover.dataset.requested, "true"); assert.equal(view.directoryLoads.size, 1);
  assert.equal(view.directoryLoads.has(outside), true); assert.equal(view.directoryLoads.has(removed), false);
});
test("hidden People and zero-sized roots defer decoding until a real visible layout exists", () => {
  const view = Object.create(context.module.exports.prototype), cover = node(0); let calls = 0;
  Object.assign(view, { visible: false, directoryLoads: new Map([[cover, () => {}]]), thumbnailLoads: new Map(),
    el: () => ({ getBoundingClientRect: () => ({ width: 0, height: 0 }) }), directoryThumbnails: { add() { calls++; } } });
  view.flushVisibleThumbnails(); view.visible = true; view.flushVisibleThumbnails(); assert.equal(calls, 0);
});
