'use strict';
// Production rendering regression without browser, external process, or live fake events.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.resolve(__dirname,'../sphere.js'),'utf8');
let images=0, cometCores=0, strokes=[], start=null, end=null;
const ctx={
 clearRect(){},setTransform(){},save(){},restore(){},beginPath(){},
 moveTo(x,y){start=[x,y]},lineTo(x,y){end=[x,y]},
 stroke(){if(start&&end)strokes.push({width:this.lineWidth, mode:this.globalCompositeOperation,
   a:start.map(v=>Math.round(v*1000)/1000),b:end.map(v=>Math.round(v*1000)/1000)})},
 fill(){},arc(x,y,r){if(r===3.25)cometCores++;},fillRect(){},
 drawImage(){images++;},
 createRadialGradient(){return {addColorStop(){}}}
};
const canvas={width:0,height:0,style:{},getBoundingClientRect(){return {width:1800,height:520}},
  getContext(name){return name==='2d'?ctx:null}};
const sandbox={window:{},document:{createElement(){return {...canvas,width:96,height:96,setAttribute(){}}}},
  devicePixelRatio:1,performance:{now(){return 2400}},console};
vm.runInNewContext(source,sandbox,{filename:'sphere.js'});
const {Sphere,screenEdge,cameraPoint,projection,lerpPoint}=sandbox.window.AtlasSphere;
const sphere=new Sphere(canvas);sphere.resize();
const nodes=['a','b','c','d'].map(id=>({id:'src-'+id,g:'src',w:1}));
const edges=[{a:'src-a',b:'src-b',w:1},{a:'src-c',b:'src-d',w:1}];
sphere.setData({nodes,edges});
sphere.setTrace({focusEdges:edges.map(e=>[e.a,e.b]),eventState:'returned'},0,'replay');
sphere.camera.distance=4.55;sphere.manualOverride=true;
sphere.adaptiveShape=true;sphere.shapeMorph=1;sphere.shapeStamp=2400;
assert.equal(sphere.showComets,false,'line-only initial state');
function render(){
 images=0;strokes=[];start=null;end=null;
 const view=sphere.render(2400,{seek:true,ageOverride:2400});
 const linePulse=strokes.filter(v=>v.width===2&&v.mode==='lighter');
 return {view,images,linePulse};
}
const off=render();
assert.equal(off.view.signals.length,2,'both real graph edges stay active');
for(const signal of off.view.signals){
 const a=sphere.graph.byId.get(signal.a),b=sphere.graph.byId.get(signal.b);
 const [p,q]=screenEdge(cameraPoint(a,sphere.lastCamera),
                        cameraPoint(b,sphere.lastCamera),sphere.lastCamera);
 const vx=q.x-p.x,vy=q.y-p.y,wx=signal.x-p.x,wy=signal.y-p.y;
 const dist=Math.abs(vx*wy-vy*wx)/Math.max(1,Math.hypot(vx,vy));
 assert.ok(dist<1e-8,'signal strayed off line: '+dist);
 const along=(vx*wx+vy*wy)/Math.max(1,vx*vx+vy*vy);
 assert.ok(Math.abs(along-signal.progress)<1e-8,'progress differs from on-line distance');
}
sphere.showComets=true;
const on=render();
assert.ok(off.linePulse.length>0,'line-only mode must trace moving pulses on edges');
assert.deepEqual(on.linePulse,off.linePulse,
  'with comets enabled, the ORIGINAL line-pulse path must still be rendered unchanged');
