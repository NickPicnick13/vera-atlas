/* Local WKWebView / browser adapter. Trace time is never used as a wall clock. */
(() => {
'use strict';
const $ = id => document.getElementById(id);
const embedded = location.hash === '#embed', inspect = new URLSearchParams(location.search).has('inspect');
const canvas = $('graph'), sphere = new AtlasSphere.Sphere(canvas,{compact:embedded}), footer = document.querySelector('footer');
const reduced = matchMedia('(prefers-reduced-motion: reduce)'), native = window.webkit?.messageHandlers?.widget;
const localClock = new Intl.DateTimeFormat(undefined,{hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
let trace=null,signature=null,lastSelection=null,graph={},view=null,frameID=0,endTimer=0,clockTimer=0;
let atlasDraws=0, atlasLastDrawMS=0;
let lastDraw=-Infinity,lastFrame=0,testing=false,seekAge=0,demo=false,ready=false,hasFocus=false;
let chromeKey='',readySent=false,focusSent=false,workEpoch=null,paintKey='';
let lastRegion='';
const request = () => { if (!frameID && !testing && !document.hidden) frameID=requestAnimationFrame(frame); };
const plural = n => {const k=n%100,j=n%10;return `${n} ${k>=11&&k<=14?'фрагментов':j===1?'фрагмент':j>=2&&j<=4?'фрагмента':'фрагментов'}`;};
function example() {
   const nodes=Array.from({length:1200},(_,i)=>({id:`demo-${i}`,g:i%19===0?'src':'core',w:(i*29%71)/100+.25}));
   nodes.push({id:'example-1',g:'chunk',w:1},{id:'example-2',g:'chunk',w:1},{id:'example-3',g:'chunk',w:1},{id:'example-4',g:'chunk',w:1});
   const edges=[];
   for(let i=0;i<720;i++) edges.push({a:`demo-${i}`,b:`demo-${(i+67)%1200}`,w:.45});
   const focusEdges=[['demo-38','example-1'],['demo-38','example-2'],['demo-38','example-3'],['demo-38','example-4']];
   edges.push(...focusEdges.map(([a,b])=>({a,b,w:1})));
   return {nodes,edges,trace:{ts:'example',focusEdges,selected:[{id:'demo-38',source:'ideas'}]}};
}
function describe(t) {
   const labels=[[/skysight/,'История компьютера'],[/session/,'Запись разговора'],[/ideas/,'Журнал идей'],[/lightrag/,'Граф документов'],[/graphify/,'Граф кода'],[/temporal/,'Хронология'],[/telegram|tg-private/,'Переписка'],[/obsidian|note/,'Заметки'],[/soroka/,'Короткие заметки'],[/palace/,'Архив памяти']];
   const sources=new Set((t?.selected||[]).map(s=>s?.id).filter(Boolean));
   if (sources.size>1) return `${sources.size} ${sources.size===2||sources.size===3||sources.size===4?'источника':'источников'}`;
   const category=String(t?.selected?.[0]?.source||'');
   return labels.find(([p])=>p.test(category))?.[1] || (sources.size?'Источник памяти':'');
}
function updateClock() {
   clearTimeout(clockTimer);
   const now=new Date(), clock=$('clock');
   clock.textContent=localClock.format(now);
   clock.dateTime=now.toISOString();
   clockTimer=setTimeout(updateClock,60000-(now.getTime()%60000)+35);
}
function info() {
   const active=hasFocus&&view?.focus>.19&&view?.phase!=='work';
   const key=[demo,ready,active,sphere.working,hasFocus,signature,!!lastSelection].join('|');
   if(key===chromeKey)return;
   chromeKey=key;
   const mode=$('mode'); mode.hidden=!demo; mode.lastElementChild.textContent=demo?'Демонстрация':'';
   footer.dataset.focus=active?'yes':'no';
   const state=active?`Выбрано: ${plural(sphere.focus.edges.length)}`:sphere.working?'Идёт работа':'';
   $('state').textContent=state;
   $('detail').textContent=active?describe(trace):'';
   canvas.setAttribute('aria-label',active?'Камера приблизилась к выбранным связям памяти.':sphere.working?'Идёт работа в Harness.':'Светящееся облако узлов памяти.');
   $('replay').disabled=!lastSelection;
   $('note').hidden=ready;
   $('note').textContent=ready?'':'Жду данные графа';
}
function draw(at=performance.now()) {
   atlasDraws++;atlasLastDrawMS=at;
   view=sphere.render(at,{reduced:reduced.matches,...(testing?{seek:true,ageOverride:seekAge,angle:seekAge*.00009}:{})});
   info();
   if(embedded&&native&&!inspect&&ready&&view){
      const region=sphere.hitArea();
      if(region){
         const rounded=[region.x,region.y,region.r].map(x=>Math.round(x/3)*3),key=rounded.join('/');
         if(lastRegion!==key){lastRegion=key;native.postMessage({action:'graphHitArea',x:rounded[0],y:rounded[1],r:rounded[2]});}
      }
      const bits=[view.working,view.activeEdges.length];
      if(paintKey!==bits.join('/')){
         paintKey=bits.join('/');native.postMessage({action:'atlasWorkPainted',running:bits[0],selectedLinks:bits[1]});
      }
   }
   if (embedded&&native&&!inspect&&!demo&&ready&&view&&(!readySent||(!focusSent&&view.focus>.85&&view.signals.length))) {
      readySent=true;
      if (view.focus>.85&&view.signals.length) focusSent=true;
      native.postMessage({action:'sphereReady',renderer:'topology',nodes:sphere.graph.nodes.length,
         selectedLinks:focusSent?view.activeEdges.length:0,
         graphEdges:view.graphEdges??sphere.graph.edges.length,backend:view.backend??'canvas2d',
         cometsEnabled:sphere.showComets===true,cometSignals:view.signals.length});
   }
}
function frame(at) {
   frameID=0;
   const cadence=sphere.working||view?.phase!=='idle'?1000/32:1000/22;
   if(at-lastDraw>=cadence-2) {
      const dt=lastFrame?Math.min(120,at-lastFrame):0;lastFrame=at;
      if(!reduced.matches) {
      const motionSpeed=sphere.motionSpeed ?? 1;
      const idle = !sphere.working && view?.phase === 'idle' && sphere.memoryAccesses.length === 0;
      if(sphere.spin?.direction){
          if(!sphere.spin.dragging){
             const target=(idle ? .000045 : .00009)*.5;
             sphere.spin.speed=target+(sphere.spin.speed-target)*Math.exp(-dt/1250);
             sphere.pose.yaw+=sphere.spin.direction.x*sphere.spin.speed*dt*motionSpeed;
             sphere.pose.pitch+=sphere.spin.direction.y*sphere.spin.speed*dt*motionSpeed;
          }
       }else if(!sphere.spin?.dragging){
          sphere.angle += dt * (idle ? .000045 : .00009)*motionSpeed;
       }
   }
      draw(at);lastDraw=at;
   }
   if(!reduced.matches&&ready) request();
   else if(sphere.traceMode==='replay'&&hasFocus&&at-sphere.started<8750&&!document.hidden){
      clearTimeout(endTimer);endTimer=setTimeout(()=>draw(),Math.max(50,8760-(at-sphere.started)));
   }
}
function extent(){sphere.resize();draw();request();}
function remember(t){
   if(AtlasSphere.focusOf(t||{},sphere.graph).edges.length)lastSelection=t;
}
let mergeBatchDepth=0;
function applyTrace(t,{force=false,mode='replay'}={}) {
   const next=t||{}, sig=JSON.stringify([mode,next.ts??'',next.focusEdges??[]]);
   if(!force&&sig===signature)return;
   signature=sig;trace=next;sphere.setTrace(next,performance.now(),mode);
   hasFocus=!!sphere.focus.edges.length;focusSent=false;
   remember(next);seekAge=0;chromeKey='';if(!mergeBatchDepth){draw();request();}
}
function setData(data,illustration=false) {
   graph=data||{};demo=illustration;
   sphere.setData(graph);ready=!!sphere.graph.nodes.length;
   if(!ready)lastSelection=null;
   remember(graph.trace);
   // Opening or restoring the native window is not a fresh recall or turn.
   if(!embedded&&graph.trace)applyTrace(graph.trace);
   draw();request();
}
window.__atlasMotionStatus=()=>({
    hidden:document.hidden, visibility:document.visibilityState, draws:atlasDraws,
    sinceLastDraw:Math.round(performance.now()-atlasLastDrawMS), rafPending:!!frameID,
    ready, comets:sphere.showComets, signals:view?.signals?.length||0,
    working:!!sphere.working, phase:view?.phase||null, width:innerWidth, height:innerHeight
});
window.__setAtlasData=d=>setData(d,false);
window.__applyTrace=t=>applyTrace(t);
window.__setAtlasActivity=({running=false,epoch=null,actorID=null}={})=>{
   const now=performance.now();
   // Identity comes only from authenticated read-only Desktop Host state;
   // do not let any text/prompt choose a fake active graph node.
   sphere.activeActorID=running&&typeof actorID==='string'&&/^h-[0-9a-f]{24}$/.test(actorID)?actorID:null;
   if(running&&sphere.working&&workEpoch!==epoch){sphere.handoffActivity(now);signature=null;}
   else sphere.setActivity(running===true,now);
   workEpoch=epoch;
   hasFocus=!!sphere.focus.edges.length;chromeKey='';draw();request();
};
window.__atlasMemoryAccess=()=>{
   const sequence=sphere.memoryAccess(performance.now());
   chromeKey='';draw();request();
   return sequence;
};
window.__atlasSetIdleLines=enabled=>{
   sphere.showIdleLines=(enabled===true);
   chromeKey='';draw();request();
   return sphere.showIdleLines;
};
window.__atlasSetMotionSpeed=value=>{
   if(typeof value!=='number'||!Number.isFinite(value))return sphere.motionSpeed;
   sphere.motionSpeed=Math.max(0,Math.min(3,value));
   chromeKey='';draw();request();
   return sphere.motionSpeed;
};
window.__atlasSetAdaptiveShape=enabled=>{
   sphere.adaptiveShape=(enabled===true);
   // Menu toggle is an explicit comparison: switch at once. Window resizing
   // and user zoom continue to morph naturally over subsequent frames.
   if(!sphere.adaptiveShape)sphere.shapeMorph=0;
   sphere.shapeStamp=null;
   chromeKey='';draw();request();
   return sphere.adaptiveShape;
};
window.__atlasSetComets=enabled=>{
   sphere.showComets=(enabled===true);
   chromeKey='';draw();request();
   return sphere.showComets;
};
window.__atlasSetContinuousWorkLines=enabled=>{
   sphere.showContinuousWorkLines=(enabled===true);
   chromeKey='';draw();request();
   return sphere.showContinuousWorkLines;
};
window.__atlasWindowCommand=c=>{
   if(c==='lines-on'||c==='lines-off'){window.__atlasSetIdleLines(c==='lines-on');return;}
   if(c==='adaptive-on'||c==='adaptive-off'){window.__atlasSetAdaptiveShape(c==='adaptive-on');return;}
   if(c==='comets-on'||c==='comets-off'){window.__atlasSetComets(c==='comets-on');return;}
   if(c==='work-lines-on'||c==='work-lines-off'){
      window.__atlasSetContinuousWorkLines(c==='work-lines-on');return;
   }

   if(c==='replay')$('replay').click();
   else if(c==='recent')window.__atlasReplayRecent();
   else if(c==='reset'){sphere.resetCamera?.();draw();request();}
   else if(c==='zoom-in'||c==='zoom-out'||c==='universe'){
      const x=sphere.w/2,y=sphere.h/2;
      if(c==='universe'){
         // Zoom the real graph; no rescaling or replacement of its topology.
         sphere.takeCamera?.();
         sphere.zoomAt?.(x,y,sphere.camera.distance/0.9);
      }else sphere.zoomAt?.(x,y,c==='zoom-in'?1.5:1/1.5);
      draw();request();
   }
};
window.__widgetState=state=>$('pin').setAttribute('aria-pressed',state==='pinned'?'true':'false');
$('pin').addEventListener('click',()=>native?.postMessage('togglePin'));
$('hide').addEventListener('click',()=>native?.postMessage('collapse'));
$('recent').addEventListener('click',()=>window.__atlasReplayRecent());
$('focusSource').addEventListener('click',()=>
    window.__atlasCycleObservedProject()||window.__atlasCycleObservedSource());
$('replay').addEventListener('click',()=>{
   // Replay only re-runs the previous nonempty trace; the graph itself is not rebuilt.
   if(lastSelection&&!sphere.working)applyTrace(lastSelection,{force:true});
});
// A single memory operation often generates several real events (VeraCore ->
// adapter -> selected document chunks). Do not let the last arriving event
// erase the other paths before the user sees them. Only merge actual graph
// edges observed within a short live window; never invent document access.
let recentAccessEdges=[],recentAccessAt=0;
const activityHistory=[];
let historyPointer=-1;
function storeActivity(t){
   if(!t?.focusEdges?.length)return;
   const at=performance.now();
   while(activityHistory.length&&at-activityHistory[0].at>600000)activityHistory.shift();
   activityHistory.push({at,trace:{...t,focusEdges:t.focusEdges.slice(0,40)}});
   if(activityHistory.length>160)activityHistory.shift();
}
window.__atlasReplayRecent=()=>{
   const now=performance.now();
   while(activityHistory.length&&now-activityHistory[0].at>600000)activityHistory.shift();
   if(!activityHistory.length)return false;
   historyPointer=(historyPointer+1)%activityHistory.length;
   applyTrace(activityHistory[historyPointer].trace,{force:true,mode:'replay'});
   return true;
};
window.__atlasRecentActivity=()=>({count:activityHistory.length,windowMinutes:10});
window.__atlasObservedSources=()=>{
   const sources=new Set();
   for(const item of activityHistory)for(const v of item.trace.selected||[]){
      if(typeof v?.source==='string'&&v.source.length<=128)sources.add(v.source);
   }
   return [...sources].slice(0,30);
};
let sourceFocusIndex=-1;
window.__atlasCycleObservedSource=()=>{
   const sources=window.__atlasObservedSources();
   if(!sources.length)return false;
   sourceFocusIndex=(sourceFocusIndex+1)%sources.length;
   return window.__atlasFocusObservedSource(sources[sourceFocusIndex]);
};
window.__atlasObservedProjects=()=>[...new Set(activityHistory
    .map(x=>x.trace.projectID).filter(x=>typeof x==='string'&&/^p-[0-9a-f]{24}$/.test(x)))];
let projectFocusIndex=-1;
window.__atlasCycleObservedProject=()=>{
   const projects=window.__atlasObservedProjects();
   if(!projects.length)return false;
   projectFocusIndex=(projectFocusIndex+1)%projects.length;
   const event=[...activityHistory].reverse().find(x=>x.trace.projectID===projects[projectFocusIndex]);
   if(!event)return false;
   applyTrace(event.trace,{force:true,mode:'replay'});
   return true;
};
window.__atlasFocusObservedSource=(source)=>{
   if(typeof source!=='string'||source.length>128)return false;
   const match=[...activityHistory].reverse().find(x=>
      Array.isArray(x.trace.selected)&&x.trace.selected.some(v=>v?.source===source));
   if(!match)return false;
   applyTrace(match.trace,{force:true,mode:'replay'});
   return true;
};

window.__mergeAtlasTrace=d=>{
   if(!d)return;
   if((d.nodes&&d.nodes.length)||(d.edges&&d.edges.length))sphere.mergeData?.({nodes:d.nodes||[],edges:d.edges||[]});
   if(d.trace)remember(d.trace);
   if(d.trace&&d.live===true&&AtlasSphere.focusOf(d.trace,sphere.graph).edges.length){
      let incoming=d.trace;
      if(d.memoryAccess===true){
         const now=performance.now();
         if(now-recentAccessAt>6000)recentAccessEdges=[];
         const pairs=new Map();
         for(const pair of [...recentAccessEdges,...(incoming.focusEdges||[])]){
            const a=String(pair?.[0]??''),b=String(pair?.[1]??'');
            if(!a||!b)continue;
            const key=JSON.stringify(a<b?[a,b]:[b,a]);
            if(!pairs.has(key))pairs.set(key,[a,b]);
         }
         // Cap the illuminated path to protect the rendering budget. No
         // synthetic links: each candidate must already exist in the graph.
         recentAccessEdges=[...pairs.values()].filter(pair=>
            AtlasSphere.focusOf({focusEdges:[pair]},sphere.graph).edges.length).slice(-40);
         recentAccessAt=now;
         incoming={...incoming,focusEdges:recentAccessEdges};
      }else{
         recentAccessEdges=[];recentAccessAt=0;
      }
      storeActivity(incoming);
      applyTrace(incoming,{mode:d.memoryAccess===true?'replay':'live'});
   }else {chromeKey='';if(!mergeBatchDepth){draw();request();}}
};
// Merge 20+ genuine Harness tool/model events in one actual render frame.
// Each trace still contributes its own verified edges; no synthetic links.
window.__mergeAtlasBatch=deltas=>{
   if(!Array.isArray(deltas)||deltas.length>128)return false;
   mergeBatchDepth++;
   try{for(const delta of deltas)window.__mergeAtlasTrace(delta);}
   finally{mergeBatchDepth--;}
   chromeKey='';draw();request();
   return true;
};
const cssXY=e=>{const r=canvas.getBoundingClientRect();return [e.clientX-r.left,e.clientY-r.top];};
const center=()=>[sphere.w/2,sphere.h/2];
const zoomStep=f=>{const [x,y]=center();sphere.zoomAt?.(x,y,f);draw();request();};
$('zoomIn').addEventListener('click',()=>zoomStep(1.25));
$('zoomOut').addEventListener('click',()=>zoomStep(1/1.25));
$('zoomReset').addEventListener('click',()=>{sphere.resetCamera?.();draw();request();});
document.addEventListener('keydown',e=>{
   if(e.target&&/^(input|textarea|select)$/i.test(e.target.tagName))return;
   const [cx,cy]=center(),step=28;
   switch(e.key){
      case '+':case '=':sphere.zoomAt?.(cx,cy,1.25);e.preventDefault();break;
      case '-':case '_':sphere.zoomAt?.(cx,cy,1/1.25);e.preventDefault();break;
      case '0':sphere.resetCamera?.();e.preventDefault();break;
      case 'ArrowLeft':sphere.panBy?.(step,0);e.preventDefault();break;
      case 'ArrowRight':sphere.panBy?.(-step,0);e.preventDefault();break;
      case 'ArrowUp':sphere.panBy?.(0,step);e.preventDefault();break;
      case 'ArrowDown':sphere.panBy?.(0,-step);e.preventDefault();break;
      default:return;
   }
   draw();request();
});
// Unmodified wheel zooms under the pointer; Cmd-wheel belongs to AppKit window drag.
canvas.addEventListener('wheel',e=>{
   if(embedded&&e.metaKey)return;
   e.preventDefault();
   const [x,y]=cssXY(e);
   sphere.zoomAt?.(x,y,Math.exp(-e.deltaY*.0016));
   draw();request();
},{passive:false});
canvas.addEventListener('contextmenu',e=>e.preventDefault());
const pointers=new Map();let pinch=null;
canvas.addEventListener('pointerdown',e=>{
   if(!ready)return;
   if(embedded&&native&&e.button===0&&e.metaKey)return;
    canvas.setPointerCapture(e.pointerId);
   pointers.set(e.pointerId,{x:e.clientX,y:e.clientY,sx:e.screenX,sy:e.screenY});
   if(pointers.size===2){
      const [p,q]=[...pointers.values()];
      pinch={d:Math.hypot(p.x-q.x,p.y-q.y),x:(p.x+q.x)/2,y:(p.y+q.y)/2};
      sphere.grab=null;sphere.spin.dragging=false;return;
   }
   if(pointers.size>2)return;
    // Cmd+left belongs to AppKit; Shift+Option resizes invisibly.
    // Plain drag rotates; Shift or right drag pans.
   sphere.grab={x:e.clientX,y:e.clientY,sx:e.screenX,sy:e.screenY,
      pan:e.button===2||(e.shiftKey&&!e.altKey),resize:embedded&&e.button===0&&e.altKey&&e.shiftKey,
      dx:0,dy:0,lastAt:performance.now(),speed:0};
   if(!sphere.grab.pan&&!sphere.grab.resize)sphere.spin.dragging=true;
});
canvas.addEventListener('pointermove',e=>{
   if(pointers.has(e.pointerId))pointers.set(e.pointerId,{x:e.clientX,y:e.clientY,sx:e.screenX,sy:e.screenY});
   if(pinch&&pointers.size>=2){
      const [p,q]=[...pointers.values()];
      const d=Math.hypot(p.x-q.x,p.y-q.y),mx=(p.x+q.x)/2,my=(p.y+q.y)/2;
      if(pinch.d>0&&d>0)sphere.zoomAt?.(...cssXY({clientX:mx,clientY:my}),d/pinch.d);
      pinch={d,x:mx,y:my};draw();request();return;
   }
   if(sphere.grab){
      const g=sphere.grab,dx=e.clientX-g.x,dy=e.clientY-g.y;
      if(g.resize){
          native?.postMessage({action:'resizeWindow',dx:Math.round(e.screenX-g.sx),dy:Math.round(e.screenY-g.sy)});
       }else if(g.pan)sphere.panBy?.(dx,dy);
      else{
         sphere.pose.yaw+=dx*.008;
         sphere.pose.pitch+=dy*.008;
         const now=performance.now(),elapsed=Math.max(12,now-g.lastAt);
         const instant=Math.min(.003,Math.hypot(dx,dy)*.008/elapsed);
         g.speed=g.speed ? g.speed*.45+instant*.55 : instant;
         g.dx+=dx;g.dy+=dy;g.lastAt=now;
      }
      sphere.grab={...g,x:e.clientX,y:e.clientY,sx:e.screenX,sy:e.screenY};
      draw();request();return;
   }
   if(!ready)return;
   const [x,y]=cssXY(e);
   const id=sphere.hits(x,y)?sphere.pick(x,y):null;
   if(sphere.hover!==id){sphere.hover=id;draw();request();}
});
const release=e=>{
   pointers.delete(e.pointerId);
   if(pointers.size<2)pinch=null;
   if(!pointers.size){
      const g=sphere.grab;
      if(g&&!g.pan&&!g.resize&&Math.hypot(g.dx,g.dy)>3){
         const magnitude=Math.hypot(g.dx,g.dy);
         sphere.spin.direction={x:g.dx/magnitude,y:g.dy/magnitude};
         const idleFor=performance.now()-g.lastAt;
         sphere.spin.speed=Math.max(.0000225,Math.min(.003,
            g.speed*Math.exp(-Math.max(0,idleFor-80)/175)));
      }
      sphere.spin.dragging=false;
      sphere.grab=null;
   }
};
canvas.addEventListener('pointerup',release);
canvas.addEventListener('pointercancel',release);
canvas.addEventListener('lostpointercapture',release);
canvas.addEventListener('pointerleave',()=>{
   if(!pointers.size&&sphere.hover!==null){sphere.hover=null;draw();request();}
});
new ResizeObserver(extent).observe(canvas);
document.addEventListener('visibilitychange',()=>{
   if(document.hidden){cancelAnimationFrame(frameID);frameID=0;clearTimeout(endTimer);clearTimeout(clockTimer);}
   else{updateClock();lastFrame=0;extent();}
});
reduced.addEventListener('change',()=>{clearTimeout(endTimer);draw();request();});
function snapshot() {
   return view?{phase:view.phase,focus:view.focus,sphereZ:view.sphereZ,sphereRadius:view.sphereRadius,
      activeEdges:view.activeEdges.map(({a,b})=>({a,b})),activeNodes:[...view.activeNodes],pulse:view.pulse,
      points:[...view.foreground].map(([id,p])=>({id,x:p.x,y:p.y,z:p.z,baseZ:p.baseZ??null,world:p.world??null})),
      signals:view.signals,volumePoints:view.volumePoints,ambientEdges:view.ambientEdges,
      camera:view.camera??null,hover:view.hover??null,graphEdges:view.graphEdges??sphere.graph.edges.length,
      backend:view.backend??'canvas2d',focalTranslation:view.focalTranslation??null,
      working:view.working,activity:view.activity,memoryPulse:view.memoryPulse,memoryAccessSequence:sphere.memoryAccessSequence,hit:sphere.hitArea(),
      shapeMorph:view.shapeMorph,adaptiveShape:view.adaptiveShape,motionSpeed:sphere.motionSpeed,comets:sphere.showComets,
      demo,reduced:view.reduced,graphNodes:sphere.graph.nodes.length,spin:{direction:sphere.spin.direction,speed:sphere.spin.speed,dragging:sphere.spin.dragging,yaw:sphere.pose.yaw,pitch:sphere.pose.pitch,angle:sphere.angle}}:
      {phase:'empty',focus:0,sphereZ:0,activeEdges:[],activeNodes:[],signals:[],volumePoints:0,ambientEdges:0,pulse:0,demo};
}
if(inspect)window.__atlasInspect={
   seek(ms){testing=true;cancelAnimationFrame(frameID);frameID=0;seekAge=Math.max(0,Number(ms)||0);draw();return snapshot();},
   state:snapshot,
   centerMetric(){
      const s=sphere.lastCamera;
      if(!s)return null;
      const a=AtlasSphere.projection({x:0,y:0,z:0},s);
      const dx=AtlasSphere.projection({x:.002,y:0,z:0},s);
      const dy=AtlasSphere.projection({x:0,y:.002,z:0},s);
      const sx=Math.abs(dx.x-a.x)/.002,sy=Math.abs(dy.y-a.y)/.002;
      return {x:sx,y:sy,ratio:sx/Math.max(.001,sy)};
   },
   geometry(){
      const s=sphere.lastCamera;
      if(!s)return null;
      const bounds={count:0,offscreen:0,invisible:0,minX:Infinity,maxX:-Infinity,
                    minY:Infinity,maxY:-Infinity,center:0,outer:0};
      for(const n of sphere.graph.nodes){
         const p=AtlasSphere.projection(AtlasSphere.cameraPoint(n,s),s);
         bounds.count++;
         if(!p.visible)bounds.invisible++;
         if(p.x<0||p.y<0||p.x>s.w||p.y>s.h)bounds.offscreen++;
         bounds.minX=Math.min(bounds.minX,p.x/s.w);
         bounds.maxX=Math.max(bounds.maxX,p.x/s.w);
         bounds.minY=Math.min(bounds.minY,p.y/s.h);
         bounds.maxY=Math.max(bounds.maxY,p.y/s.h);
         const r=Math.hypot((p.x/s.w-.5)/.47,(p.y/s.h-.5)/.44);
         if(r<.36)bounds.center++;
         if(r>.72)bounds.outer++;
      }
      return {...bounds,morph:s.shapeMorph,aspect:s.w/s.h};
   }
};
updateClock();sphere.resize();
if(window.__WIDGET_DATA)setData(window.__WIDGET_DATA);
else if(!embedded)setData(example(),true);
else setData({});
})();
