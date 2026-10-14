const { test } = require('node:test');
const assert = require('node:assert/strict');
const { GraphModel } = require('../shell/ui/graph.js');
const hit = (path, cosine = .9) => ({ path, cosine, kind: 'doc' });
const reply = (seed, paths, source = 'fixture-vector-source') => ({ seed: hit(seed), hits: paths.map((path) => hit(path)), vector_source: source });
test('cycles and repeated pages do not duplicate nodes or undirected edges', () => {
  const model = new GraphModel(); model.merge(reply('a', ['b', 'c', 'b', 'a']));
  const positions = [...model.nodes.values()].map(({ x, y }) => [x, y]);
  model.merge(reply('b', ['a', 'c'])); model.merge(reply('a', ['b', 'c']));
  assert.equal(model.nodes.size, 3); assert.equal(model.edges.size, 3);
  assert.deepEqual([...model.nodes.values()].map(({ x, y }) => [x, y]), positions);
});
test('byte-distinct Unicode names stay distinct and labels never become IDs', () => {
  const model = new GraphModel(); model.merge(reply('Фото/Café.txt', ['Фото/Cafe\u0301.txt', 'Фото/<script>.txt']));
  assert.equal(model.nodes.size, 3);
});
test('view cap is bounded and new neighbors never overlap existing labels', () => {
  const model = new GraphModel(120); model.merge(reply('seed', Array.from({ length: 200 }, (_, i) => `file-${i}`)));
  assert.equal(model.nodes.size, 120); assert.equal(model.edges.size, 119); assert.equal(model.omitted, 81);
  const nodes = [...model.nodes.values()];
  for (let i = 0; i < nodes.length; i++) for (let j = i + 1; j < nodes.length; j++) {
    assert.ok(Math.abs(nodes[i].x - nodes[j].x) >= 154 || Math.abs(nodes[i].y - nodes[j].y) >= 58);
  }
});
test('mixed model vectors and non-finite similarities cannot enter the same graph', () => {
  const model = new GraphModel(); model.merge(reply('a', ['b']));
  assert.throws(() => model.merge(reply('b', ['c'], 'different-model')), /model changed/);
  model.merge({ seed: hit('a'), hits: [hit('bad', NaN)], vector_source: 'fixture-vector-source' });
  assert.equal(model.nodes.size, 2);
});
