'use strict';
// Production rendering regression without browser, external process, or live fake events.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.resolve(__dirname,'../sphere.js'),'utf8');
let images=0;
const ctx={
 clearRect(){},setTransform(){},save(){},restore(){},beginPath(){},
 moveTo(){},lineTo(){},stroke(){},fill(){},arc(){},fillRect(){},
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
 images=0;
 const view=sphere.render(2400,{seek:true,ageOverride:2400});
 return {view,images};
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
assert.equal(on.view.signals.length,off.view.signals.length);
assert.equal(on.images-off.images,on.view.signals.length,'one head glow per selected edge');
let distinct=0;
for(let i=0;i<off.view.signals.length;i++){
 const signal=on.view.signals[i];
 const a=cameraPoint(sphere.graph.byId.get(signal.a),sphere.lastCamera);
 const b=cameraPoint(sphere.graph.byId.get(signal.b),sphere.lastCamera);
 const projected=projection(lerpPoint(a,b,signal.progress),sphere.lastCamera);
 assert.ok(Math.abs(signal.x-projected.x)<1e-8,'comet projected x');
 assert.ok(Math.abs(signal.y-projected.y)<1e-8,'comet projected y');
 const dx=signal.x-off.view.signals[i].x;
 const dy=signal.y-off.view.signals[i].y;
 if(Math.hypot(dx,dy)>.01)distinct++;
}
assert.ok(distinct>0,'restored 3D comet visibly follows a different path');
sphere.showComets=false;
const restored=render();
assert.equal(restored.images,off.images,'toggle-off restores no-head style');
assert.equal(restored.view.activeEdges.length,on.view.activeEdges.length);
console.log(JSON.stringify({result:'PASS',edges:off.view.activeEdges.length,
  offImages:off.images,onImages:on.images,distinct3DComets:distinct,deviationPx:0,reversible:true}));
