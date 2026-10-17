"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const Period = require("../shell/ui/year-period.js");
test("year preferences preserve inclusive and open endpoints", () => {
  assert.deepEqual(Period.options({ fromYear: "2000", throughYear: 2003 }), { fromYear: 2000, throughYear: 2003 });
  assert.deepEqual(Period.options({ throughYear: 2003 }), { fromYear: null, throughYear: 2003 });
  assert.deepEqual(Period.options({ fromYear: 1, throughYear: 9999 }), { fromYear: 1, throughYear: 9999 });
});
test("corrupt persisted years cannot silently narrow ordinary search", () => {
  assert.deepEqual(Period.options({ fromYear: 2003, throughYear: 2000 }), { fromYear: null, throughYear: null });
  for (const bad of [true, false, [2000], {}, 0, 10000, 2000.5, "2000.5", "2000x", ""]) {
    assert.deepEqual(Period.options({ fromYear: bad }), { fromYear: null, throughYear: null });
  }
});
