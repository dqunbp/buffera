import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { DURATION, ACTIONS, shotAt } from './timeline.mjs';

const clamp = n => Math.max(0, Math.min(1, n));
const ease = n => 1 - (1 - clamp(n)) ** 3;
const smooth = n => { n=clamp(n); return n*n*(3-2*n); };
const mix = (a,b,p) => a+(b-a)*p;
const v = (x,y,z) => new THREE.Vector3(x,y,z);
const spring = (t,start) => t<start?0:Math.sin((t-start)*16)*Math.exp(-(t-start)*1.65);

function roundedShape(w,h,r) {
  const x=-w/2,y=-h/2,p=new THREE.Shape();
  p.moveTo(x+r,y);p.lineTo(x+w-r,y);p.quadraticCurveTo(x+w,y,x+w,y+r);
  p.lineTo(x+w,y+h-r);p.quadraticCurveTo(x+w,y+h,x+w-r,y+h);
  p.lineTo(x+r,y+h);p.quadraticCurveTo(x,y+h,x,y+h-r);
  p.lineTo(x,y+r);p.quadraticCurveTo(x,y,x+r,y);return p;
}
function faceTexture(kind) {
  const canvas=document.createElement('canvas');canvas.width=1400;canvas.height=875;
  const ctx=canvas.getContext('2d');
  const box=(x,y,w,h,r,color)=>{ctx.fillStyle=color;ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill()};
  const text=(value,x,y,size,color='#35233e',weight=500)=>{
    ctx.font=`${weight} ${size}px -apple-system,BlinkMacSystemFont,Arial`;
    ctx.fillStyle=color;ctx.fillText(value,x,y);
  };
  box(0,0,1400,875,62,'#fffaff');
  box(64,65,110,110,29,'#e8d7f6');
  text(kind==='link'?'↗':kind==='note'?'Aa':'▧',83,141,62,'#8053a4',650);
  text(kind==='link'?'Ссылка':kind==='note'?'Заметка':'Скриншот',211,136,43,'#8d7998',450);
  text(kind==='link'?'Та самая ссылка':kind==='note'?'Та самая мысль':'Место встречи',66,344,92,'#35233e',630);
  text(kind==='link'?'design.example/guide':kind==='note'?'Меньше вкладок. Больше идей.':'Улица Примеров, 12',72,467,kind==='note'?58:65,'#8550ab',500);
  box(72,549,1245,3,1,'#e6daed');
  if(kind==='link'){
    text('Гайд по интерфейсам',72,664,52,'#806a8e',450);
    text('Сохранено в Buffera',72,770,36,'#aa8cb9',450);
  }else{
    box(72,634,1150,15,7,'#ddd0e7');box(72,688,830,15,7,'#e8dfee');
  }
  box(1250,76,74,74,37,'#efe2f7');text('✓',1266,130,45,'#9272aa',600);
  const map=new THREE.CanvasTexture(canvas);map.colorSpace=THREE.SRGBColorSpace;map.anisotropy=8;
  return map;
}
function softGeometry() {
  const geometry=new THREE.SphereGeometry(1,64,48),a=geometry.attributes.position.array;
  for(let i=0;i<a.length;i+=3){
    const y=a[i+1];
    a[i]*=1.08*(1-.11*y+.045*(1-y*y));
    a[i+1]=y*1.08+.045*(1-y*y);
    a[i+2]*=.93+.11*(1-y*y);
  }
  geometry.computeVertexNormals();return geometry;
}

