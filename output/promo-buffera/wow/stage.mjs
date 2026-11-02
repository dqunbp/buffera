import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { DURATION, shotAt } from './timeline.mjs';

const clamp=x=>Math.max(0,Math.min(1,x));
const ease=x=>1-(1-clamp(x))**3;
const smooth=x=>{x=clamp(x);return x*x*(3-2*x)};
const mix=(a,b,p)=>a+(b-a)*p;
const vec=(x,y,z)=>new THREE.Vector3(x,y,z);
const bounce=(t,start,amp=1)=>t<start?0:Math.sin((t-start)*18)*Math.exp(-(t-start)*4)*amp;

function texture(draw,width=1536,height=960){
  const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
  const ctx=canvas.getContext('2d');draw(ctx,width,height);
  const map=new THREE.CanvasTexture(canvas);map.colorSpace=THREE.SRGBColorSpace;map.anisotropy=8;return map;
}
function rounded(ctx,x,y,w,h,r,fill){ctx.fillStyle=fill;ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill()}
function line(ctx,text,x,y,size=48,color='#241832',weight=500){ctx.fillStyle=color;ctx.font=`${weight} ${size}px -apple-system,BlinkMacSystemFont,Arial`;ctx.fillText(text,x,y)}
function cardFace(kind){return texture((ctx,w,h)=>{
  rounded(ctx,0,0,w,h,64,'#faf8ff');
  rounded(ctx,62,62,110,110,26,'#e6d8fa');
  line(ctx,kind==='link'?'↗':kind==='text'?'Aa':'▧',84,138,61,'#7444ad',650);
  line(ctx,kind==='link'?'Ссылка':kind==='text'?'Текст':'Скриншот',205,137,43,'#8b7f9b',450);
  if(kind==='link'){
    line(ctx,'Та самая ссылка',68,343,94,'#241832',640);
    line(ctx,'design.example/guide',73,460,63,'#8554ba',500);
    rounded(ctx,71,535,1390,2,1,'#e3daec');
    line(ctx,'Гайд по интерфейсам',73,643,53,'#61506f',450);
    line(ctx,'Пригодится для следующего проекта.',73,726,39,'#766383',400);
    rounded(ctx,72,807,300,68,20,'#ece4f5');line(ctx,'Скопировано',101,853,34,'#8a65b0',500);
  }else if(kind==='text'){
    line(ctx,'Идея для проекта',68,343,91,'#241832',640);
    line(ctx,'Меньше вкладок.',73,472,64,'#60526e',450);
    line(ctx,'Больше хороших идей.',73,561,64,'#60526e',450);
    rounded(ctx,72,673,1300,16,8,'#d8cee5');rounded(ctx,72,723,1030,16,8,'#e1d8ec');
    rounded(ctx,72,807,300,68,20,'#ece4f5');line(ctx,'Скопировано',101,853,34,'#8a65b0',500);
  }else{
    // The picture contains exactly the address that OCR later copies.
    line(ctx,'Улица Примеров, 12',73,390,84,'#49315e',600);
    rounded(ctx,70,490,1390,397,28,'#ccbae3');
    ctx.save();ctx.beginPath();ctx.roundRect(70,490,1390,397,28);ctx.clip();
    ctx.strokeStyle='#fffaff';ctx.lineWidth=40;
    for(const [x1,y1,x2,y2] of [[130,470,560,920],[830,430,1060,950],[20,620,1510,565],[20,830,1510,760]]){ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.stroke()}
    rounded(ctx,1090,728,270,122,25,'#af92cc');
    ctx.fillStyle='#8e5bc3';ctx.beginPath();ctx.arc(793,650,34,0,Math.PI*2);ctx.fill();
    ctx.beginPath();ctx.moveTo(766,668);ctx.lineTo(793,711);ctx.lineTo(820,668);ctx.fill();
    ctx.fillStyle='#fff';ctx.beginPath();ctx.arc(793,648,12,0,Math.PI*2);ctx.fill();ctx.restore();
  }
  rounded(ctx,1386,68,76,76,38,'#e8dcf6');line(ctx,'✓',1400,124,48,'#8a63ad',650);
})}
function roundShape(width,height,radius){
  const x=-width/2,y=-height/2,s=new THREE.Shape();
  s.moveTo(x+radius,y);s.lineTo(x+width-radius,y);s.quadraticCurveTo(x+width,y,x+width,y+radius);
  s.lineTo(x+width,y+height-radius);s.quadraticCurveTo(x+width,y+height,x+width-radius,y+height);
  s.lineTo(x+radius,y+height);s.quadraticCurveTo(x,y+height,x,y+height-radius);
  s.lineTo(x,y+radius);s.quadraticCurveTo(x,y,x+radius,y);return s;
}

