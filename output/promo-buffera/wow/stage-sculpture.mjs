import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

const clamp = x => Math.max(0, Math.min(1, x));
const ease = x => 1 - (1 - clamp(x)) ** 3;
const smooth = x => { x=clamp(x); return x*x*(3-2*x); };
const lerp = (a,b,p) => a+(b-a)*p;
const spring = (t,start,amplitude=1) => t<start?0:Math.sin((t-start)*18)*Math.exp(-(t-start)*3.8)*amplitude;
const v3 = (x,y,z) => new THREE.Vector3(x,y,z);

function shadowTexture() {
  const c=document.createElement('canvas');c.width=256;c.height=256;
  const x=c.getContext('2d'),g=x.createRadialGradient(128,128,0,128,128,128);
  g.addColorStop(0,'rgba(25,7,49,.46)');g.addColorStop(.35,'rgba(25,7,49,.28)');g.addColorStop(1,'rgba(25,7,49,0)');
  x.fillStyle=g;x.fillRect(0,0,256,256);
  return new THREE.CanvasTexture(c);
}

function cardTexture(index) {
  const c=document.createElement('canvas');c.width=768;c.height=480;
  const x=c.getContext('2d');
  x.fillStyle='#faf8ff';x.beginPath();x.roundRect(0,0,768,480,40);x.fill();
  x.fillStyle='#e6d7ff';x.beginPath();x.roundRect(40,40,105,105,24);x.fill();
  x.fillStyle='#7644bd';x.font='600 55px -apple-system,BlinkMacSystemFont,Arial';x.fillText(['⌘C','↗','Aa'][index%3],53,112);
  x.fillStyle='#8b819b';x.font='30px -apple-system,BlinkMacSystemFont,Arial';x.fillText('В буфере',174,104);
  x.fillStyle='#21182d';x.font='600 55px -apple-system,BlinkMacSystemFont,Arial';x.fillText(['Та самая ссылка.','Та самая мысль.','Скриншот.'][index%3],42,237);
  x.fillStyle='#d4c8e5';x.beginPath();x.roundRect(44,290,590,14,7);x.roundRect(44,330,410,14,7);x.fill();
  x.fillStyle='#9266d0';x.font='40px -apple-system,BlinkMacSystemFont,Arial';x.fillText('✓',666,416);
  const texture=new THREE.CanvasTexture(c);texture.colorSpace=THREE.SRGBColorSpace;texture.anisotropy=4;
  return texture;
}

