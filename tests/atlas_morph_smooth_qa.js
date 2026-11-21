// Regression QA: overlapping multi-stream bursts morph focus & camera smoothly
// without frame-to-frame snaps or brightness flashes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const ctx = new Proxy({ createRadialGradient: () => ({ addColorStop() {} }) }, {
  get(o, k) { if (k in o) return o[k]; return () => {}; },
  set(o, k, v) { o[k] = v; return true; }
});
global.window = {};
global.devicePixelRatio = 1;
global.document = { createElement: () => ({ width: 96, height: 96, getContext: () => ctx }) };
vm.runInThisContext(fs.readFileSync('sphere.js', 'utf8'), { filename: 'sphere.js' });
const { Sphere } = window.AtlasSphere;

function buildSphere(compact) {
  const canvas = {
    getContext: () => ctx,
    getBoundingClientRect: () => ({ width: compact ? 428 : 1600, height: compact ? 428 : 900 }),
    width: 0, height: 0
  };
  const s = new Sphere(canvas, { compact });
  s.resize();
  s.showIdleLines = true;
  s.showComets = true;
  const nodes = [
    { id: 'd-reader', g: 'src', w: 1 },
    { id: 'd-flash', g: 'src', w: 1 },
    { id: 'd-agent', g: 'src', w: 1 },
  ];
  const edges = [
    { a: 'd-reader', b: 'd-flash', w: 1 },
    { a: 'd-reader', b: 'd-agent', w: 1 },
  ];
  for (let i = 0; i < 40; i++) {
    nodes.push({ id: `c-${i}`, g: 'core', w: 0.7 });
    edges.push({ a: 'd-flash', b: `c-${i}`, w: 0.5 });
    edges.push({ a: 'd-agent', b: `c-${i}`, w: 0.5 });
  }
  s.setData({ nodes, edges });
  return s;
}

function runBurstSimulation(compact) {
  const s = buildSphere(compact);
  let prev = s.render(1000, { angle: 0 });
  let maxFocusJump = 0;
  let maxDistJump = 0;
  let maxPanJump = 0;
  let minFocusDuringBursts = 1;

  const streams = [
    [['d-reader', 'd-flash'], ['d-flash', 'c-1'], ['d-flash', 'c-2']],
    [['d-reader', 'd-agent'], ['d-agent', 'c-10'], ['d-agent', 'c-11']],
  ];

  let nextBurstAt = 1100;
  let burstIdx = 0;
  for (let t = 1016; t <= 6500; t += 16) {
    if (t >= nextBurstAt && burstIdx < 8) {
      const combined = [];
      for (let k = Math.max(0, burstIdx - 1); k <= burstIdx; k++) {
        combined.push(...streams[k % streams.length]);
      }
      s.setTrace({ ts: `b-${burstIdx}`, focusEdges: combined }, t, 'replay');
      burstIdx++;
      nextBurstAt += 500;
    }
    const cur = s.render(t, { angle: 0 });
    maxFocusJump = Math.max(maxFocusJump, Math.abs(cur.focus - prev.focus));
    maxDistJump = Math.max(maxDistJump, Math.abs(cur.camera.distance - prev.camera.distance));
    maxPanJump = Math.max(
      maxPanJump,
      Math.hypot(cur.camera.panX - prev.camera.panX, cur.camera.panY - prev.camera.panY)
    );
    if (t >= 2400 && t <= 5000) {
      minFocusDuringBursts = Math.min(minFocusDuringBursts, cur.focus);
    }
    prev = cur;
  }
  for (let t = 6516; t <= 12500; t += 16) {
    const cur = s.render(t, { angle: 0 });
    maxFocusJump = Math.max(maxFocusJump, Math.abs(cur.focus - prev.focus));
    maxDistJump = Math.max(maxDistJump, Math.abs(cur.camera.distance - prev.camera.distance));
    maxPanJump = Math.max(
      maxPanJump,
      Math.hypot(cur.camera.panX - prev.camera.panX, cur.camera.panY - prev.camera.panY)
    );
    prev = cur;
  }
  return { maxFocusJump, maxDistJump, maxPanJump, minFocusDuringBursts };
}

const compactStats = runBurstSimulation(true);
const wideStats = runBurstSimulation(false);
assert.ok(compactStats.maxFocusJump < 0.08, `compact focus jumped: ${compactStats.maxFocusJump}`);
assert.ok(compactStats.maxDistJump < 0.04, `compact distance jumped: ${compactStats.maxDistJump}`);
assert.ok(compactStats.minFocusDuringBursts > 0.85, `compact focus dipped: ${compactStats.minFocusDuringBursts}`);
assert.ok(wideStats.maxFocusJump < 0.08, `wide focus jumped: ${wideStats.maxFocusJump}`);
assert.ok(wideStats.maxDistJump < 0.12, `wide distance jumped: ${wideStats.maxDistJump}`);
assert.ok(wideStats.minFocusDuringBursts > 0.85, `wide focus dipped: ${wideStats.minFocusDuringBursts}`);
console.log(JSON.stringify({ result: 'PASS', compact: compactStats, wide: wideStats }));
