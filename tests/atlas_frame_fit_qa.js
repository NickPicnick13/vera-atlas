'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.resolve(__dirname,'../sphere.js'),'utf8');
const ctx={
 clearRect(){},setTransform(){},save(){},restore(){},beginPath(){},
 moveTo(){},lineTo(){},stroke(){},fill(){},arc(){},fillRect(){},
 drawImage(){},createRadialGradient(){return {addColorStop(){}}}
};
const sandbox={window:{},document:{createElement(){return {getContext(){return ctx},width:96,height:96}}},
 devicePixelRatio:1,performance:{now(){return 1000}},console};
vm.runInNewContext(source,sandbox);
const {Sphere,projection,cameraPoint}=sandbox.window.AtlasSphere;
const pts=Array.from({length:2400},(_,i)=>({
 id:'f-'+i,g:i%27===0?'src':'chunk',w:.35+((i*17)%43)/70
}));
const edges=Array.from({length:400},(_,i)=>({a:'f-'+i,b:'f-'+((i+59)%2400),w:.7}));
const cases=[];
for(const [w,h,expectedFit] of [[3008,816,true],[3840,1050,true],[1920,1080,false],[428,428,false]]){
 const canvas={width:w,height:h,style:{},getBoundingClientRect(){return {width:w,height:h}},
    getContext(){return ctx}};
 const sp=new Sphere(canvas,{compact:w===428});sp.resize();sp.setData({nodes:pts,edges});
 sp.render(1000,{seek:true,ageOverride:20000});
 const before=sp.camera.distance;
 sp.fitFrame();
 const view=sp.render(1600,{seek:true,ageOverride:20000});
 const scene=sp.lastCamera;
 const ranges={minX:Infinity,minY:Infinity,maxX:-Infinity,maxY:-Infinity,count:0};
 for(const n of sp.graph.nodes){
   const p=projection(cameraPoint(n,scene),scene);
   if(!p.visible)continue;
   ranges.minX=Math.min(ranges.minX,p.x);ranges.minY=Math.min(ranges.minY,p.y);
   ranges.maxX=Math.max(ranges.maxX,p.x);ranges.maxY=Math.max(ranges.maxY,p.y);
   ranges.count++;
 }
 assert(ranges.count>2200);
 if(expectedFit){
   assert(sp.camera.distance<before, 'wide viewport must grow the real graph');
   assert(view.shapeMorph>.94,'wide viewport must activate safe geometric edge fitting');
   assert(ranges.minX>=0&&ranges.maxX<=w&&ranges.minY>=0&&ranges.maxY<=h,
     'all projected real graph nodes must remain inside the visible frame');
 } else {
   assert(sp.camera.distance>=before-.25,'square-ish windows preserve compact round shape');
   assert(view.shapeMorph<.06, 'square-ish windows do not stretch graph into a rectangle');
 }
 cases.push({width:w,height:h,before:+before.toFixed(3),after:+sp.camera.distance.toFixed(3),
              morph:+view.shapeMorph.toFixed(3),
              bbox:Object.fromEntries(Object.entries(ranges).map(([k,v])=>[k,Math.round(v)]))});
 sp.adaptiveShape=false;sp.shapeStamp=null;
 const raw=sp.render(2000,{seek:true,ageOverride:20000});
 assert(raw.shapeMorph===0,'disabling adaptive fit restores natural/unbounded projection');
 sp.resetCamera();
 assert.equal(sp.camera.distance,4.55,'reset returns to the same original overview');
}
console.log(JSON.stringify({result:'PASS',cases,geometry:'real projected nodes; never interpolated image'}));