export async function createStage(canvas) {
  const renderer=new THREE.WebGLRenderer({canvas,antialias:true,alpha:false,preserveDrawingBuffer:true,powerPreference:'high-performance'});
  renderer.setSize(1920,1080,false);renderer.setPixelRatio(1);
  renderer.outputColorSpace=THREE.SRGBColorSpace;
  renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.03;
  const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(38,1920/1080,.1,90);
  const pmrem=new THREE.PMREMGenerator(renderer),room=new RoomEnvironment();
  scene.environment=pmrem.fromScene(room,.06).texture;scene.environmentIntensity=.85;
  room.dispose();pmrem.dispose();
  const key=new THREE.DirectionalLight('#fff0df',2.5);key.position.set(-4,6,5);scene.add(key);
  const rim=new THREE.DirectionalLight('#d6b9fa',2.1);rim.position.set(6,2,-4);scene.add(rim);
  const fill=new THREE.DirectionalLight('#fff6fe',.8);fill.position.set(-5,-1,3);scene.add(fill);
  const slab=new THREE.ExtrudeGeometry(roundedShape(5.6,3.5,.24),{depth:.12,bevelEnabled:true,bevelSize:.045,bevelThickness:.045,bevelSegments:3,curveSegments:16});
  const cards=['link','note','image'].map(kind=>{
    const group=new THREE.Group();group.userData.kind=kind;
    const edge=new THREE.Mesh(slab,new THREE.MeshStandardMaterial({color:'#c6addc',metalness:.16,roughness:.47,envMapIntensity:.5}));
    edge.position.z=-.11;group.add(edge);
    const face=new THREE.Mesh(new THREE.PlaneGeometry(5.47,3.42),new THREE.MeshBasicMaterial({map:faceTexture(kind),alphaTest:.04,toneMapped:false,side:THREE.DoubleSide}));
    face.position.z=.075;group.add(face);scene.add(group);return group;
  });
  const [link,note,image]=cards;
  const geometry=softGeometry();
  function makePair(){
    const group=new THREE.Group(),parts=[];
    for(let i=0;i<2;i++){
      const ownGeometry=geometry.clone();
      const mesh=new THREE.Mesh(ownGeometry,new THREE.MeshPhysicalMaterial({
        color:i?'#a15bd5':'#b476df',metalness:.11,roughness:.235,
        clearcoat:.88,clearcoatRoughness:.15,envMapIntensity:1.1,
        sheen:.18,sheenColor:new THREE.Color('#eecaff'),sheenRoughness:.5,
      }));
      mesh.userData.basePositions=new Float32Array(ownGeometry.attributes.position.array);
      group.add(mesh);parts.push(mesh);
    }
    scene.add(group);return {group,parts};
  }
  const hero=makePair(),cameo=makePair();
  function arrange(pair,separation=1.18,rebound=0,contact=null){
    const stats=[];
    pair.parts.forEach((mesh,i)=>{
      const sign=i?1:-1;
      const response=Math.max(-1.05,Math.min(1.05,typeof rebound==='function'?rebound(i):rebound));
      const pressure=contact?.pressure??0;
      const vertical=.18*response-.075*pressure;
      mesh.visible=true;
      // Centres never open a corridor. Motion comes from the material's shape
      // and a vertical impulse; each body stays anchored to its original x.
      mesh.position.set(sign*separation,-.14*response+.035*pressure,0);
      mesh.rotation.set(0,0,0);mesh.scale.set(1,1,1);
      const a=mesh.geometry.attributes.position.array,base=mesh.userData.basePositions;
      let maxDent=0,maxVertical=0;
      for(let k=0;k<a.length;k+=3){
        const x=base[k],y=base[k+1],z=base[k+2];
        let dx=x*(1-.42*vertical+.035*pressure);
        const dy=y*(1+vertical);
        const dz=z*(1-.25*vertical+.04*pressure);
        if(contact?.box){
          // An edge-on card presses a travelling local indentation into the
          // inward surface. A padded contact patch keeps triangles clear too.
          const box=contact.box,worldY=pair.group.position.y+mesh.position.y+dy;
          const worldZ=pair.group.position.z+dz;
          const yDistance=Math.max(box.min.y-.14-worldY,worldY-box.max.y-.14,0);
          const zDistance=Math.max(box.min.z-.12-worldZ,worldZ-box.max.z-.12,0);
          const patch=Math.exp(-(yDistance*yDistance)/.055-(zDistance*zDistance)/.055);
          const inner=clamp((-sign*x-.25)/.7);
          const unpressedX=sign*separation+dx;
          const boundary=sign<0?box.min.x-.028:box.max.x+.028;
          const overlap=sign<0?Math.max(0,unpressedX-boundary):Math.max(0,boundary-unpressedX);
          const tactile=.11*pressure*inner*Math.exp(-((worldY-box.min.y-.28)**2)/.42);
          const dent=(overlap+tactile)*patch;
          dx+=sign*dent;maxDent=Math.max(maxDent,dent);
        }
        // Neighbouring cushions can touch, but their inner surfaces do not
        // pass through one another during the negative rebound half-cycle.
        dx=sign<0?Math.min(dx,separation-.012):Math.max(dx,-separation+.012);
        a[k]=dx;a[k+1]=dy;a[k+2]=dz;
        maxVertical=Math.max(maxVertical,Math.abs(dy-y));
      }
      mesh.geometry.attributes.position.needsUpdate=true;
      mesh.geometry.computeVertexNormals();mesh.geometry.computeBoundingBox();mesh.geometry.computeBoundingSphere();
      stats.push({dentDepth:maxDent,verticalScale:1+vertical,maxVerticalDeformation:maxVertical,response});
    });
    pair.stats=stats;pair.separation=separation;
  }
  function place(object,x,y,z,rx,ry,rz,scale=1){
    object.visible=true;object.position.set(x,y,z);object.rotation.set(rx,ry,rz);object.scale.setScalar(scale);
  }
  function cam(position,target,fov=38){camera.position.copy(position);camera.lookAt(target);camera.fov=fov;camera.updateProjectionMatrix()}
  let current=shotAt(0),now=0;
  function render(time){
    now=Math.max(0,Math.min(DURATION,time));current=shotAt(now);
    const {id,local:s,duration}=current;
    const light=id==='copy'||id==='result';
    scene.background=new THREE.Color(light?'#f4f2f6':'#0b0810');
    renderer.toneMappingExposure=light?1.02:1.05;
    cards.forEach(card=>card.visible=false);hero.group.visible=false;cameo.group.visible=false;
    hero.parts.forEach(mesh=>mesh.visible=true);cameo.parts.forEach(mesh=>mesh.visible=true);
    cam(v(0,.3,9.9),v(0,-.2,0));
    if(id==='copy'){
      const arrival=ease((now-ACTIONS.copy)/.55),drift=smooth(s/duration);
      if(now>=ACTIONS.copy){
        place(link,2.38,-.5,0,mix(.12,.025,arrival),mix(-.37,.04,arrival),mix(-.03,.025,drift),mix(.52,.75,arrival));
      }
      // A small side holder, with a single sympathetic response to the copy.
      place(cameo.group,4.53,-2.06,.05,0,-.1,-.12,.31);
      arrange(cameo,1.18,i=>spring(now,ACTIONS.copy+.04*i)*1.05);
      cam(v(mix(.28,-.12,drift),.3,9.9),v(0,-.2,0));
    }else if(id==='find'){
      const settle=ease(s/.35),lift=ease((s-.45)/.75);
      place(note,mix(-3.8,-3.45,settle),.62,-.6,.025,.06,-.025,.33);
      place(image,mix(-3.85,-3.45,settle),-1.07,-.6,.025,.06,.025,.33);
      place(link,mix(1.6,1.34,lift),mix(-.48,-.32,lift),mix(-.65,.5,lift),.025,mix(-.08,0,lift),mix(-.025,0,lift),mix(.82,.94,lift));
      // A cropped foreground curve frames the left edge, instead of repeating
      // the entire hero silhouette in every shot.
      place(cameo.group,-7.95,-1.6,1.25,.12,-.2,-.14,2.25);
      arrange(cameo,1.18,i=>spring(now,ACTIONS.found+.04*i)*.85);
      cameo.parts[1].visible=false;cameo.parts[0].position.x=.55;
    }else if(id==='insert'){
      const turn=smooth((now-7.15)/.70);
      const pass=smooth((now-ACTIONS.insert)/1.28);
      place(hero.group,0,-1.03,0,0,0,0,1);
      // One vertical insertion. The bodies do not move aside to let it through.
      // Their inner surfaces are compressed only where the card makes contact.
      if(now<9.28){
        place(link,0,mix(1.28,-3.65,pass),.15,0,mix(-.035,83*Math.PI/180,turn),0,.44);
      }
      scene.updateMatrixWorld(true);
      const cardBox=now>=ACTIONS.insert&&link.visible?new THREE.Box3().setFromObject(link):null;
      const pressure=cardBox?smooth((.18-cardBox.min.y)/.35)*smooth((cardBox.max.y+2.27)/.35):0;
      const response=i=>.30*spring(now,5.66+i*.045)+.52*spring(now,8.12+i*.055)+1.05*spring(now,8.87+i*.055);
      arrange(hero,1.18,response,{box:cardBox,pressure});
      const orbit=smooth((now-6.0)/4.3);
      cam(v(mix(.8,1.6,orbit),.60,mix(10.1,9.8,orbit)),v(0,.15,0),38);
    }else if(id==='result'){
      // Just a soft edge in the lower corner: the destination remains the focus.
      place(cameo.group,6.8,-2.5,.7,0,-.2,.15,.9);
      arrange(cameo,1.18,i=>spring(now,ACTIONS.paste+i*.045)*1.05);
      cameo.parts[1].visible=false;
      cam(v(0,.3,9.9),v(0,-.2,0));
    }else{
      const p=ease(s/.6);
      place(hero.group,0,1.24,0,0,mix(-.15,.025,p),mix(.045,0,p),mix(.66,.60,p));
      arrange(hero,1.18,i=>spring(now,ACTIONS.brand+i*.045)*.95);
      cam(v(0,.2,8.2),v(0,.2,0));
    }
    renderer.render(scene,camera);
  }
  function projectedBounds(object){
    const points=[];
    object.updateWorldMatrix(true,true);
    const walk=node=>{
      if(!node.visible)return;
      if(node.geometry){
        node.geometry.computeBoundingBox();const {min,max}=node.geometry.boundingBox;
        for(const x of [min.x,max.x])for(const y of [min.y,max.y])for(const z of [min.z,max.z]){
          const p=v(x,y,z).applyMatrix4(node.matrixWorld).project(camera);
          points.push({x:(p.x+1)*960,y:(1-p.y)*540});
        }
      }
      node.children.forEach(walk);
    };
    walk(object);
    return points.length?{left:Math.min(...points.map(p=>p.x)),right:Math.max(...points.map(p=>p.x)),top:Math.min(...points.map(p=>p.y)),bottom:Math.max(...points.map(p=>p.y))}:null;
  }
  function inspect(){
    scene.updateMatrixWorld(true);camera.updateMatrixWorld(true);
    const cardBox=link.visible?new THREE.Box3().setFromObject(link):null;
    const heroBoxes=hero.group.visible?hero.parts.map(mesh=>new THREE.Box3().setFromObject(mesh)):[];
    const clearance=[];
    if(cardBox&&hero.group.visible&&current.id==='insert'){
      hero.parts.forEach((mesh,i)=>{
        let minimum=Infinity,checked=0;
        const a=mesh.geometry.attributes.position.array;
        for(let k=0;k<a.length;k+=3){
          const p=v(a[k],a[k+1],a[k+2]).applyMatrix4(mesh.matrixWorld);
          if(p.y<cardBox.min.y||p.y>cardBox.max.y||p.z<cardBox.min.z||p.z>cardBox.max.z)continue;
          checked++;minimum=Math.min(minimum,i?p.x-cardBox.max.x:cardBox.min.x-p.x);
        }
        clearance.push({minimum:checked?minimum:null,checkedVertices:checked});
      });
    }
    return {
      time:now,shot:current.id,
      cards:cards.filter(c=>c.visible).map(c=>({id:c.userData.kind,...projectedBounds(c)})),
      hero:hero.group.visible?projectedBounds(hero.group):null,
      cardPosition:link.visible?link.position.toArray():null,
      cardRotation:link.visible?link.rotation.toArray().slice(0,3):null,
      cardCenter:link.visible?link.position.toArray():null,
      cardYaw:link.visible?link.rotation.y:null,
      centerSeparation:hero.group.visible?hero.parts[1].position.x-hero.parts[0].position.x:null,
      contactDentDepthLeft:hero.stats?.[0]?.dentDepth??0,
      contactDentDepthRight:hero.stats?.[1]?.dentDepth??0,
      verticalDeformation:hero.stats?.map(stat=>stat.maxVerticalDeformation)??[],
      verticalScale:hero.stats?.map(stat=>stat.verticalScale)??[],
      contactSurfaceClearance:clearance,
      gapClearance:cardBox&&heroBoxes.length===2?Math.min(cardBox.min.x-heroBoxes[0].max.x,heroBoxes[1].min.x-cardBox.max.x):null,
      cardHeroIntersections:cardBox?heroBoxes.map(box=>cardBox.intersectsBox(box)):[],
      heroBounds:heroBoxes.map(box=>({min:box.min.toArray(),max:box.max.toArray()})),
    };
  }
  render(0);return {render,inspect,renderer,scene,camera};
}
