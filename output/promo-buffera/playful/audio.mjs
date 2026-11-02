// Original slow funk / neo-soul score, with brief comic vocal-like accents.
// No samples, recordings, external assets, or voice impersonation.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DURATION, ACTIONS } from './timeline.mjs';

const rate = 48000;
const count = Math.round(DURATION * rate);
const bpm = 90;
const beat = 60 / bpm;
const bar = 4 * beat;
const tau = 2 * Math.PI;
const music = [new Float64Array(count), new Float64Array(count)];
const drums = [new Float64Array(count), new Float64Array(count)];
const effects = [new Float64Array(count), new Float64Array(count)];
const room = [new Float64Array(count), new Float64Array(count)];
let seed = 903016;
function noise() {
  seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
  return (seed >>> 0) / 2147483648 - 1;
}
const clamp = x => Math.max(0, Math.min(1, x));
const smooth = x => { x=clamp(x); return x*x*(3-2*x); };
const hz = note => 440 * 2 ** ((note - 69) / 12);
function event(bus, start, duration, synth, level=1, pan=0, wet=0) {
  const first = Math.round(start*rate), n = Math.round(duration*rate);
  const gains = [Math.cos((pan+1)*Math.PI/4),Math.sin((pan+1)*Math.PI/4)];
  for(let j=0;j<n && first+j<count;j++) {
    if(first+j<0)continue;
    const t=j/rate;
    const value=synth(t,j)*level*smooth((duration-t)/.012);
    for(let ch=0;ch<2;ch++) {
      bus[ch][first+j]+=value*gains[ch];
      room[ch][first+j]+=value*gains[ch]*wet;
    }
  }
}

function kick(start, level=.39) {
  let phase=0;
  event(drums,start,.35,t=>{
    phase+=tau*(46+53*Math.exp(-t*37))/rate;
    return Math.sin(phase)*Math.exp(-t*13)*smooth(t/.003);
  },level);
}
function rim(start, level=.13) {
  let low=0;
  event(drums,start,.14,t=>{
    low+=.3*(noise()-low);
    const wood=Math.sin(tau*1850*t)+.6*Math.sin(tau*2390*t);
    return (wood*.25*Math.exp(-t*82)+low*.3*Math.exp(-t*37))*smooth(t/.0008);
  },level,.10,.16);
  // Soft hand clap tail, a room rather than a sharp dance snare.
  let filtered=0;
  event(drums,start+.012,.16,t=>{
    filtered+=.15*(noise()-filtered);
    return filtered*Math.exp(-t*29)*smooth(t/.004);
  },level*.72,-.08,.27);
}
function hat(start, level=.035, open=false, pan=.3) {
  let low=0;
  const duration=open?.19:.065;
  event(drums,start,duration,t=>{
    const value=noise();low+=.21*(value-low);
    return (value-low)*Math.exp(-t*(open?21:64))*smooth(t/.0015);
  },level,pan,.08);
}
function brush(start, level=.035, pan=-.3) {
  let low=0, slow=0;
  event(drums,start,.20,t=>{
    low+=.18*(noise()-low);slow+=.03*(low-slow);
    return (low-slow)*Math.sin(Math.PI*t/.2)**1.4;
  },level,pan,.14);
}
function electricBass(start,note,duration=.38,level=.27,slideFrom=note) {
  let phase=0;
  event(music,start,duration,t=>{
    const f=hz(note)+(hz(slideFrom)-hz(note))*Math.exp(-t*32);
    phase+=tau*f/rate;
    const pluck=Math.exp(-t*11);
    const wave=Math.sin(phase)+.24*Math.sin(2*phase)+pluck*(.17*Math.sin(3*phase)+.07*Math.sin(4*phase));
    const env=smooth(t/.004)*Math.exp(-t*1.5)*smooth((duration-t)/.055);
    return Math.tanh(wave*1.2)*env;
  },level,0,.025);
}
function rhodes(start,notes,duration=1.65,level=.052) {
  notes.forEach((note,i)=>{
    const f=hz(note),pan=(i/(notes.length-1)-.5)*1.18;
    event(music,start+i*.007,duration,t=>{
      const p=tau*f*t;
      const tine=Math.sin(p+.7*Math.exp(-t*13)*Math.sin(3*p));
      const body=.64*tine+.19*Math.sin(p*1.002+.4)+.10*Math.sin(2*p)*Math.exp(-t*7);
      const tremolo=.97+.03*Math.sin(tau*4.1*t+i*.7);
      return body*smooth(t/.008)*Math.exp(-t*1.45)*smooth((duration-t)/.18)*tremolo;
    },level,pan,.38);
  });
}
function guitar(start,note,duration=.24,level=.09,pan=-.32) {
  const f=hz(note);
  event(music,start,duration,t=>{
    const p=tau*f*t;
    const wah=3.2+4.6*Math.exp(-t*18);
    let value=0;
    for(let h=1;h<=13;h++){
      const filter=.075+.9*Math.exp(-Math.pow((h-wah)/2.6,2));
      value+=Math.sin(p*h+h*.11)*filter/h;
    }
    return Math.tanh(value*1.4)*Math.exp(-t*13)*smooth(t/.002)*smooth((duration-t)/.04);
  },level,pan,.24);
}
function click(start,level=.10,pan=0) {
  let low=0;
  event(effects,start,.07,t=>{
    low+=.25*(noise()-low);
    return (low*.6+Math.sin(tau*560*t)*.22)*Math.exp(-t*80)*smooth(t/.001);
  },level,pan,.08);
}
function air(start,duration=.3,level=.10,pan=.1) {
  let low=0,high=0;
  event(effects,start,duration,t=>{
    const p=t/duration;
    low+=(.045+.12*Math.sin(Math.PI*p))*(noise()-low);
    high+=.013*(low-high);
    return (low-high)*Math.sin(Math.PI*p)**1.8;
  },level,pan,.20);
}
function spring(start) {
  let phase=0;
  event(effects,start,.58,t=>{
    phase+=tau*(128+110*Math.exp(-t*11)+21*Math.sin(tau*8*t)*Math.exp(-t*7))/rate;
    return (Math.sin(phase)+.12*Math.sin(2*phase))*Math.exp(-t*7)*smooth(t/.004);
  },.14,.05,.10);
}