export async function createStage(canvas){
  const renderer=new THREE.WebGLRenderer({canvas,antialias:true,alpha:false,preserveDrawingBuffer:true,powerPreference:'high-performance'});
  renderer.setSize(1920,1080,false);renderer.setPixelRatio(1);
  renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.08;
  const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(38,1920/1080,.1,80);
  const pmrem=new THREE.PMREMGenerator(renderer),room=new RoomEnvironment();
  scene.environment=pmrem.fromScene(room,.035).texture;scene.environmentIntensity=1.15;room.dispose();pmrem.dispose();
  const key=new THREE.DirectionalLight('#fff7ff',3);key.position.set(-4,6,6);scene.add(key);
  const rim=new THREE.DirectionalLight('#b69bf5',2.7);rim.position.set(6,2,-3);scene.add(rim);
  const fill=new THREE.DirectionalLight('#fffaff',1.6);fill.position.set(3,-2,4);scene.add(fill);
  const slabGeometry=new THREE.ExtrudeGeometry(roundShape(5.75,3.65,.22),{depth:.13,bevelEnabled:true,bevelSegments:3,steps:1,bevelSize:.055,bevelThickness:.055,curveSegments:12});
  const cards=[];
  for(const kind of ['link','text','screenshot']){
    const group=new THREE.Group();
    const edge=new THREE.Mesh(slabGeometry,new THREE.MeshStandardMaterial({color:'#b49bd1',metalness:.12,roughness:.58,envMapIntensity:.55}));
    edge.position.z=-.12;group.add(edge);
    const face=new THREE.Mesh(new THREE.PlaneGeometry(5.62,3.51),new THREE.MeshBasicMaterial({map:cardFace(kind),alphaTest:.05,toneMapped:false,side:THREE.FrontSide}));
    face.position.z=.085;group.add(face);
    const accent=new THREE.Mesh(new THREE.ExtrudeGeometry(roundShape(5.83,3.73,.26),{depth:.025,bevelEnabled:false,curveSegments:12}),new THREE.MeshBasicMaterial({color:'#a563f1'}));
    accent.position.z=-.19;accent.visible=false;group.add(accent);
    group.userData={kind,edge,face,accent};scene.add(group);cards.push(group);
  }
  const [linkCard,textCard,screenshot]=cards;
  const scan=new THREE.Mesh(new THREE.PlaneGeometry(4.9,.038),new THREE.MeshBasicMaterial({color:'#9951ef',transparent:true,opacity:.8,depthWrite:false}));
  scan.position.z=.11;screenshot.add(scan);
  const scanBand=new THREE.Mesh(new THREE.PlaneGeometry(4.9,.22),new THREE.MeshBasicMaterial({color:'#af78ed',transparent:true,opacity:.15,depthWrite:false}));
  scanBand.position.z=.105;screenshot.add(scanBand);
  const extract=new THREE.Group();
  const extractTexture=texture((ctx,w,h)=>{rounded(ctx,0,0,w,h,33,'#fbf8ff');line(ctx,'Улица Примеров, 12',53,150,72,'#59317e',580)},1200,240);
  const extractBase=new THREE.Mesh(new THREE.ExtrudeGeometry(roundShape(4.85,1.02,.15),{depth:.07,bevelEnabled:true,bevelSize:.035,bevelThickness:.035,bevelSegments:3,curveSegments:8}),new THREE.MeshStandardMaterial({color:'#b49bd1',metalness:.12,roughness:.58,envMapIntensity:.55}));
  extractBase.position.z=-.08;extract.add(extractBase);
  const extractFace=new THREE.Mesh(new THREE.PlaneGeometry(4.73,.945),new THREE.MeshBasicMaterial({map:extractTexture,alphaTest:.05,toneMapped:false}));extractFace.position.z=.035;extract.add(extractFace);scene.add(extract);
  // The brand forms appear only in the final lockup.
  const pair=new THREE.Group();scene.add(pair);const blobs=[];
  for(let i=0;i<2;i++){
    const geometry=new THREE.SphereGeometry(1,56,40),a=geometry.attributes.position.array;
    for(let k=0;k<a.length;k+=3){const y=a[k+1];a[k]*=1.1*(1-.15*y+.055*(1-y*y));a[k+1]=y*1.08+.065*(1-y*y);a[k+2]*=.98+.13*(1-y*y)}
    geometry.computeVertexNormals();
    const m=new THREE.Mesh(geometry,new THREE.MeshPhysicalMaterial({color:i?'#8436dd':'#9a4ce8',metalness:.42,roughness:.155,clearcoat:1,clearcoatRoughness:.075,envMapIntensity:1.7}));pair.add(m);blobs.push(m);
  }
  function cam(pos,target,fov=38){camera.position.copy(pos);camera.lookAt(target);camera.fov=fov;camera.updateProjectionMatrix()}
  function place(card,x,y,z,rx,ry,rz,scale=1){card.visible=true;card.position.set(x,y,z);card.rotation.set(rx,ry,rz);card.scale.setScalar(scale)}
  let renderedTime=0,renderedShot=shotAt(0);
  function render(time){
    const t=Math.max(0,Math.min(DURATION,time)),shot=shotAt(t);
    const {id,local:s,duration}=shot;
    renderedTime=t;renderedShot=shot;
    const light=['copy2','paste-link','extract','paste-address'].includes(id);
    scene.background=new THREE.Color(light?'#f4f4f7':'#08070b');renderer.toneMappingExposure=light?1.04:1.08;
    cards.forEach(c=>{c.visible=false;c.userData.accent.visible=false});pair.visible=false;extract.visible=false;scan.visible=false;scanBand.visible=false;
    cam(vec(0,.2,8.2),vec(0,-.3,0));
    if(id==='copy1'){
      const p=ease(s/duration);
      const entry=ease(s/.65);
      place(linkCard,2.2,-.62,0,mix(.22,.035,entry),mix(-.72,.12,entry),mix(-.09,.035,p),.76);
      linkCard.visible=s>=.18;linkCard.scale.multiplyScalar(ease((s-.18)/.4));
      cam(vec(mix(.9,-.25,p),mix(.7,.25,p),mix(9.6,9.1,p)),vec(0,-.2,0));
    }else if(id==='copy2'){
      const p=ease(s/.58);
      place(linkCard,mix(2.2,1.7,p),mix(-.45,-.25,p),mix(0,-1.5,p),.06,mix(.12,-.15,p),mix(.035,-.12,p),mix(.76,.66,p));
      place(textCard,mix(7,2.3,p),-.62,mix(2,.2,p),mix(-.16,.025,p),mix(-.65,-.10,p),mix(.12,.025,p),.76);
      cam(vec(mix(-.25,.4,p),.3,mix(9.1,9.4,p)),vec(0,-.2,0));
    }else if(id==='history'){
      // The selected card has its own clear corridor. It never crosses either
      // thumbnail's projected bounds or physical surface while moving forward.
      const settle=ease(s/.28),lift=ease((s-.24)/.62);
      place(textCard,mix(-3.8,-3.45,settle),.64,-.6,.025,.06,-.025,.34);
      place(screenshot,mix(-3.95,-3.45,settle),-1.08,-.6,.025,.06,.025,.34);
      place(linkCard,mix(1.6,1.34,lift),mix(-.48,-.32,lift),mix(-.65,.5,lift),.025,mix(-.075,0,lift),mix(-.025,0,lift),mix(.84,.94,lift));
      linkCard.userData.accent.visible=s>.24;
      cam(vec(0,.3,9.9),vec(0,-.2,0));
    }else if(id==='paste-link'){
      // The HTML address field performs the paste in this shot.
    }else if(id==='screenshot'){
      const p=ease(s/duration);
      const entry=ease(s/.65);
      place(screenshot,2.2,-.62,0,mix(.18,.035,entry),mix(.7,-.1,entry),mix(.07,-.025,p),.76);
      screenshot.visible=s>=.18;screenshot.scale.multiplyScalar(ease((s-.18)/.4));
      cam(vec(mix(-.7,.25,p),.45,mix(9.5,9.1,p)),vec(0,-.2,0));
    }else if(id==='extract'){
      const p=ease(s/.48),reveal=ease((s-.65)/.6);
      place(screenshot,mix(0,-1.75,p),-.43,-.05,.035,mix(-.1,.18,p),-.035,mix(1,.79,p));
      scan.visible=s>=.15&&s<.8;scanBand.visible=scan.visible;
      const scanY=mix(.68,.32,smooth((s-.15)/.65));scan.position.y=scanY;scanBand.position.y=scanY+.11;
      extract.visible=s>.65;extract.position.set(mix(-.2,2,reveal),mix(-.15,-.55,reveal),mix(.9,1.25,reveal));
      extract.rotation.set(.025,mix(-.28,-.05,reveal),mix(-.05,.015,reveal));extract.scale.setScalar(mix(.65,1,reveal));
      cam(vec(0,.25,9.5),vec(0,-.3,0));
    }else if(id==='paste-address'){
      // The HTML message field shows the extracted address at its destination.
    }else{
      const p=ease(s/.5);pair.visible=true;pair.position.set(0,1.2,0);pair.scale.setScalar(mix(.8,.59,p));
      pair.rotation.set(0,mix(-.25,.05,p),mix(.08,0,p));
      blobs.forEach((m,i)=>{const sign=i?1:-1,d=bounce(t,shot.start+.08+i*.03,.55);m.position.set(sign*(1.04+.18*d),-.13*d,0);m.rotation.set(0,sign*-.12,sign*(.12+d*.08));m.scale.set(1-.11*d,1+.15*d,1-.07*d)});
      if(s<.5){
        const depart=ease(s/.5);
        place(linkCard,mix(-3.1,-3.9,depart),mix(.7,-1.7,depart),mix(-.3,-4,depart),.05,mix(.1,-.25,depart),mix(-.08,-.3,depart),mix(.3,.08,depart));
        place(screenshot,mix(3.1,3.9,depart),mix(.7,-1.7,depart),mix(-.3,-4,depart),.05,mix(-.1,.25,depart),mix(.08,.3,depart),mix(.3,.08,depart));
      }
      cam(vec(0,.2,8.2),vec(0,.2,0));
    }
    renderer.render(scene,camera);
  }
  function inspect(){
    scene.updateMatrixWorld(true);camera.updateMatrixWorld(true);
    const bounds=cards.filter(card=>card.visible).map(card=>{
      const points=[];
      function visit(object){
        if(!object.visible)return;
        if(object.geometry){
          object.geometry.computeBoundingBox();
          const {min,max}=object.geometry.boundingBox;
          for(const x of [min.x,max.x])for(const y of [min.y,max.y])for(const z of [min.z,max.z]){
            const p=vec(x,y,z).applyMatrix4(object.matrixWorld).project(camera);
            points.push({x:(p.x+1)*960,y:(1-p.y)*540});
          }
        }
        for(const child of object.children)visit(child);
      }
      visit(card);
      return {id:card.userData.kind,left:Math.min(...points.map(p=>p.x)),top:Math.min(...points.map(p=>p.y)),right:Math.max(...points.map(p=>p.x)),bottom:Math.max(...points.map(p=>p.y))};
    });
    return {time:renderedTime,shot:renderedShot.id,cards:bounds};
  }
  render(0);return {render,inspect,renderer,scene,camera};
}
