'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.resolve(__dirname,'../sphere.js'),'utf8');
const ctx={
 clearRect(){},setTransform(){},save(){},restore(){},beginPath(){},
 moveTo(x,y){this.a=[x,y]},lineTo(x,y){this.b=[x,y]},
 stroke(){if(this.a&&this.b&&this.lineWidth===2&&this.globalCompositeOperation==='lighter')
  this.traces.push([this.a.map(n=>+n.toFixed(4)),this.b.map(n=>+n.toFixed(4))]);},
 fill(){},arc(){},fillRect(){},drawImage(){},
 createRadialGradient(){return {addColorStop(){}}},
 traces:[],
};
let bounds={width:3840,height:1050};
const canvas={width:0,height:0,style:{},getBoundingClientRect(){return bounds},
 getContext(name){return name==='2d'?ctx:null}};
const sandbox={window:{},document:{createElement(){return {...canvas,width:96,height:96}}},
 devicePixelRatio:1,performance:{now(){return 2400}},console};
vm.runInNewContext(source,sandbox);
const {Sphere}=sandbox.window.AtlasSphere;
const nodes=Array.from({length:12},(_,i)=>({id:'comet-'+i,g:'src',w:1}));
const edges=Array.from({length:6},(_,i)=>({a:'comet-'+(i*2),b:'comet-'+(i*2+1),w:1}));
let variants=new Set(), checked=0, routeChecks=0;
for(const dims of [[3840,1050],[1920,1050],[428,428]]) {
 bounds={width:dims[0],height:dims[1]};
 const sphere=new Sphere(canvas);sphere.resize();sphere.manualOverride=true;
 sphere.setData({nodes,edges});
 const previous=new Map();
 for(let n=0;n<12;n++){
  const current={focusEdges:edges.map(e=>[e.a,e.b]),eventState:'returned',ts:'real-'+n};
  sphere.setTrace(current,0,'replay');
  const modes=[...sphere.cometModes.values()].map(v=>v.style);
  if(n===0)assert.deepEqual(modes.slice(0,4),[0,1,2,3],
                           'initial edges should show different flight styles');
  for(const edge of sphere.focus.edges){
   const mode=sphere.cometModes.get(edge.k)?.style;
   assert.ok(Number.isInteger(mode)&&mode>=0&&mode<4);
   if(previous.has(edge.k))assert.notEqual(mode,previous.get(edge.k),
                                 'same edge must not repeat its previous flight style');
   previous.set(edge.k,mode);variants.add(mode);
  }
  ctx.traces=[];sphere.showComets=false;
  const baseline=sphere.render(2400,{seek:true,ageOverride:2400});
  const traces=JSON.stringify(ctx.traces);
  ctx.traces=[];sphere.showComets=true;
  const overlay=sphere.render(2400,{seek:true,ageOverride:2400});
  assert.equal(JSON.stringify(ctx.traces),traces,'comets must preserve every line-trace stroke');
  assert.equal(overlay.activeEdges.length,baseline.activeEdges.length);
  assert.equal(overlay.signals.length,baseline.signals.length);
  for(const comet of overlay.signals){
   assert.ok(Number.isFinite(comet.x)&&Number.isFinite(comet.y));
   assert.ok(comet.cometStyle>=0&&comet.cometStyle<=3);
  }
  routeChecks++;checked+=overlay.signals.length;
 }
}
assert.deepEqual([...variants].sort(),[0,1,2,3]);
const inactive=new Sphere(canvas);inactive.resize();inactive.setData({nodes,edges});
inactive.showComets=true;
const result=inactive.render(2400,{seek:true,ageOverride:2400});
assert.equal(result.signals.length,0,'no actual trace: no comet flight');
console.log(JSON.stringify({result:'PASS',variants:[...variants].sort(),framesChecked:routeChecks,realEdgeSignals:checked,
 lineTracingAlwaysOn:true,noConsecutiveRepeats:true,noFabricatedEvents:true}));