// A short stylised surprised vowel: only a quarter-second voice-like punctuation.
// Harmonic formants use no human recording and are intentionally light/cartoonish.
function surprisedOh(start) {
  let phase=0;
  event(effects,start,.31,t=>{
    const p=t/.31;
    const fundamental=195+45*Math.sin(Math.PI*clamp(p*1.25));
    phase+=tau*fundamental/rate;
    let value=0;
    for(let h=1;h<=18;h++) {
      const f=h*fundamental;
      const formant=.9*Math.exp(-Math.pow((f-490)/140,2))+.7*Math.exp(-Math.pow((f-960)/180,2))+.22*Math.exp(-Math.pow((f-2450)/290,2));
      value+=Math.sin(phase*h)*formant/Math.sqrt(h);
    }
    const envelope=smooth(t/.025)*smooth((.31-t)/.085);
    return (value*.45+noise()*.025)*envelope;
  },.15,-.04,.15);
}
function reliefExhale(start) {
  let low=0,slow=0;
  event(effects,start,.38,t=>{
    const p=t/.38;
    low+=.13*(noise()-low);slow+=.022*(low-slow);
    return (low-slow)*Math.sin(Math.PI*p)**1.6*(1-.45*p);
  },.21,.06,.12);
}

const harmony=[
  {root:38,notes:[53,57,60,64]},
  {root:31,notes:[53,59,64,69]},
  {root:36,notes:[52,55,59,62]},
  {root:33,notes:[55,61,64,70]},
  {root:38,notes:[53,57,60,64]},
];
for(let b=0;b<5;b++) {
  const start=b*bar,h=harmony[b];
  // Relaxed pocket: sparse kicks, late rimshots, and slightly swung eighths.
  for(const [at,gain] of [[0,.40],[1.65,.23],[2.5,.34],[3.5,.19]])kick(start+at*beat,gain);
  rim(start+beat+.018,.13);rim(start+3*beat+.022,.145);
  for(let n=0;n<8;n++) {
    const when=start+n*.5*beat+(n%2?.038:0);
    hat(when,n%2?.025:.039,n===7,n%2?-.30:.30);
    if(n===3||n===7)brush(when+.016,.025,n===3?.42:-.42);
  }
  for(const [at,interval,duration,gain] of [[.05,0,.48,.28],[.92,0,.21,.18],[1.5,7,.27,.22],[2.28,12,.24,.21],[2.93,7,.31,.20],[3.48,0,.30,.24]]) {
    electricBass(start+at*beat,h.root+interval,duration,gain,interval===12?h.root+7:h.root+interval);
  }
  rhodes(start+.04,h.notes,1.8,.054);
  rhodes(start+1.78*beat,h.notes.map((n,i)=>i===3?n+12:n),1.45,.034);
  guitar(start+.78*beat,h.notes[1]+12,.24,.075,-.38);
  guitar(start+2.68*beat,h.notes[2]+12,.20,.067,.32);
}
// A small descending answer between phrases, with room around every note.
guitar(2.16,76,.23,.085,.25);guitar(2.39,72,.29,.073,-.20);
rhodes(5.42,[60,64,67,71],.85,.028);
guitar(10.03,73,.25,.063,-.3);guitar(10.30,69,.28,.063,.3);

