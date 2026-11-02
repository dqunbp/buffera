// Original 150 BPM electro/bass film score, synthesized without samples.
// Rebuild: node output/promo-buffera/wow/audio-wow-sculpture.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const rate = 48000;
const seconds = 12.8;
const count = rate * seconds;
const beat = 60 / 150;
const tau = Math.PI * 2;
const music = [new Float64Array(count), new Float64Array(count)];
const drums = [new Float64Array(count), new Float64Array(count)];
const effects = [new Float64Array(count), new Float64Array(count)];
const send = [new Float64Array(count), new Float64Array(count)];
const kicks = [];
let seed = 1502026;
function noise() {
  seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
  return (seed >>> 0) / 2147483648 - 1;
}
function hz(note) { return 440 * 2 ** ((note - 69) / 12); }
function smooth(v) { v = Math.max(0, Math.min(1, v)); return v * v * (3 - 2 * v); }
function event(bus, start, duration, synth, level, pan = 0, wet = 0) {
  const offset = Math.round(start * rate);
  const length = Math.round(duration * rate);
  const gains = [Math.cos((pan + 1) * Math.PI / 4), Math.sin((pan + 1) * Math.PI / 4)];
  for (let n = 0; n < length && offset + n < count; n++) {
    if (offset + n < 0) continue;
    const sample = synth(n / rate, n) * level * smooth((duration - n / rate) / .008);
    for (let ch = 0; ch < 2; ch++) {
      bus[ch][offset + n] += sample * gains[ch];
      send[ch][offset + n] += sample * gains[ch] * wet;
    }
  }
}
function kick(start, level = .72) {
  kicks.push(start);
  let phase = 0, air = 0;
  event(drums, start, .42, t => {
    phase += tau * (46 + 145 * Math.exp(-t * 39)) / rate;
    air += .6 * (noise() - air);
    const body = Math.tanh(Math.sin(phase)*1.45) * Math.exp(-t * 14);
    const attack = air * Math.exp(-t * 230) * .19;
    return (body + attack) * smooth(t / .0015);
  }, level);
}
function clap(start, level = .26) {
  let low = 0, high = 0;
  event(drums, start, .25, t => {
    low += .34 * (noise() - low);
    high += .06 * (low - high);
    const bursts = [0, .009, .019].reduce((v, d) => v + (t < d ? 0 : Math.exp(-(t-d)*240)), 0);
    const tail = t < .027 ? 0 : .6 * Math.exp(-(t-.027)*27);
    return (low - high) * (bursts + tail) * smooth(t/.0008);
  }, level, 0, .12);
  event(drums, start, .13, t => Math.sin(tau*181*t)*Math.exp(-t*35)*smooth(t/.001), level*.17);
}
function hat(start, open = false, level = .055, pan = 0) {
  let filtered = 0;
  const duration = open ? .24 : .065;
  event(drums, start, duration, t => {
    const n = noise(); filtered += .22 * (n - filtered);
    const metal = Math.sin(tau*6941*t)*Math.sin(tau*4237*t)*.12;
    return ((n-filtered)*.8+metal)*Math.exp(-t*(open?17:70))*smooth(t/.001);
  }, level, pan, open?.11:.025);
}
function shaker(start, level = .026, pan = .3) {
  let previous = 0;
  event(drums, start, .075, t => {
    const n = noise(); const out = n - previous; previous=n;
    return out*Math.sin(Math.PI*t/.075)**2;
  }, level, pan, .025);
}
function bass(start, note, duration = .19, level = .28) {
  const f = hz(note);
  event(music, start, duration, t => {
    const p = tau*f*t;
    const cutoff = Math.exp(-t*12);
    const wave = Math.sin(p)+.32*Math.sin(2*p)+cutoff*(.30*Math.sin(3*p)+.16*Math.sin(4*p)+.07*Math.sin(6*p));
    const env = smooth(t/.003)*Math.exp(-t*2)*smooth((duration-t)/.025);
    return Math.tanh(wave*1.65)*env;
  }, level);
}
function chord(start, notes, level = .045, duration = .42) {
  notes.forEach((note, i) => {
    const f = hz(note);
    event(music, start, duration, t => {
      let v=0;
      for(let harmonic=1;harmonic<=7;harmonic++) {
        const decay = Math.exp(-t*(5+harmonic*3));
        v += Math.sin(tau*f*harmonic*t+i*.2)*decay/harmonic;
        v += .3*Math.sin(tau*f*1.0025*harmonic*t+i*.4)*decay/harmonic;
      }
      return Math.tanh(v*1.1)*smooth(t/.009)*smooth((duration-t)/.08);
    },level,(i/(notes.length-1)-.5)*1.2,.24);
  });
}
function lead(start, note, level = .11, duration = .38, pan = 0) {
  const f = hz(note);
  event(music, start, duration, t => {
    // Midrange analogue-style bite: harmonically rich and rapidly closing filter.
    const p=tau*f*t;
    const pluck = .64*Math.sin(p)+.25*Math.sin(p*1.004+.2);
    const shimmer = .34*Math.sin(p*2.002)*Math.exp(-t*10)+.23*Math.sin(p*3)*Math.exp(-t*17)+.09*Math.sin(p*5)*Math.exp(-t*24);
    return Math.tanh((pluck+shimmer)*1.5)*smooth(t/.006)*Math.exp(-t*5.5)*smooth((duration-t)/.035);
  },level,pan,.32);
}
function sweep(start, duration, level = .13, pan = 0) {
  let low=0, high=0;
  event(effects, start, duration, t => {
    const p=t/duration;
    low += (.025+.3*p)*(noise()-low);
    high += .01*(low-high);
    return (low-high)*Math.sin(Math.PI*p)**1.8;
  },level,pan,.22);
}
function spring(start) {
  let phase=0;
  event(effects,start,.95,t=>{
    const f=140+270*Math.exp(-t*12)+64*Math.sin(tau*9*t)*Math.exp(-t*5);
    phase+=tau*f/rate;
    return (Math.sin(phase)+.18*Math.sin(phase*2))*smooth(t/.003)*Math.exp(-t*5.4);
  },.47,-.08,.12);
}
const progression = [
  {root:30, tones:[54,57,61,66], melody:[66,66,69,73,69,66]},
  {root:33, tones:[57,61,64,69], melody:[69,69,73,76,73,69]},
  {root:26, tones:[54,57,62,66], melody:[66,69,74,73,69,66]},
  {root:28, tones:[52,56,59,64], melody:[64,68,71,73,71,68]},
];
function groove(start, end, intensity=1, progressionStart=0) {
  const beats=(end-start)/beat;
  for(let b=0;b<beats;b++) {
    const t=start+b*beat;
    kick(t,.72*intensity);
    if(b%2===1) clap(t,.41*intensity);
    for(let sub=0;sub<4;sub++) {
      const when=t+sub*beat/4;
      if(when>=end)continue;
      const open=sub===2;
      hat(when,open,([.06,.027,.10,.045][sub])*intensity,sub%2?-.25:.25);
      if(sub===1||sub===3)shaker(when+.009,.022*intensity,sub===1?.42:-.42);
    }
  }
  for(let bar=0;start+bar*beat*4<end;bar++) {
    const from=start+bar*beat*4;
    const harmony=progression[(bar+progressionStart)%4];
    const pattern=[[.25,0,.24],[1,0,.16],[1.5,12,.15],[1.75,0,.10],[2.25,0,.19],[3,7,.17],[3.5,12,.12],[3.75,7,.09]];
    for(const [offset,interval,duration] of pattern) {
      if(from+offset*beat<end-.03) bass(from+offset*beat,harmony.root+interval,duration,.32*intensity);
    }
    for(const offset of [.5,2.5]) {
      if(from+offset*beat<end-.08) chord(from+offset*beat,harmony.tones,.065*intensity,.32);
    }
    const phrase=[0,.75,1.5,2,2.75,3.5];
    phrase.forEach((offset,j)=>{
      if(from+offset*beat<end-.09)lead(from+offset*beat,harmony.melody[j],.14*intensity,j===3?.4:.22,j%2?.17:-.17);
    });
  }
}

