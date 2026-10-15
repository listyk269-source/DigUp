const { test } = require('node:test');
const assert = require('node:assert/strict');
const GS = require('../shell/ui/graph-state.js');
const { GraphModel, separated } = require('../shell/ui/graph.js');
const hit = (path, cosine=.9, modified=1) => ({ path, cosine, modified, size: 5, kind: 'image', segment_id: path.length });
const reply = (paths, changed=false) => ({ seed: hit('Фото/seed.jpg',.9,changed?2:1), hits: paths.map(p=>hit(p)), vector_source: 'real-test-schema' });
test('verification survives serialization but expires when file evidence or model changes', () => {
  const state = new GS.InvestigationState(), model = new GraphModel(120,state);
  model.merge(reply(['Фото/near.jpg'])); let edge = [...model.edges.values()][0];
  assert.equal(edge.status,'unverified'); assert.deepEqual(edge.matchTypes,[]);
  state.verify(edge.reviewKey,'confirmed');
  const restored = new GraphModel(120,new GS.InvestigationState(JSON.parse(JSON.stringify(state.serialize()))));
  restored.merge(reply(['Фото/near.jpg'])); assert.equal([...restored.edges.values()][0].status,'confirmed');
  restored.merge(reply(['Фото/near.jpg'],true)); assert.equal([...restored.edges.values()][0].status,'unverified');
  const other = new GraphModel(120,state); other.merge({...reply(['Фото/near.jpg']),vector_source:'other'});
  assert.equal([...other.edges.values()][0].status,'unverified'); assert.throws(()=>state.verify('x','likely'));
});
test('only evidence-bearing channels become badges; no face label is inferred from image type', () => {
  const model = new GraphModel(), response=reply(['image']);
  response.hits[0].match_types=['face','ocr'];
  response.hits[0].match_evidence=[{type:'visual',cosine:.88},{type:'audio',cosine:NaN},{type:'metadata',value:'2026:10:15'},{type:'unknown',cosine:1}];
  model.merge(response); const edge=[...model.edges.values()][0];
  assert.deepEqual(edge.matchTypes,['visual','metadata']); assert.equal(edge.similarityScore,.9);
});
test('shortest paths exclude rejected and hidden links even when rejected links are visible', () => {
  const model=new GraphModel(); model.merge(reply(['a','b'])); model.merge({seed:hit('a'),hits:[hit('b')],vector_source:'real-test-schema'});
  const direct=model.edges.get(GS.pairKey('Фото/seed.jpg','b')); direct.status='rejected';
  assert.deepEqual(GS.shortestPath(model,'Фото/seed.jpg','b',{showRejected:true}),['Фото/seed.jpg','a','b']);
  model.nodes.get('a').hidden=true; assert.equal(GS.shortestPath(model,'Фото/seed.jpg','b',{showRejected:true}),null);
  assert.equal(GS.visibleEdges(model).length,0);
});
test('byte-distinct Unicode annotations, hidden nodes and pins survive refresh independently', () => {
  const state=new GS.InvestigationState(), seed=hit('Фото/seed.jpg'), a=hit('Café.jpg'), b=hit('Cafe\u0301.jpg');
  state.annotate(a,false,{pinned:{x:900,y:200},hidden:true});
  assert.equal(state.annotation(b,false),undefined); assert.equal(state.annotation(a,true),undefined);
  const model=new GraphModel(120,state); model.merge({...reply([]),seed,hits:[a,b]});
  assert.equal(model.nodes.get(a.path).fx,900); assert.equal(model.nodes.get(a.path).hidden,true);
  model.merge({...reply([]),seed,hits:[a,b]}); assert.equal(model.nodes.get(a.path).x,900);
});
test('timeline orders real dates, separates equal-date cards and preserves explicit fixed coordinates', () => {
  const nodes=Array.from({length:40},(_,i)=>({...hit('f'+i),modified:1000+Math.floor(i/5)*100}));
  nodes[0].fx=-1000;nodes[0].fy=140;
  const layout=GS.timelineLayout(nodes);
  assert.deepEqual(layout.get('f0'),{x:-1000,y:140});
  for(let i=1;i<40;i++) for(let j=i+1;j<40;j++) { assert.ok(separated(layout.get('f'+i),layout.get('f'+j))); if(nodes[i].modified<nodes[j].modified) assert.ok(layout.get('f'+i).x<layout.get('f'+j).x); }
});
test('opening waits for annotation IO and only the newest seed becomes visible', async () => {
  const { GraphView } = require('../shell/ui/graph.js');
  let ready;
  const view = Object.assign(Object.create(GraphView.prototype), {
    generation: 0, searchGeneration: 0, countGeneration: 0,
    annotationsReady: new Promise((resolve) => { ready = resolve; }),
    pages: new Map(), anchors: new Map(), el: () => ({}),
    onVisibility: () => {}, expand: async () => {},
  });
  const older = view.show({ path: 'Фото/old.jpg' }, false);
  assert.equal(view.loading, true);
  const newer = view.show({ path: 'Фото/new.jpg' }, false);
  ready(); await Promise.all([older, newer]);
  assert.equal(view.selected, 'Фото/new.jpg');
  assert.equal(view.visible, true);
  assert.deepEqual([...view.model.nodes.keys()], ['Фото/new.jpg']);
});

test('closing while annotations load prevents the delayed graph from reopening', async () => {
  const { GraphView } = require('../shell/ui/graph.js');
  let ready, reopened = false;
  const view = Object.assign(Object.create(GraphView.prototype), {
    generation: 0, countGeneration: 0, searchGeneration: 0,
    annotationsReady: new Promise((resolve) => { ready = resolve; }),
    stopInspectionMedia: () => {}, hideContext: () => {},
    onVisibility: (visible) => { reopened ||= visible; },
  });
  const opening = view.show({ path: 'Фото/closed.jpg' }, false);
  view.close(); ready(); await opening;
  assert.equal(view.visible, false);
  assert.equal(view.loading, false);
  assert.equal(reopened, false);
});
