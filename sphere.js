/* One fixed 3D topology; the camera travels to the real links chosen in the trace. */
(() => {
'use strict';
const TAU = 2*Math.PI, HOME = 4.55, NEAR = .13, MEMORY_PULSE_MS = 800;
// Idle spin factor (task-94): only the accumulated idle angle is scaled; user drag writes pose.yaw and stays unscaled.
const IDLE_SPIN = .5;
const clamp = (x,a=0,b=1) => Math.max(a,Math.min(b,x));
const mix = (a,b,t) => a+(b-a)*t;
const smooth = t => { t=clamp(t); return t*t*(3-2*t); };
const idOf = v => ['string','number'].includes(typeof v) ? String(v) : null;
const end = e => [idOf(e?.a ?? e?.[0]),idOf(e?.b ?? e?.[1])];
const pairKey = (a,b) => JSON.stringify(a<b?[a,b]:[b,a]);
function hash(s) { let h=2166136261; for(let i=0;i<s.length;i++)h=Math.imul(h^s.charCodeAt(i),16777619); return h>>>0; }
function unit(n) {
   n=Math.imul(n^(n>>>16),0x45d9f3b); n=Math.imul(n^(n>>>16),0x45d9f3b);
   return ((n^(n>>>16))>>>0)/4294967296;
}
function anchor(seed) {
   const z=2*unit(seed^0xec359)-1, lon=TAU*unit(seed^0xff13), ring=Math.sqrt(1-z*z);
   const r=Math.cbrt(unit(seed^0xa744))*(.93+.12*unit(seed^0xab23f));
   return [r*ring*Math.cos(lon),r*ring*Math.sin(lon),r*z];
}
function addGraph(graph,payload={}) {
   const {nodes,byId,edges,byPair,adj}=graph;
   const added=[];let changed=false;
   for(const raw of payload.nodes||[]) {
      const id=idOf(raw?.id);if(!id||byId.has(id))continue;
      const seed=hash(id), p=anchor(seed);
      const n={id,g:raw.g||'core',w:clamp(Number(raw.w)||.30),p,seed,grain:unit(seed^0x913),i:nodes.length};
      nodes.push(n);byId.set(id,n);adj.set(id,[]);added.push(n);changed=true;
   }
   for(const raw of payload.edges||[]) {
      const [a,b]=end(raw), na=byId.get(a), nb=byId.get(b);
      if(!na||!nb||na===nb)continue;
      const k=pairKey(a,b);if(byPair.has(k))continue;
      const provenance=(na.g==='src'&&nb.g==='chunk')||(nb.g==='src'&&na.g==='chunk');
      const edge={a,b,k,na,nb,w:clamp(Number(raw.w??raw[2])||.25),provenance};
      byPair.set(k,edge);edges.push(edge);adj.get(a).push(edge);adj.get(b).push(edge);changed=true;
   }
   // Place each actual fragment in the volume around its own source, not in a global random bin.
   // The incoming trace may append new points; already placed points never get rearranged.
   for(const n of added) {
      if(n.g!=='chunk')continue;
      const relation=adj.get(n.id).find(e=>e.provenance);if(!relation)continue;
      const source=relation.a===n.id?relation.nb:relation.na;
      source.population??=adj.get(source.id).length;
      const density=smooth((Math.log2(source.population+1)-6)/8);
      source.radius??=mix(.088+.035*Math.log2(source.population+1),.94,density);
      n.origin=source;
      const p=anchor(n.seed^0x10d3c3), q=source.p;
      // A few huge sources contain tens of thousands of fragments. Give those families room
      // throughout the volume instead of piling them into opaque balls around the anchor.
      const raw=q.map((x,i)=>x*mix(.95,.30,density)+p[i]*source.radius);
      const len=Math.hypot(...raw), scale=len>1 ? (1+.035*Math.tanh((len-1)*4))/len : 1;
      n.p=raw.map(x=>x*scale);
   }
   return changed;
}
function buildGraph(payload={}) {
   const graph={nodes:[],byId:new Map(),edges:[],byPair:new Map(),adj:new Map()};addGraph(graph,payload);
   const core=graph.nodes.filter(n=>n.g==='core');
   if(core.length) {
      // A few tethered spring passes pull documented neighbours together while keeping a 3D spread.
      // Never run these passes on selection or replay: topology has one stable set of coordinates.
      const ties=graph.edges.filter(e=>e.na.g==='core'&&e.nb.g==='core');
      const starting=core.map(n=>n.p.slice()), forces=new Float32Array(graph.nodes.length*3);
      for(let step=0;step<18;step++) {
         forces.fill(0);
         for(const {na,nb,w} of ties) {
            const ax=na.p[0]-nb.p[0],ay=na.p[1]-nb.p[1],az=na.p[2]-nb.p[2],d=Math.hypot(ax,ay,az)||1;
            const f=.22*(d-.24)/d*(.44+.56*Math.sqrt(w)), li=na.i*3, ri=nb.i*3;
            forces[li]-=f*ax;forces[li+1]-=f*ay;forces[li+2]-=f*az;
            forces[ri]+=f*ax;forces[ri+1]+=f*ay;forces[ri+2]+=f*az;
         }
         core.forEach((n,i)=>{
            const pull=1/Math.sqrt(1+graph.adj.get(n.id).length),base=starting[i];
            for(let k=0;k<3;k++)n.p[k]+=.49*forces[n.i*3+k]*pull+.12*(base[k]-n.p[k]);
         });
      }
   }
   return graph;
}
function focusOf(trace={},graph) {
   const edges=[],ids=new Set(),keys=new Set();
   for(const item of trace.focusEdges||[]) {
      const [a,b]=end(item),k=pairKey(a,b),e=graph.byPair.get(k);
      // The trace may activate a real edge; it cannot invent geometry by naming two real nodes.
      if(!e||keys.has(k))continue;
      keys.add(k);ids.add(a);ids.add(b);edges.push({a,b,k});
   }
   return {edges,ids:[...ids],set:ids,keys,ts:trace.ts||''};
}
function envelope(age) { return age<=0?0:age<1100?smooth(age/1100):age<=6900?1:1-smooth((age-6900)/1850); }
function phase(age,on) { return !on||age<=0||age>=8750?'idle':age<1100?'depart':age<=6900?'focus':'return'; }
function packet(age) { return (1-Math.cos(TAU*Math.max(0,age-270)/3000))/2; }
function sprite(stops) {
   const el=document.createElement('canvas');el.width=el.height=96;
   const c=el.getContext('2d'),g=c.createRadialGradient(48,48,0,48,48,48);
   for(const [at,color] of stops)g.addColorStop(at,color);c.fillStyle=g;c.fillRect(0,0,96,96);return el;
}
function glow(c,im,p,r) { c.drawImage(im,p.x-r,p.y-r,2*r,2*r); }
const CORE_PALETTE=[[.19,.43,1],[.27,.51,.98],[.31,.64,1],[.43,.45,.98]];
const LARGE_CORE=[.68,.50,1];
function coreSize(n) { return .83+n.grain*.91+.32*Math.sqrt(n.w); }
function coreHue(n) { return Math.min(CORE_PALETTE.length-1,Math.floor(unit(n.seed^0x7b93)*CORE_PALETTE.length)); }
function nodeGroup(n) {
   if(n.g==='src')return 8;
   if(n.g==='chunk') { const family=(n.origin?.seed??n.seed)%11;return family<=1?1:family<=3?2:0; }
   return coreSize(n)>1.82?7:3+coreHue(n);
}
function tone(n) {
   if(n.g==='src')return [.82,.85,1,2.0+n.grain*.65];
   if(n.g==='chunk') {
      const family=(n.origin?.seed??n.seed)%11;
      const size=mix(.53,.39,smooth((Math.log2((n.origin?.population||1)+1)-6)/8))+n.grain*.26;
      if(family<=1)return [.92,.76,.44,size];
      if(family<=3)return [.69,.61,.98,size];
      return [.66,.77,1,size];
   }
   const size=coreSize(n),color=size>1.82?LARGE_CORE:CORE_PALETTE[coreHue(n)];
   return [...color,size];
}
function edgeTone(e,graph) {
   const degree=Math.max(graph.adj.get(e.a).length,graph.adj.get(e.b).length);
   return e.provenance?[.43,.36,.73,clamp(.065/Math.pow(degree,.32),.0024,.033)]
      :[.41,.39,.77,clamp(.22/Math.pow(degree,.23),.037,.14)*( .77+.3*Math.sqrt(e.w))];
}

// Large graph stays on the GPU, with one point per node and one line segment per real edge.
// Flags are changed only when inspection or an actual selection changes.
class VolumeGL {
   constructor(before) {
      const el=document.createElement('canvas');
      el.className='atlas-volume';el.setAttribute('aria-hidden','true');
      el.style.cssText='position:absolute;inset:0;width:100%;height:100%;display:block;pointer-events:none';
      const gl=el.getContext('webgl',{alpha:true,antialias:true,premultipliedAlpha:true,depth:false});
      if(!gl)throw new Error('WebGL unavailable');
      const vertex=`
      attribute vec3 pos; attribute vec4 prop; attribute vec3 flags;
      uniform vec4 rot; uniform vec2 pan,focal,stretch;
      uniform float camera, focus, ratio, isPoint, zoom, activity, sparse, morph, idleLineWeight;
      varying vec3 ink; varying float opacity, isDot, rim;
      float fitBound(float v,float shoulder,float boundary) {
         float d=abs(v);
         if(d<=shoulder)return v;
         float k=exp(-2.0*(d-shoulder)/(boundary-shoulder));
         return sign(v)*(shoulder+(boundary-shoulder)*(1.0-k)/(1.0+k));
      }
      void main(){
        float x=pos.x*rot.x+pos.z*rot.y, z=pos.z*rot.x-pos.x*rot.y;
        float y=pos.y*rot.z-z*rot.w;
        float depth=pos.y*rot.w+z*rot.z;
        float originalDepth=camera-depth;
        vec2 sphereScreen=vec2(x+pan.x,y+pan.y)*focal/max(0.13,originalDepth);
        // The same sphere, fitted to the ultrawide viewport when enabled.
        float fitDepth=max(.85,originalDepth);
        // Central ~55% of the spherical cloud uses identical x/y scale.
        // Only projected peripheral vertices gradually gain horizontal span.
        float radius=length(vec2(x,y));
        float lateral=mix(stretch.y,stretch.x,smoothstep(.43,.94,radius));
        vec2 adapted=vec2((x+pan.x)*lateral,(y+pan.y)*stretch.y)*focal/fitDepth;
        vec2 bounded=vec2(fitBound(adapted.x,.64,.9985),
                          fitBound(adapted.y,.64,.997));
        // morph=0 MUST reproduce the original unbounded projection.
        vec2 screen=mix(sphereScreen,bounded,morph);
        // Near the end of the morph, a few perspective vertices can still
        // overshoot; finish the fit without affecting the original sphere.
        float edgeFinish=smoothstep(.14,.42,morph);
        screen=mix(screen,clamp(screen,vec2(-.9985,-.997),vec2(.9985,.997)),edgeFinish);
        float w=mix(originalDepth,fitDepth,morph);
        if(morph>.001)w=max(.20,w);
        gl_Position=vec4(screen*w,w-0.26,w);
        float dim=(1.0-.44*focus);
        float front=clamp(.54+.4*depth,.18,1.0);
        float picked=smoothstep(.0,.38,focus)*flags.x;
        float tint=clamp(flags.z,0.,1.);
        ink=min(prop.rgb*(1.48+.42*activity),vec3(1.0));
        ink=mix(ink,vec3(.76,.62,1.),tint*.8);
        isDot=isPoint;
        rim=0.;
        if(isPoint>.5){
           float scale=clamp(4.55/max(.19,w),.55,3.75);
           gl_PointSize=max(1.5,ratio*clamp(prop.w*scale*1.84,.92,14.0));
           float dust=1.0-flags.y*(1.0-min(.90,.66+.07*zoom));
           float sizeClass=smoothstep(1.18,1.82,prop.w);
           opacity=(.68+.18*sizeClass+.16*activity)*(.70+.30*front)*dim*(1.0-picked)*dust;
           opacity=mix(opacity,(.88+.12*front)*(1.0-picked),tint);
           rim=smoothstep(1.68,1.98,prop.w);
        } else {
           float local=mix(dim,1.0,flags.x*focus*.65);
           opacity=prop.w*local*(.81+.19*front)*min(1.8,1.18+.2*zoom);
           opacity=mix(opacity,.56*dim,tint);
           opacity*=1.0-smoothstep(.0,.24,focus)*flags.y;
           // Experimental points-only universe: only actual highlighted
           // paths or hovered adjacencies may appear in the 3D edge layer.
           float activeLine=clamp(flags.y*smoothstep(.01,.12,focus)+flags.z,0.0,1.0);
           opacity*=mix(1.0,activeLine,sparse);
           // WebGL1 commonly clamps gl.LINES to 1 physical pixel.
           // Half alpha is the portable equivalent of half pixel coverage,
           // applied ONLY to ambient edges; highlighted paths stay bright.
           opacity*=mix(idleLineWeight,1.0,activeLine);
        }
      }`;
      const fragment=`
       precision mediump float;
       uniform float memoryPulse;
       varying vec3 ink; varying float opacity,isDot,rim;
       void main(){
          if(isDot>.5){
             float d=length(gl_PointCoord-vec2(.5))*2.0;
             if(d>1.0)discard;
             float core=1.0-smoothstep(.08,.31,d);
             float halo=1.0-smoothstep(.22,1.0,d);
             vec3 edge=mix(ink*.94,vec3(.12,.15,.30),rim);
             vec3 base=mix(edge,ink,1.0-smoothstep(.42,.82,d));
             vec3 hot=min(ink*1.95+vec3(.03,.04,.11),vec3(1.0));
             vec3 color=mix(base,hot,core);
              float flash=clamp(memoryPulse,0.0,4.0);
              vec3 flashBlue=mix(vec3(.16,.38,.98),vec3(.58,.40,1.0),clamp(ink.r*.72,0.0,1.0));
              color=min(color+flashBlue*(.14*flash*halo+.17*flash*core),vec3(1.0));
             float alpha=clamp(opacity*(.28*halo+.98*core)+flash*(.10*halo+.12*core),0.0,.96);
             gl_FragColor=vec4(color,alpha);
          }else gl_FragColor=vec4(ink,opacity);
       }`;
      const shader=(type,src)=>{
         const s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);
         if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s;
      };
      const program=gl.createProgram();gl.attachShader(program,shader(gl.VERTEX_SHADER,vertex));
      gl.attachShader(program,shader(gl.FRAGMENT_SHADER,fragment));gl.linkProgram(program);
      if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(program));
      this.gl=gl;this.el=el;this.program=program;
      this.vertex=gl.createBuffer();this.lines=gl.createBuffer();this.vFlags=gl.createBuffer();this.lFlags=gl.createBuffer();
      this.loc=Object.fromEntries(['rot','pan','focal','stretch','camera','focus','ratio','isPoint','zoom','activity','memoryPulse','sparse','morph','idleLineWeight'].map(k=>[k,gl.getUniformLocation(program,k)]));
      this.attr=Object.fromEntries(['pos','prop','flags'].map(k=>[k,gl.getAttribLocation(program,k)]));
      before.before(el);
      el.addEventListener('webglcontextlost',e=>{e.preventDefault();this.lost=true;el.hidden=true;});
      el.addEventListener('webglcontextrestored',()=>{this.lost=true;});
   }
   draw(graph,focal,hover,s,w,h,dpr,showIdleLines=true) {
      const gl=this.gl,l=this.loc, a=this.attr;
      if(this.lost)return false;
      const dirty=this.graph!==graph||this.count!==graph.nodes.length||this.linkCount!==graph.edges.length;
      const bind=(type,buf,arr)=>{gl.bindBuffer(gl.ARRAY_BUFFER,buf);gl.bufferData(gl.ARRAY_BUFFER,arr,type);};
      if(dirty) {
         const points=new Float32Array(graph.nodes.length*7),links=new Float32Array(graph.edges.length*14);
         graph.nodes.forEach((n,i)=>{
            points.set(n.p,i*7);points.set(tone(n),i*7+3);
         });
         graph.edges.forEach((e,i)=>{
            const t=edgeTone(e,graph);
            links.set(e.na.p,i*14);links.set(t,i*14+3);
            links.set(e.nb.p,i*14+7);links.set(t,i*14+10);
         });
         bind(gl.STATIC_DRAW,this.vertex,points);bind(gl.STATIC_DRAW,this.lines,links);
         this.count=graph.nodes.length;this.linkCount=graph.edges.length;this.graph=graph;
      }
      if(dirty||this.focus!==focal||this.hover!==hover) {
         const v=new Float32Array(graph.nodes.length*3),e=new Float32Array(graph.edges.length*6);
         const near=new Set(), nearEdges=new Set();
         for(const x of graph.adj.get(hover)||[]){near.add(x.a);near.add(x.b);nearEdges.add(x.k);}
         graph.nodes.forEach((n,i)=>{
            v[i*3]=focal.set.has(n.id)?1:0;
            v[i*3+1]=n.g==='chunk'? .53+.47*smooth((Math.log2((n.origin?.population||1)+1)-6)/8) :0;
            v[i*3+2]=near.has(n.id)||n.id===hover?1:0;
         });
         graph.edges.forEach((x,i)=>{
            const p=i*6, hot=focal.keys.has(x.k)?1:0;
            const bright=nearEdges.has(x.k)?clamp(1/Math.sqrt(1+nearEdges.size/120),.15,1):0;
            const around=focal.set.has(x.a)||focal.set.has(x.b)?1:0;
            e[p]=around;e[p+1]=hot;e[p+2]=bright;
            e[p+3]=around;e[p+4]=hot;e[p+5]=bright;
         });
         bind(gl.DYNAMIC_DRAW,this.vFlags,v);bind(gl.DYNAMIC_DRAW,this.lFlags,e);this.focus=focal;this.hover=hover;
      }
      const pixelW=Math.round(w*dpr),pixelH=Math.round(h*dpr);
      if(this.el.width!==pixelW||this.el.height!==pixelH){this.el.width=pixelW;this.el.height=pixelH;}
      gl.viewport(0,0,pixelW,pixelH);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.BLEND);gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
      gl.useProgram(this.program);gl.uniform4f(l.rot,s.cy,s.sy,s.cx,s.sx);
      gl.uniform2f(l.pan,s.panX,s.panY);gl.uniform2f(l.focal,2*s.eye/w,2*s.eye/h);
      gl.uniform1f(l.camera,s.distance);
      gl.uniform1f(l.focus,s.f);gl.uniform1f(l.ratio,dpr);gl.uniform1f(l.zoom,HOME/s.distance);
      gl.uniform1f(l.activity,s.activity);gl.uniform1f(l.memoryPulse,s.memoryPulse);
      gl.uniform1f(l.sparse,showIdleLines?0:1);
      gl.uniform1f(l.idleLineWeight,showIdleLines?.50:1.0);
      gl.uniform1f(l.morph,s.shapeMorph||0);
      gl.uniform2f(l.stretch,s.shapeStretchX||1,s.shapeStretchY||1);
      const use=(buf,flags)=>{
         gl.bindBuffer(gl.ARRAY_BUFFER,buf);gl.enableVertexAttribArray(a.pos);gl.vertexAttribPointer(a.pos,3,gl.FLOAT,false,28,0);
         gl.enableVertexAttribArray(a.prop);gl.vertexAttribPointer(a.prop,4,gl.FLOAT,false,28,12);
         gl.bindBuffer(gl.ARRAY_BUFFER,flags);gl.enableVertexAttribArray(a.flags);gl.vertexAttribPointer(a.flags,3,gl.FLOAT,false,0,0);
      };
      // Skip the whole 52k-edge draw call at rest in sparse mode.
      if(showIdleLines || (s.f>.008 && focal.edges.length) || hover){
         gl.uniform1f(l.isPoint,0);use(this.lines,this.lFlags);gl.drawArrays(gl.LINES,0,this.linkCount*2);
      }
      gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
       gl.uniform1f(l.isPoint,1);use(this.vertex,this.vFlags);gl.drawArrays(gl.POINTS,0,this.count);
      return true;
   }
}