function impact(start, strength=1) {
  let phase=0, low=0;
  event(effects,start,.7,t=>{
    phase+=tau*(43+74*Math.exp(-t*21))/rate;
    low+=.16*(noise()-low);
    return (Math.sin(phase)*Math.exp(-t*8.5)+low*.34*Math.exp(-t*24))*smooth(t/.002);
  },.25*strength,0,.17);
}
function suction(end, duration=.32, pan=0) {
  let low=0, phase=0;
  event(effects,end-duration,duration,t=>{
    const p=t/duration;
    low+=(.025+.34*p)*(noise()-low);
    phase+=tau*(110+780*p*p)/rate;
    return (low*.9+Math.sin(phase)*.11)*smooth(p)*smooth((1-p)/.035);
  },.28,pan,.14);
}
function ratchet(start) {
  [.0,.075,.125,.163].forEach((offset,i)=>{
    hat(start+offset,false,.08+i*.018,i%2?.45:-.45);
    bass(start+offset,42,.05,.13+i*.015);
  });
}

// Eight bars. Each major cut lands on a downbeat: nothing is time-stretched.
groove(0,1.4,.79,0);
impact(0,.6);
suction(1.6,.42,.2);
ratchet(1.4);
groove(1.6,3.0,1,0);
impact(1.6,.8);
spring(2.0);
ratchet(3.0);
suction(3.2,.28,-.3);