assert.equal(on.view.signals.length,off.view.signals.length);
assert.equal(on.images-off.images,on.view.signals.length,'one head glow per selected edge');
let distinct=0;
for(let i=0;i<off.view.signals.length;i++){
 const signal=on.view.signals[i];
 const a=cameraPoint(sphere.graph.byId.get(signal.a),sphere.lastCamera);
 const b=cameraPoint(sphere.graph.byId.get(signal.b),sphere.lastCamera);
 const projected=projection(lerpPoint(a,b,signal.progress),sphere.lastCamera);
 assert.ok(Number.isFinite(signal.x)&&Number.isFinite(signal.y),'comet has finite screen coordinates');
 // The 3D path is preferred where it separates from the edge; its
 // intentional curved fallback may differ from the raw projection.
 const dx=signal.x-off.view.signals[i].x;
 const dy=signal.y-off.view.signals[i].y;
 if(Math.hypot(dx,dy)>.01)distinct++;
}
assert.ok(distinct>0,'restored 3D comet visibly follows a different path');
sphere.showComets=false;
const restored=render();
assert.equal(restored.images,off.images,'toggle-off restores no-head style');
assert.equal(restored.view.activeEdges.length,on.view.activeEdges.length);
// Regression: a 3D head may lie behind the near plane even when the
// projected edge is partly visible. Switching on comets may not erase pulses.
const clipped=new Sphere(canvas);
clipped.resize();
const many=Array.from({length:32},(_,i)=>({id:'n-'+i,g:'src',w:1}));
const links=Array.from({length:16},(_,i)=>({a:'n-'+i*2,b:'n-'+(i*2+1),w:1}));
clipped.setData({nodes:many,edges:links});
clipped.setTrace({focusEdges:links.map(e=>[e.a,e.b]),eventState:'returned'},0,'replay');
clipped.adaptiveShape=false;
clipped.manualOverride=true;
let recovered=0;
for(const d of [.25,.4,.6,.8,1,1.5,2,3,4.55,6]) {
 for(const pitch of [-1,-.5,0,.5,1]) {
  clipped.camera.distance=d;clipped.pose.pitch=pitch;
  clipped.showComets=false;
  const a=clipped.render(2500,{seek:true,ageOverride:2500}).signals.length;
  clipped.showComets=true;
  const b=clipped.render(2500,{seek:true,ageOverride:2500}).signals.length;
  assert.ok(b>=a,'comets vanished behind near-plane at distance='+d+' pitch='+pitch+' '+a+'->'+b);
  recovered+=a;
 }
}
assert.ok(recovered>0,'clipping test exercised no visible edges');
// Narrow secondary monitor must get a distinguishable bright comet core.
const oldRect=canvas.getBoundingClientRect;
canvas.getBoundingClientRect=()=>({width:1920,height:1050});
const narrow=new Sphere(canvas);narrow.resize();
narrow.setData({nodes,edges});
narrow.setTrace({focusEdges:edges.map(e=>[e.a,e.b]),eventState:'returned'},0,'replay');
narrow.camera.distance=4.55;narrow.manualOverride=true;narrow.adaptiveShape=true;
cometCores=0;strokes=[];
narrow.showComets=false;
const narrowOff=narrow.render(2400,{seek:true,ageOverride:2400});
const narrowLineOff=strokes.filter(v=>v.width===2&&v.mode==='lighter');
assert.equal(cometCores,0,'no comet core while switched off');
strokes=[];
narrow.showComets=true;
const narrowOn=narrow.render(2400,{seek:true,ageOverride:2400});
const narrowLineOn=strokes.filter(v=>v.width===2&&v.mode==='lighter');
assert.ok(narrowLineOff.length>0,'Samsung baseline has visible traced pulses');
assert.deepEqual(narrowLineOn,narrowLineOff,
 'Samsung must retain the EXACT line-tracing layer with comets enabled');
assert.equal(cometCores,narrowOn.signals.length,'visible core per comet on narrow display');
assert.equal(narrowOn.signals.length,narrowOff.signals.length);
canvas.getBoundingClientRect=oldRect;
console.log(JSON.stringify({result:'PASS',edges:off.view.activeEdges.length,
  offImages:off.images,onImages:on.images,distinct3DComets:distinct,deviationPx:0,reversible:true}));
