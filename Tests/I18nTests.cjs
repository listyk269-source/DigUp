"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const i18n = require("../shell/ui/i18n.js");
const ui = path.join(__dirname, "../shell/ui");
test("every Russian message retains exactly the English substitution parameters", () => {
  const fields = (s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
  for (const [english, russian] of Object.entries(i18n.catalog)) {
    assert.ok(russian.trim(), english);
    assert.deepEqual(fields(russian), fields(english), english);
  }
});
test("language switch retains document names, queries and literal replacement characters", () => {
  const name = 'Поиск $& {files} <script>untrusted</script> dog 🐕';
  i18n.set("ru");
  assert.equal(i18n.t("Similar to {name}", { name }), `Похожие на «${name}»`);
  assert.equal(i18n.t("{count} results", { count: 21 }), "Результатов: 21");
  assert.equal(i18n.locale(), "ru-RU");
  for (const key of ["__proto__", "constructor", "toString"]) assert.equal(i18n.t(key), key);
  i18n.set("en");
  assert.equal(i18n.t("Similar to {name}", { name }), `Similar to ${name}`);
  assert.equal(i18n.t("Find similar"), "Find similar");
});
test("static UI annotations and literal translation calls have catalog entries", () => {
  const decode = (s) => s.replaceAll("&#x27;", "'").replaceAll("&quot;", '"').replaceAll("&amp;", "&");
  for (const filename of ["index.html", "setup.html"]) {
    for (const match of readFileSync(path.join(ui, filename), "utf8").matchAll(/data-i18n(?:-[\w-]+)?="([^"]+)"/g)) {
      assert.ok(Object.hasOwn(i18n.catalog, decode(match[1])), `${filename}: ${match[1]}`);
    }
  }
  for (const filename of ["panel.js", "graph.js", "graph-tools.js", "setup.js"]) {
    for (const match of readFileSync(path.join(ui, filename), "utf8").matchAll(/\bt\("([^"\\]+)"/g)) {
      assert.ok(Object.hasOwn(i18n.catalog, match[1]), `${filename}: ${match[1]}`);
    }
  }
});

test("English singular and Russian neutral counters handle 1, 2, 5 and 21", () => {
  i18n.set("en");
  assert.equal(i18n.t("{count} results", { count: 1 }), "1 result");
  assert.equal(i18n.t("{count} pages", { count: "1" }), "1 page");
  assert.equal(i18n.t("{count} pages", { count: 2 }), "2 pages");
  i18n.set("ru");
  for (const count of [1, 2, 5, 21]) assert.equal(i18n.t("{count} results", { count }), `Результатов: ${count}`);
  i18n.set("en");
});