// The vortex gets a rising bass variation and short reverse-like sweeps.
groove(3.2,5.6,1.07,1);
for(const [time,note,pan] of [[3.2,69,-.45],[4.0,73,.45],[4.8,76,-.3]]) {
  suction(time,.24,pan);
  chord(time,[note-12,note-5,note],.072,.22);
  impact(time,.55);
}
// The retrieved item gets a hard cut, bass punctuation, and a compact fill.
kick(5.6,.8);
clap(5.6,.43);
bass(5.6,30,.22,.36);
chord(5.6,[54,57,61,66],.09,.38);
hat(5.8,true,.08,.3);
kick(6.0,.61);
ratchet(6.2);

// Setup: a half-time groove creates a readable punchline, not dead silence.
kick(6.4,.76);
bass(6.45,30,.31,.34);
lead(6.4,66,.16,.3,-.15);
clap(6.8,.36);
hat(6.6,true,.08,.3);
hat(6.9,false,.05,-.3);
bass(7.0,42,.16,.25);
kick(7.2,.65);
lead(7.2,69,.13,.25,.15);
clap(7.6,.32);
for(const t of [7.5,7.6,7.7])hat(t,false,.055+(t-7.5)*.1,.25);
suction(8,.45,-.25);

// Rejoinder: impact, elastic low-end drop, and the riff at full force.
groove(8,9.4,1.12,0);
impact(8,1.45);
spring(8.02);
ratchet(9.4);
suction(9.6,.3,.3);

// Brand: the melody opens out, then an unmistakable musical finish at 11.2.
groove(9.6,11.1,1.02,0);
chord(9.6,[54,57,61,66,73],.078,.75);
impact(9.6,.75);
const cadence=11.2;
kick(cadence,.77);
bass(cadence,30,.85,.34);
chord(cadence,[42,54,57,61,66,73],.095,1.5);
lead(cadence,78,.085,.85,.2);
impact(cadence,1);
sweep(cadence,.9,.15,-.2);

// Compact stereo room and rhythmic tap, only on musical/high-frequency sources.
for(const [delay,level,cross] of [[.058,.22,false],[.097,.17,true],[.146,.13,false],[beat*.75,.20,true],[beat*1.5,.10,false],[.61,.07,true]]) {
  const shift=Math.round(delay*rate);
  for(let ch=0;ch<2;ch++) {
    let low=0;
    const source=send[cross?1-ch:ch];
    for(let i=shift;i<count;i++) {
      low+=.34*(source[i-shift]-low);
      music[ch][i]+=low*level;
    }
  }
}
kicks.sort((a,b)=>a-b);
let current=-100, next=0, peak=0, sum=0;
const result=[new Float64Array(count),new Float64Array(count)];
for(let i=0;i<count;i++) {
  const t=i/rate;
  while(next<kicks.length && kicks[next]<=t) current=kicks[next++];
  const duck=1-.57*Math.exp(-(t-current)*20);
  // A 90ms vacuum before the drop sharpens the impact without a long pause.
  const breakFade=t>=7.87&&t<8 ? smooth((7.96-t)/.09) : 1;
  const fade=smooth(t/.004)*smooth((seconds-t)/.45);
  for(let ch=0;ch<2;ch++) {
    const musical=music[ch][i]*duck*breakFade;
    const v=Math.tanh((musical+drums[ch][i]*breakFade+effects[ch][i])*.95)*fade;
    result[ch][i]=v;
    peak=Math.max(peak,Math.abs(v));
    sum+=v*v;
  }
}
const gain=10**(-2/20)/peak;
const wav=Buffer.alloc(44+count*4);
wav.write('RIFF',0);wav.writeUInt32LE(wav.length-8,4);wav.write('WAVE',8);
wav.write('fmt ',12);wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(2,22);
wav.writeUInt32LE(rate,24);wav.writeUInt32LE(rate*4,28);wav.writeUInt16LE(4,32);wav.writeUInt16LE(16,34);
wav.write('data',36);wav.writeUInt32LE(count*4,40);
for(let i=0;i<count;i++)for(let ch=0;ch<2;ch++) {
  const v=Math.max(-1,Math.min(1,result[ch][i]*gain+(noise()+noise())/65536));
  wav.writeInt16LE(Math.round(v*32767),44+(i*2+ch)*2);
}
const output=path.join(path.dirname(fileURLToPath(import.meta.url)),'soundtrack-wow-raw-sculpture.wav');
fs.writeFileSync(output,wav);
console.log(JSON.stringify({output,seconds,bpm:150,sampleRate:rate,channels:2,samplePeakDBFS:-2,rmsDBFS:20*Math.log10(Math.sqrt(sum/(count*2))*gain)},null,2));