/** Studio lit deterministic film stage. No real clipboard data or external imagery. */
export async function createStage(canvas) {
  const renderer=new THREE.WebGLRenderer({canvas,antialias:true,alpha:false,preserveDrawingBuffer:true,powerPreference:'high-performance'});
  renderer.setSize(1920,1080,false);renderer.setPixelRatio(1);
  renderer.outputColorSpace=THREE.SRGBColorSpace;
  renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.05;
  const scene=new THREE.Scene();
  const camera=new THREE.PerspectiveCamera(38,1920/1080,.1,70);
  const pmrem=new THREE.PMREMGenerator(renderer);
  const studio=new RoomEnvironment();
  const env=pmrem.fromScene(studio,.035).texture;
  scene.environment=env;scene.environmentIntensity=1.3;
  studio.dispose();pmrem.dispose();

  const key=new THREE.DirectionalLight('#fff5ff',4.3);key.position.set(-3,6,5);scene.add(key);
  const rim=new THREE.DirectionalLight('#c6b7ff',3.6);rim.position.set(5,3,-4);scene.add(rim);
  const fill=new THREE.DirectionalLight('#fffaff',1.8);fill.position.set(-5,-1,2);scene.add(fill);
  const pair=new THREE.Group();scene.add(pair);
  const baseGeometry=new THREE.SphereGeometry(1,64,48);
  const base=baseGeometry.attributes.position.array;
  for(let i=0;i<base.length;i+=3){
    const y=base[i+1];
    // Broad lower volume, soft flattened crown and a rounded front. Not an egg.
    base[i]*=1.1*(1-.15*y+.055*(1-y*y));
    base[i+1]=y*1.08+.065*(1-y*y);
    base[i+2]=base[i+2]*(.98+.13*(1-y*y))+.07*(1-y*y);
  }
  baseGeometry.computeVertexNormals();
  const blobs=[];
  for(let i=0;i<2;i++){
    const geometry=baseGeometry.clone();
    const material=new THREE.MeshPhysicalMaterial({
      color:i?'#8436dd':'#9a4ce8',metalness:.42,roughness:.155,
      clearcoat:1,clearcoatRoughness:.075,ior:1.47,
      sheen:.35,sheenColor:new THREE.Color('#dfb3ff'),sheenRoughness:.33,
      envMapIntensity:1.7,
    });
    const mesh=new THREE.Mesh(geometry,material);
    mesh.userData.base=new Float32Array(geometry.attributes.position.array);
    pair.add(mesh);blobs.push(mesh);
  }
  baseGeometry.dispose();
  const shadows=new THREE.Group();scene.add(shadows);
  const shadowMap=shadowTexture();
  for(let i=0;i<2;i++){
    const m=new THREE.Mesh(new THREE.PlaneGeometry(3.6,2.5),new THREE.MeshBasicMaterial({map:shadowMap,transparent:true,opacity:.65,depthWrite:false}));
    m.rotation.x=-Math.PI/2;m.position.set(i?1.1:-1.1,-1.17,0);shadows.add(m);
  }

  const cards=new THREE.Group();scene.add(cards);
  const cardMeshes=[];
  for(let i=0;i<9;i++){
    const m=new THREE.Mesh(new THREE.PlaneGeometry(1.5,.9375),new THREE.MeshBasicMaterial({map:cardTexture(i),transparent:true,side:THREE.DoubleSide,depthWrite:true}));
    cards.add(m);cardMeshes.push(m);
  }
  const ring=new THREE.Mesh(new THREE.TorusGeometry(2.2,.045,12,100),new THREE.MeshPhysicalMaterial({color:'#dac9ee',metalness:1,roughness:.12,envMapIntensity:2.7}));
  scene.add(ring);

  function deform(t,hit,amount=1) {
    blobs.forEach((mesh,i)=>{
      const sign=i?1:-1;
      const bounce=spring(t,hit+i*.028,amount);
      const compress=hit>0?(smooth((t-(hit-.15))/.15)*(1-smooth((t-hit)/.1)))*amount:0;
      const sway=bounce*.11;
      mesh.position.set(sign*(1.04-.28*compress+.21*bounce),-.12*bounce+i*.035,.10*Math.sin(t*1.1+i));
      mesh.rotation.set(.035*Math.sin(t+i),sign*-.12+Math.sin(t*.7+i)*.08,sign*(.12+sway));
      mesh.scale.set(1+.16*compress-.10*bounce,1-.16*compress+.13*bounce,1+.13*compress-.08*bounce);
      const positions=mesh.geometry.attributes.position.array,original=mesh.userData.base;
      for(let k=0;k<positions.length;k+=3){
        const x=original[k],y=original[k+1],z=original[k+2];
        const ripple=.026*Math.sin(y*7+z*4-(t-hit)*23+i)*Math.exp(-Math.max(0,t-hit)*4)*Math.abs(bounce);
        positions[k]=x*(1+ripple);positions[k+1]=y*(1+ripple*.6);positions[k+2]=z*(1+ripple);
      }
      mesh.geometry.attributes.position.needsUpdate=true;
      mesh.geometry.computeVertexNormals();
    });
  }

  function setCamera(position,target,fov=38) {
    camera.position.copy(position);camera.lookAt(target);camera.fov=fov;camera.updateProjectionMatrix();
  }

  function render(time) {
    const t=Math.max(0,Math.min(12.8,time));
    const light=(t>=1.6&&t<3.2)||(t>=5.6&&t<6.4)||(t>=8&&t<9.6);
    scene.background=new THREE.Color(light?'#f4f4f7':'#08070b');
    renderer.toneMappingExposure=light?1.06:1.13;
    pair.visible=true;cards.visible=false;ring.visible=false;
    shadows.visible=light;pair.position.set(0,0,0);pair.rotation.set(0,0,0);pair.scale.setScalar(1);
    scene.environmentIntensity=light?1.2:1.3;
    key.intensity=light?3.7:4.3;rim.intensity=light?2.5:3.6;
    let hit=-10,amp=0;

    if(t<1.6){
      const p=smooth(t/1.6);
      pair.position.set(.85,-.45,0);pair.rotation.y=lerp(-.24,.15,p);
      pair.rotation.z=lerp(-.15,.09,p);
      setCamera(v3(lerp(3.9,-.9,p),lerp(.9,.25,p),lerp(4.2,4.65,p)),v3(.5,-.08,0),38);
    }else if(t<3.2){
      const p=ease((t-1.6)/.35);
      pair.position.set(2.35,-.15,0);
      pair.rotation.y=lerp(-.23,.05,p);pair.rotation.z=-.055;
      setCamera(v3(0,.18,8.9),v3(0,-.05,0),38);
      hit=2; amp=1.65;
    }else if(t<5.6){
      const s=t-3.2;
      pair.position.set(0,-.7,-.25);pair.scale.setScalar(.92);
      pair.rotation.y=Math.sin(s*1.7)*.18;pair.rotation.z=Math.sin(s*2)*.045;
      setCamera(v3(Math.sin(s*1.2)*.5,.55,7.8-s*.32),v3(0,-.25,0),40);
      hit=3.2+Math.floor(s/.8)*.8;amp=.65;
      cards.visible=true;
      cardMeshes.forEach((card,i)=>{
        const wave=Math.floor(i/3),lane=i%3;
        const start=3.2+wave*.8-lane*.09;
        const p=clamp((t-start)/.84);
        card.visible=t>=start&&p<.99;
        const a=lane*2.094+wave*.8+p*2.7;
        const r=6.5*(1-ease(p))+.05;
        card.position.set(Math.cos(a)*r,Math.sin(a)*r*.55-.35,3.2*(1-p)-.1);
        const size=1.25*(1-smooth((p-.52)/.48));
        card.scale.setScalar(Math.max(.015,size));
        card.rotation.set(Math.sin(a)*.25,Math.cos(a)*.35,a*.13+p*.8);
        card.material.opacity=1-smooth((p-.82)/.18);
      });
    }else if(t<6.4){
      const p=ease((t-5.6)/.8);
      pair.visible=false;shadows.visible=false;ring.visible=true;
      ring.position.set(0,0,-1);ring.rotation.set(1.2+p*.8,.3,p*1.5);
      ring.scale.setScalar(1+.28*p);
      setCamera(v3(0,0,8),v3(0,0,0),38);
    }else if(t<8){
      const p=smooth((t-6.4)/1.6);
      pair.position.set(0,-1.5,0);pair.rotation.y=lerp(-.3,.3,p);
      pair.rotation.z=lerp(.1,-.07,p);
      setCamera(v3(lerp(-.8,.9,p),.35,4.25),v3(0,-.1,0),40);
    }else if(t<9.6){
      pair.position.set(0,-.5,0);pair.rotation.y=Math.sin((t-8)*4)*.16;
      pair.rotation.z=Math.sin((t-8)*5)*.065;
      setCamera(v3(0,.28,lerp(7.7,7.3,ease((t-8)/1.6))),v3(0,0,0),38);
      hit=8;amp=1.85;
    }else{
      const s=t-9.6,p=ease(s/.65);
      pair.position.set(0,1.25,0);pair.scale.setScalar(lerp(1.16,.73,p));
      pair.rotation.y=lerp(-.35,.08,p);pair.rotation.z=lerp(.14,0,p);
      setCamera(v3(0,.2,8.2),v3(0,.2,0),38);
      hit=s<1.6?9.6:11.2;amp=s<1.6?.35:.28;
    }
    deform(t,hit,amp);
    shadows.position.copy(pair.position);shadows.scale.copy(pair.scale);shadows.rotation.y=pair.rotation.y;
    renderer.render(scene,camera);
  }
  render(0);
  return {render,renderer,scene,camera};
}