function rotatePoint(p,s) {
   const x=p[0]*s.cy+p[2]*s.sy,z=p[2]*s.cy-p[0]*s.sy;
   return {x,y:p[1]*s.cx-z*s.sx,z:p[1]*s.sx+z*s.cx};
}
function cameraPoint(n,s) {
   return rotatePoint(n.p,s);
}
// A monotonic soft wall: identity in the centre, smooth compression at the
// viewport boundary. A projected point can approach but never cross it.
function softWall(v,shoulder,boundary) {
   const d=Math.abs(v);
   if(d<=shoulder)return v;
   const u=(d-shoulder)/(boundary-shoulder);
   return Math.sign(v)*(shoulder+(boundary-shoulder)*Math.tanh(u));
}
function projection(p,s) {
   const d=s.distance-p.z,oldDepth=Math.max(NEAR,d);
   const originalX=(p.x+s.panX)*2*s.eye/(s.w*oldDepth);
   const originalY=(p.y+s.panY)*2*s.eye/(s.h*oldDepth);
   const morph=s.shapeMorph||0;
   // Full torus coordinates are in screen-relative units. On an ultrawide
   // monitor the ring can use the full width without exceeding its height.
   const fitDepth=Math.max(.85,d);
   const radial=Math.hypot(p.x,p.y);
   const lateral=mix(s.shapeStretchY||1,s.shapeStretchX||1,smooth((radial-.43)/.51));
   const fittedX=((p.x+s.panX)*2*s.eye/(s.w*fitDepth))*lateral;
   const fittedY=((p.y+s.panY)*2*s.eye/(s.h*fitDepth))*(s.shapeStretchY||1);
   // When disabled, the old sphere must project unchanged, even offscreen.
   const rawX=mix(originalX,softWall(fittedX,.64,.9985),morph);
   const rawY=mix(originalY,softWall(fittedY,.64,.997),morph);
   const edgeFinish=smooth((morph-.14)/.28);
   const ndcX=mix(rawX,clamp(rawX,-.9985,.9985),edgeFinish);
   const ndcY=mix(rawY,clamp(rawY,-.997,.997),edgeFinish);
   const depth=mix(d,fitDepth,morph);
   return {x:s.w*(1+ndcX)/2,y:s.h*(1-ndcY)/2,z:p.z,
      k:s.eye/Math.max(NEAR,depth),visible:depth>=NEAR,
      ndcX,ndcY};
}
function lerpPoint(a,b,t) {
   return {x:mix(a.x,b.x,t),y:mix(a.y,b.y,t),z:mix(a.z,b.z,t),
           tx:mix(a.tx??a.x,b.tx??b.x,t),
           ty:mix(a.ty??a.y,b.ty??b.y,t),
           tz:mix(a.tz??a.z,b.tz??b.z,t)};
}
function screenEdge(a,b,s) {
   if((s.shapeMorph||0)>.68) {
      const p=projection(a,s),q=projection(b,s);
      return [p,q]; // actual sphere endpoints fitted to viewport
   }
   const z=s.distance-NEAR;
   if(a.z>z && b.z>z)return null;
   if(a.z>z)a=lerpPoint(a,b,(a.z-z)/(a.z-b.z));
   if(b.z>z)b=lerpPoint(b,a,(b.z-z)/(b.z-a.z));
   const p=projection(a,s),q=projection(b,s);
   if((p.x<0&&q.x<0)||(p.y<0&&q.y<0)||(p.x>s.w&&q.x>s.w)||(p.y>s.h&&q.y>s.h))return null;
   return [p,q];
}
function stroke(c,p,q) { c.beginPath();c.moveTo(p.x,p.y);c.lineTo(q.x,q.y);c.stroke(); }
class Sphere {
   constructor(canvas,{compact=false}={}) {
      this.el=canvas;this.c=canvas.getContext('2d');this.graph=buildGraph();this.focus=focusOf({},this.graph);
      this.pose={yaw:0,pitch:0};this.angle=0;this.grab=null;this.hover=null;
      this.spin={direction:null,speed:0,dragging:false};
      this.motionSpeed=1; // slider: 0 freezes auto rotation, drag unchanged
      this.camera={distance:HOME,panX:0,panY:0};this.manualOverride=false;this.compact=compact;
      this.working=false;this.workStarted=0;this.traceMode='replay';this.returning=null;
      this.showIdleLines=false; // reversible visual experiment; graph edges remain intact
      this.showContinuousWorkLines=false; // default pulse-only while Harness runs
      this.adaptiveShape=true; // viewport fit of ORIGINAL sphere
      this.shapeMorph=0;this.shapeStamp=null;
      this.activeActorID=null; // verified active session ID from native DSH read-only state
       this.memoryAccesses=[];this.memoryAccessSequence=0;
      this.traceState='called';
      this.sky=sprite([[0,'#effbff'],[.15,'#9bdfff'],[.36,'rgba(78,165,255,.62)'],[1,'rgba(70,126,255,0)']]);
      this.red=sprite([[0,'#ffded3'],[.12,'#ff9d9a'],[.24,'rgba(248,76,93,.84)'],[.49,'rgba(228,36,78,.22)'],[1,'rgba(228,36,78,0)']]);
      this.gold=sprite([[0,'#fffce8'],[.23,'#ffe785'],[.45,'rgba(255,195,65,.59)'],[1,'rgba(255,182,49,0)']]);
      try{this.gpu=new VolumeGL(canvas);}catch(_){this.gpu=null;}
   }
   setData(payload){
       this.graph=buildGraph(payload||{});
       if(!this.graph.byId.has(this.hover))this.hover=null;
       // Actual native session/state running flag illuminates a stable DSH
       // presence path even while the model has not called any tools yet.
       this.harnessWorkFocus=focusOf({focusEdges:[
          ['d-reader','d-deepseek-harness'],
          ['d-deepseek-harness','d-harness-active'],
          ['d-deepseek-harness','d-team-activity']
       ]},this.graph);
    }
   mergeData(delta){return addGraph(this.graph,delta);}
   setTrace(trace,now,mode='replay'){
      this.focus=focusOf(trace||{},this.graph);this.started=now;this.traceMode=mode;this.returning=null;
      this.traceState=['called','returned','error'].includes(trace?.eventState) ? trace.eventState : 'called';
      const c=this.lastCamera;
      this.fromCamera=c?.automatic?{distance:c.distance,panX:c.panX,panY:c.panY}:null;
      this.manualOverride=false;
   }
   setActivity(active,now){
      if(this.working===active)return;
      this.working=active;
      if(active) this.workStarted=now;
      // End the visible work indicator immediately. Only the unlit camera eases home.
      if(!active&&this.traceMode==='live'){
         const c=this.lastCamera;
         if(c?.automatic&&!this.manualOverride)
            this.returning={at:now,distance:c.distance,panX:c.panX,panY:c.panY};
         this.focus=focusOf({},this.graph);
      }
   }
   handoffActivity(now){
      this.setActivity(false,now);
      this.setActivity(true,now);
   }
   memoryAccess(now){
       const at=Number.isFinite(now)?now:performance.now();
       this.memoryAccesses=this.memoryAccesses.filter(t=>at>=t&&at-t<MEMORY_PULSE_MS);
       this.memoryAccesses.push(at);
       if(this.memoryAccesses.length>4)this.memoryAccesses.shift();
       return ++this.memoryAccessSequence;
    }
    memoryPulseLevel(now,reduced=false){
       this.memoryAccesses=this.memoryAccesses.filter(t=>now>=t&&now-t<MEMORY_PULSE_MS);
       let level=0;
       for(const t of this.memoryAccesses)level+=reduced?1:1-(now-t)/MEMORY_PULSE_MS;
       return clamp(level,0,4);
    }
    hitArea(){
      const s=this.lastCamera;if(!s)return null;
      const ordinary=Math.min(Math.hypot(s.w,s.h),s.eye/Math.sqrt(Math.max(.48,s.distance*s.distance-1.03)))*1.035;
      const ring=Math.hypot(.48*s.w,.45*s.h);
      const radius=mix(ordinary,ring,s.shapeMorph||0);
      const morph=s.shapeMorph||0;
      return {x:mix(s.w*.5+s.panX*s.eye/s.distance,s.w*.5,morph),
              y:mix(s.h*.5-s.panY*s.eye/s.distance,s.h*.5,morph),r:radius};
   }
   hits(x,y){
      const a=this.hitArea();return !!a&&Math.hypot(x-a.x,y-a.y)<=a.r+4;
   }
   resize(){
      const r=this.el.getBoundingClientRect(),dpr=Math.min(devicePixelRatio||1,2);
      this.w=Math.max(1,r.width);this.h=Math.max(1,r.height);this.dpr=dpr;
      const w=Math.round(this.w*dpr),h=Math.round(this.h*dpr);
      if(this.el.width!==w||this.el.height!==h){this.el.width=w;this.el.height=h;}
      this.c.setTransform(dpr,0,0,dpr,0,0);
   }
   resetCamera(){
      this.manualOverride=true;this.camera={distance:HOME,panX:0,panY:0};
      this.pose={yaw:0,pitch:0};this.angle=0;
      this.spin={direction:null,speed:0,dragging:false};
   }
   takeCamera(){
      if(!this.manualOverride&&this.lastCamera?.automatic){
         const {distance,panX,panY}=this.lastCamera;this.camera={distance,panX,panY};
      }
      this.manualOverride=true;
   }
   panBy(dx,dy){
      if(!this.w||!this.h)return;
      this.takeCamera();
      const eye=this.lastCamera?.eye||this.eye(),k=this.camera.distance/eye;
      this.camera.panX=clamp(this.camera.panX+dx*k,-6,6);this.camera.panY=clamp(this.camera.panY-dy*k,-6,6);
   }
   zoomAt(x,y,factor){
      if(!Number.isFinite(factor)||factor<=0||!this.w||!this.h)return;
      this.takeCamera();
      const old=this.camera.distance,next=clamp(old/factor,.46,14);
      const eye=this.lastCamera?.eye||this.eye();
      // Anchor the lens ray at the pointer; allow the camera to pass the front of the cloud.
      this.camera.panX=clamp(this.camera.panX+(x-this.w/2)*(next-old)/eye,-6,6);
      this.camera.panY=clamp(this.camera.panY-(y-this.h/2)*(next-old)/eye,-6,6);
      this.camera.distance=next;
   }
   pick(x,y){
      const s=this.lastCamera;if(!s)return null;
      let winner=null,best=43;
      for(const n of this.graph.nodes) {
         const world=cameraPoint(n,s),a=projection(world,s);
         if(!a.visible)continue;
         const d=Math.max(NEAR,mix(s.distance-world.z,Math.max(.85,s.distance-world.z),s.shapeMorph||0));
         const dx=a.x-x,dy=a.y-y;
         const score=dx*dx+dy*dy-(n.g==='src'?12:n.g==='core'?5:0)-Math.min(5,2/d);
         if(score<best){winner=n.id;best=score;}
      }
      return winner;
   }
   renderFallback(s,focusData=this.focus){
       const c=this.c,hoverEdges=new Set((this.graph.adj.get(this.hover)||[]).map(e=>e.k));
       const xy=this.graph.nodes.map(n=>cameraPoint(n,s));
       c.save();c.lineWidth=this.showIdleLines?.36:.72;
       const edgeIdle=['#584c9f','#5e55b4','#8374dd'],edgeLive=['#6264c9','#6d80ed','#a499fb'];
       for(let group=0;group<3;group++){
          c.beginPath();
          for(const e of this.graph.edges){
             if(!this.showIdleLines && !hoverEdges.has(e.k))continue;
             if(this.showIdleLines&&s.f>.10&&focusData.keys.has(e.k))continue;
             const h=hoverEdges.has(e.k);
             if((h?2:e.provenance?0:1)!==group)continue;
             const line=screenEdge(xy[e.na.i],xy[e.nb.i],s);if(!line)continue;
             c.moveTo(line[0].x,line[0].y);c.lineTo(line[1].x,line[1].y);
          }
          c.globalAlpha=(1-.50*s.f)*[.043,.20,.66][group];
          c.lineWidth=this.showIdleLines&&group!==2?.36:.72;
          c.strokeStyle=(s.activity?edgeLive:edgeIdle)[group];c.stroke();
       }
       const tints=[[168,193,255],[247,199,120],[181,155,255],
          ...CORE_PALETTE.map(rgb=>rgb.map(v=>Math.round(v*255))),[179,132,255],[220,230,255]];
       const memoryPulse=clamp(s.memoryPulse||0,0,4),memoryTint=Math.min(.62,.15*memoryPulse);
       for(let group=0;group<tints.length;group++){
          const boost=1+.28*s.activity;
          c.fillStyle=`rgb(${tints[group].map((v,i)=>Math.round(mix(Math.min(255,v*boost),[72,90,255][i],memoryTint))).join(' ')})`;
          const baseAlpha=group<=2?[.58,.62,.58][group]:group===7?.84:group===8?.88:.50;
          c.globalAlpha=(1-.44*s.f)*clamp(baseAlpha+.14*s.activity+.07*memoryPulse,0,1);c.beginPath();
          for(const n of this.graph.nodes){
             if(this.focus.set.has(n.id)&&s.f>.13)continue;
             if(nodeGroup(n)!==group)continue;
             const p=projection(xy[n.i],s);
             if(!p.visible||p.x<0||p.y<0||p.x>s.w||p.y>s.h)continue;
             const renderDepth=mix(s.distance-p.z,Math.max(.85,s.distance-p.z),s.shapeMorph||0);
             const r=clamp(tone(n)[3]*.38*HOME/Math.max(NEAR,renderDepth),.30,4.2);
             c.moveTo(p.x+r,p.y);c.arc(p.x,p.y,r,0,TAU);
          }
          if(group===7){c.strokeStyle='#313057';c.lineWidth=.42;c.stroke();}
          c.fill();
       }
       c.restore();
    }
   diveTarget(s) {
      const points=this.focus.ids.map(id=>cameraPoint(this.graph.byId.get(id),s));
      if(!points.length)return this.camera;
      const center={x:0,y:0,z:0};
      for(const p of points){center.x+=p.x;center.y+=p.y;center.z+=p.z;}
      for(const k of ['x','y','z'])center[k]/=points.length;
      // Frame this existing part of the graph. Only the lens moves; peripheral stars may
      // pass behind the near plane, but all selected endpoints stay ahead of it.
      let fit=.46;
      for(const p of points){
         const pad=Math.max(s.eye*Math.abs(p.x-center.x)/(s.w*.36),s.eye*Math.abs(p.y-center.y)/(s.h*.35),.33);
         fit=Math.max(fit,p.z+pad);
      }
      const distance=Math.max(fit,center.z+.91);
      return {distance,panX:-center.x,panY:-center.y};
   }
   eye(){return (this.compact?Math.min(this.w,this.h)*.43:Math.min(this.w*.365,this.h*.44))*HOME;}
   render(now,{reduced=false,seek=false,ageOverride,angle}={}) {
      const c=this.c,w=this.w,h=this.h;if(!c||!w||!h)return null;
      c.clearRect(0,0,w,h);
      if(!this.graph.nodes.length){this.lastView=null;return null;}
      const age=ageOverride??(now-(this.started??now)),chosen=this.focus.edges.length>0;
      const liveWindow=this.traceMode==='live'&&(this.showContinuousWorkLines?this.working:age<8750);
      const linked=chosen&&liveWindow;
      const replay=chosen&&this.traceMode==='replay';
      // Concrete events fade after ~9s in pulse mode; never lock their paths
      // to a long-running model's "running" status.
      const replayFocus=linked?(this.showContinuousWorkLines?(reduced?1:smooth(age/900)):(reduced?(age<8750?1:0):envelope(age))):
                           (replay?(reduced?(age<8750?1:0):envelope(age)):0);
      const steadyWork=this.showContinuousWorkLines&&this.working&&replayFocus<.03&&
                       (this.harnessWorkFocus?.edges.length||0)>0;
      const focusData=steadyWork?this.harnessWorkFocus:this.focus;
      // Continuous work paths only in the optional legacy visualization.
      const f=steadyWork?(reduced?.7:.55):replayFocus;
      const workAge=ageOverride??(now-this.workStarted);
      const activity=this.working?(reduced?.78:.72+.18*Math.cos(TAU*workAge/2050)):0;
       const memoryPulse=this.memoryPulseLevel(now,reduced);
      const yaw=.46+(angle??this.angle)*IDLE_SPIN+this.pose.yaw,pitch=-.23+this.pose.pitch;
      const s={...this.camera,w,h,f,activity,memoryPulse,eye:this.eye(),
               cy:Math.cos(yaw),sy:Math.sin(yaw),cx:Math.cos(pitch),sx:Math.sin(pitch),automatic:false};
      const wide=smooth((w/h-1.25)/1.20);
      const apparent=s.eye/(Math.max(.4,s.distance)*h);
      // Let the small sphere grow naturally first; warp only when it
      // approaches the upper/lower frame of the ultrawide display.
      const expansion=smooth((apparent-.50)/.29);
      const targetMorph=this.adaptiveShape?wide*expansion:0;
      const elapsed=this.shapeStamp===null?1000:clamp(now-this.shapeStamp,0,1000);
      this.shapeStamp=now;
      this.shapeMorph=mix(this.shapeMorph,targetMorph,clamp(elapsed/290));
      if(Math.abs(this.shapeMorph-targetMorph)<.0001)this.shapeMorph=targetMorph;
      s.shapeMorph=this.shapeMorph;
      // Central isotropic metric, horizontal expansion of outer shell only.
      s.shapeStretchX=clamp((w/h)/1.02,1,4.5);
      s.shapeStretchY=1.12;
      if(!reduced&&!this.manualOverride) {
         if(f>0&&!steadyWork&&s.shapeMorph<.38){
            const target=this.diveTarget(s), home=this.camera;
            const handoff=!seek&&this.fromCamera&&age<900;
            const from=handoff?this.fromCamera:home,t=handoff?smooth(age/900):f;
            if(this.compact){
               // Native overview is already close to the window edge. A modest lens move
               // brings attention to the real region without taking over the desktop.
               target.distance=Math.max(target.distance,home.distance*.87);
               const reach=.23*home.distance/HOME;
               target.panX=home.panX+clamp(target.panX-home.panX,-reach,reach);
               target.panY=home.panY+clamp(target.panY-home.panY,-reach,reach);
            }
            s.distance=mix(from.distance,Math.min(target.distance,home.distance),t);
            s.panX=mix(from.panX,target.panX,t);s.panY=mix(from.panY,target.panY,t);s.automatic=true;
         }else if(this.returning){
            const r=this.returning,t=smooth((now-r.at)/570);
            s.distance=mix(r.distance,this.camera.distance,t);
            s.panX=mix(r.panX,this.camera.panX,t);s.panY=mix(r.panY,this.camera.panY,t);
            if(t>=1)this.returning=null;
         }
      }
      this.lastCamera=s;
      const gpuDraw=!!this.gpu?.draw(this.graph,focusData,this.hover,s,w,h,this.dpr,this.showIdleLines);
      if(!gpuDraw)this.renderFallback(s,focusData);
      const edges=focusData.edges,world=new Map(),foreground=new Map(),signals=[],beats=new Map();
      for(const id of focusData.ids){
         const n=this.graph.byId.get(id),p=cameraPoint(n,s),a=projection(p,s);world.set(id,p);
         foreground.set(id,{...a,baseX:a.x,baseY:a.y,baseZ:p.z,world:[...n.p]});
      }
      const pulse=reduced?.53:packet(age),emit=smooth(f*1.38);
      if((chosen||steadyWork)&&emit>.008){
         c.save();c.lineCap='round';
         edges.forEach((e,i)=>{
            const src=this.graph.byId.get(e.b).g==='src'&&this.graph.byId.get(e.a).g!=='src'?e.b:e.a;
            const leaf=src===e.a?e.b:e.a,a=world.get(src),b=world.get(leaf),line=screenEdge(a,b,s);if(!line)return;
            // The illuminated stroke is the very same projected segment as the normal graph edge.
            c.globalAlpha=emit*.68;c.strokeStyle=this.traceState==='error'?'#ff7b94':this.traceState==='returned'?'#e6bd78':'#86b5ff';c.lineWidth=.76;stroke(c,...line);
            const t=Math.max(0,age-270-(i%5)*120),progress=reduced?.53:packet(t+270);
            const dir=reduced?0:Math.sin(TAU*t/3000)<0?-1:1,head=projection(lerpPoint(a,b,progress),s);
            if(head.visible) {
               c.globalCompositeOperation='lighter';
               for(let j=8;j>=0;j--){
                  const d0=clamp(progress-dir*(j+1)*.019),d1=clamp(progress-dir*j*.019);
                  if(d1===d0)continue;const x=projection(lerpPoint(a,b,d0),s),y=projection(lerpPoint(a,b,d1),s);
                  if(!x.visible||!y.visible)continue;
                  c.globalAlpha=emit*.55*(1-j/10);c.strokeStyle=this.traceState==='error'?'#ff728e':this.traceState==='returned'?'#ffcb65':'#82caff';c.lineWidth=1.33;stroke(c,x,y);
               }
               c.globalAlpha=emit*.94;glow(c,this.traceState==='error'?this.red:this.traceState==='returned'?this.gold:this.sky,head,5.8);
               c.globalCompositeOperation='source-over';signals.push({a:src,b:leaf,progress,x:head.x,y:head.y,dir});
            }
            beats.set(src,Math.max(beats.get(src)||0,1-5*progress));
            beats.set(leaf,Math.max(beats.get(leaf)||0,5*progress-4));
         });
         c.globalCompositeOperation='lighter';
         for(const [id,p] of foreground){
            if(!p.visible||p.x<-20||p.y<-20||p.x>w+20||p.y>h+20)continue;
            const src=this.graph.byId.get(id).g==='src',hit=reduced?0:beats.get(id)||0;
            // The actual VeraCore invocation is the central entry in a verified
            // retrieval chain; emphasize only its selected node, never at idle.
            const entry=id==='d-vera-core';
            c.globalAlpha=emit*(.77+.23*hit);
            glow(c,this.traceState==='error'?this.red:this.traceState==='returned'?this.gold:this.sky,p,(entry?19:src?11:8.5)*(1+.3*hit));
            c.globalAlpha=emit*.84;c.fillStyle=this.traceState==='error'?'#ff899f':this.traceState==='returned'?'#ffe1a3':entry?'#ceeaff':'#8fd0ff';
            c.beginPath();c.arc(p.x,p.y,entry?2.6:src?1.72:1.36,0,TAU);c.fill();
         }
         c.restore();
      }
      // The live Desktop Host identifies an actual active worker session.
      // In pulse mode illuminate only that real actor point, or the stable
      // Harness-active hub if its actor node is not catalogued yet. No edges.
      if(this.working&&!this.showContinuousWorkLines) {
         const selectedID=this.activeActorID&&this.graph.byId.has(this.activeActorID)?
                          this.activeActorID:'d-harness-active';
         const node=this.graph.byId.get(selectedID);
         if(node){
            const point=projection(cameraPoint(node,s),s);
            if(point.visible&&point.x>-25&&point.y>-25&&point.x<w+25&&point.y<h+25){
               const beat=reduced?.65:(.52+.48*Math.sin(TAU*(now-this.workStarted)/2600));
               const pulse=.50+.50*beat;
               c.save();c.globalCompositeOperation='lighter';
               c.globalAlpha=.25+.44*pulse;
               glow(c,this.sky,point,12+17*pulse);
               c.globalAlpha=.52+.38*pulse;c.fillStyle='#b5e8ff';
               c.beginPath();c.arc(point.x,point.y,1.9+1.8*pulse,0,TAU);c.fill();
               c.restore();
            }
         }
      }
      if(this.hover && this.graph.byId.has(this.hover)) {
         const n=this.graph.byId.get(this.hover),p=projection(cameraPoint(n,s),s);
         if(p.visible){c.beginPath();c.arc(p.x,p.y,4,0,TAU);c.lineWidth=.8;c.strokeStyle='#c2b3ff';c.stroke();}
      }
      const stage=steadyWork?'work':(linked?(reduced||age>=900?'focus':'depart'):(replay?phase(age,chosen):this.returning?'return':'idle'));
      const view={phase:stage,working:this.working,activity,memoryPulse,focus:f,sphereZ:0,sphereRadius:s.eye/s.distance,
         shapeMorph:s.shapeMorph,adaptiveShape:this.adaptiveShape,
         activeEdges:f>0?edges:[],activeNodes:f>0?focusData.ids:[],foreground,pulse,age,reduced,signals,
         volumePoints:this.graph.nodes.length,ambientEdges:this.graph.edges.length,graphEdges:this.graph.edges.length,
         camera:{distance:s.distance,panX:s.panX,panY:s.panY,zoom:HOME/s.distance,manualDistance:this.camera.distance,automatic:s.automatic},
         focalTranslation:0,backend:gpuDraw?'webgl':'canvas',
         hover:this.hover?{id:this.hover,edges:(this.graph.adj.get(this.hover)||[]).map(({a,b})=>({a,b}))}:null};
      this.lastView=view;return view;
   }
}
window.AtlasSphere={Sphere,buildGraph,focusOf,packet,envelope,cameraPoint,projection};
})();