// Action accents sit beneath the score and do not underline every visual cut.
click(ACTIONS.copy,.12,-.18);
click(ACTIONS.found,.075,.15);
air(ACTIONS.approach,.46,.085,-.2);
air(ACTIONS.insert-.16,.38,.12,0);
surprisedOh(8.42);
spring(ACTIONS.settle);
reliefExhale(9.62);
click(ACTIONS.paste,.11,.1);
guitar(ACTIONS.paste+.08,76,.28,.06,.28);

// The sixth bar resolves and breathes, while the final identity stays readable.
const cadence=5*bar;
kick(cadence,.32);electricBass(cadence,38,1.18,.27,40);
rhodes(cadence,[50,53,57,60,64,69],2.66,.065);
guitar(cadence+.45,76,.45,.065,.2);
hat(cadence+.71,.023,true,-.3);
brush(cadence+1.5,.023,.25);

// Short room, subtle stereo taps. The music stays intimate and dry enough.
for(const [delay,gain,cross] of [[.061,.23,false],[.107,.18,true],[.179,.13,false],[.293,.09,true],[beat*.75,.13,true],[.747,.06,false]]) {
  const shift=Math.round(delay*rate);
  for(let ch=0;ch<2;ch++) {
    let low=0;const source=room[cross?1-ch:ch];
    for(let i=shift;i<count;i++){low+=.20*(source[i-shift]-low);music[ch][i]+=low*gain;}
  }
}

const result=[new Float64Array(count),new Float64Array(count)];
let peak=0,sum=0;
for(let i=0;i<count;i++) {
  const t=i/rate;
  // A brief held breath before the single visual gag, not a repeated stop/start.
  const space=(t>7.58&&t<8.04)?1-.68*smooth((t-7.58)/.09)*smooth((8.04-t)/.12):1;
  const vocalSpace=t>8.36&&t<8.80?1-.17*Math.sin(Math.PI*(t-8.36)/.44)**2:1;
  const fade=smooth(t/.014)*smooth((DURATION-t)/.9);
  for(let ch=0;ch<2;ch++) {
    const value=Math.tanh((music[ch][i]*space*vocalSpace+drums[ch][i]*space+effects[ch][i])*.95)*fade;
    result[ch][i]=value;peak=Math.max(peak,Math.abs(value));sum+=value*value;
  }
}
const gain=10**(-2/20)/peak;
const wav=Buffer.alloc(44+count*4);
wav.write('RIFF',0);wav.writeUInt32LE(wav.length-8,4);wav.write('WAVE',8);
wav.write('fmt ',12);wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(2,22);
wav.writeUInt32LE(rate,24);wav.writeUInt32LE(rate*4,28);wav.writeUInt16LE(4,32);wav.writeUInt16LE(16,34);
wav.write('data',36);wav.writeUInt32LE(count*4,40);
for(let i=0;i<count;i++)for(let ch=0;ch<2;ch++) {
  const value=Math.max(-1,Math.min(1,result[ch][i]*gain+(noise()+noise())/65536));
  wav.writeInt16LE(Math.round(value*32767),44+(i*2+ch)*2);
}
const output=path.join(path.dirname(fileURLToPath(import.meta.url)),'soundtrack-raw.wav');
fs.writeFileSync(output,wav);
console.log(JSON.stringify({output,seconds:DURATION,bpm,sampleRate:rate,channels:2,peakDBFS:-2,rmsDBFS:20*Math.log10(Math.sqrt(sum/(count*2))*gain)},null,2));
