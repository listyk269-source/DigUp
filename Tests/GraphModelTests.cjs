const { test } = require('node:test');
const assert = require('node:assert/strict');
const { GraphModel, GRAPH_CARD, separated, graphBounds, graphCurve, curvePoint } = require('../shell/ui/graph.js');
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


test('force relaxation preserves pinned nodes and enforces card-sized whitespace at the 120-node cap', () => {
  const model = new GraphModel(); model.merge(reply('root', Array.from({ length: 6 }, (_, i) => `first-${i}`)));
  const pinned = new Map([...model.nodes].map(([path, n]) => [path, { x: n.x, y: n.y }]));
  for (let i = 0; i < 20; i++) model.merge(reply(`first-${i % 6}`, Array.from({ length: 6 }, (_, j) => `added-${i}-${j}`)));
  for (const [path, point] of pinned) assert.deepEqual({ x: model.nodes.get(path).x, y: model.nodes.get(path).y }, point);
  const all = [...model.nodes.values()];
  for (let i = 0; i < all.length; i++) for (let j = i + 1; j < all.length; j++) assert.ok(separated(all[i], all[j]), `${all[i].path} / ${all[j].path}`);
  assert.equal(all.length, 120);
});
test('Bezier routing avoids an intervening card and labels are outside card content', () => {
  const from = { path: 'from', x: -420, y: 0 }, to = { path: 'to', x: 420, y: 0 }, blocker = { path: 'blocker', x: 0, y: 0 };
  const route = graphCurve(from, to, [from, to, blocker]);
  assert.equal(route.score, 0); assert.match(route.drawing, / C /);
  for (let i = 1; i < 24; i++) { const p = curvePoint(route, i / 24); assert.ok(Math.abs(p.x) >= GRAPH_CARD.width / 2 + 10 || Math.abs(p.y) >= GRAPH_CARD.height / 2 + 10); }
});
test('minimap bounds contain every full card, including Unicode nodes far from the origin', () => {
  const nodes = [{ path: 'Фото', x: -3500, y: 1600 }, { path: '動画', x: 4100, y: -2200 }], b = graphBounds(nodes);
  for (const n of nodes) { assert.ok(n.x - GRAPH_CARD.width / 2 > b.x && n.x + GRAPH_CARD.width / 2 < b.x + b.width); assert.ok(n.y - GRAPH_CARD.height / 2 > b.y && n.y + GRAPH_CARD.height / 2 < b.y + b.height); }
});
test('radial neighborhoods keep finite curved paths and separate coefficient labels', () => {
  const model = new GraphModel(); model.merge(reply('seed', ['a', 'b', 'c', 'd', 'e', 'f'])); const labels = [];
  for (const edge of model.edges.values()) { const curve = graphCurve(model.nodes.get(edge.from), model.nodes.get(edge.to), model.nodes.values(), labels); assert.ok(Number.isFinite(curve.label.x)); assert.ok(Number.isFinite(curve.label.y)); assert.ok(!/NaN|Infinity/.test(curve.drawing)); labels.push(curve.label); }
  for (let i=0;i<labels.length;i++) for(let j=i+1;j<labels.length;j++) assert.ok(Math.abs(labels[i].x-labels[j].x)>=56 || Math.abs(labels[i].y-labels[j].y)>=26);
});
