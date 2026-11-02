// Original 132 BPM electro / funky-house score, synthesized without samples.
// Rebuild: node output/promo-buffera/audio-energetic.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const rate = 48000;
const seconds = 24;
const count = rate * seconds;
const beat = 60 / 132;
const tau = Math.PI * 2;
const music = [new Float64Array(count), new Float64Array(count)];
const drums = [new Float64Array(count), new Float64Array(count)];
const effects = [new Float64Array(count), new Float64Array(count)];
const send = [new Float64Array(count), new Float64Array(count)];
const kicks = [];
let seed = 1322026;
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
function kick(start, level = .66) {
  kicks.push(start);
  let phase = 0, air = 0;
  event(drums, start, .42, t => {
    phase += tau * (49 + 116 * Math.exp(-t * 35)) / rate;
    air += .6 * (noise() - air);
    const body = Math.sin(phase) * Math.exp(-t * 12.5);
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
function bass(start, note, duration = .19, level = .24) {
  const f = hz(note);
  event(music, start, duration, t => {
    const p = tau*f*t;
    const cutoff = Math.exp(-t*9);
    const wave = Math.sin(p)+.30*Math.sin(2*p)+cutoff*(.19*Math.sin(3*p)+.08*Math.sin(4*p)+.04*Math.sin(6*p));
    const env = smooth(t/.003)*Math.exp(-t*3)*smooth((duration-t)/.035);
    return Math.tanh(wave*1.25)*env;
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
    // A warm plucked synth with a gentle upper octave, rather than a pure beep.
    const p=tau*f*t;
    const pluck = Math.sin(p+.35*Math.sin(p*2)*Math.exp(-t*17));
    const shimmer = .19*Math.sin(p*2.002)*Math.exp(-t*13)+.10*Math.sin(p*3)*Math.exp(-t*22);
    return (pluck+shimmer)*smooth(t/.008)*Math.exp(-t*7.5)*smooth((duration-t)/.045);
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
  },.35,-.08,.12);
}
const progression = [
  {root:38, tones:[62,66,69,73], melody:[74,78,81,78,76,73]},
  {root:35, tones:[59,62,66,69], melody:[74,78,81,78,74,73]},
  {root:31, tones:[59,62,66,69], melody:[79,78,74,78,81,78]},
  {root:33, tones:[61,64,66,69], melody:[76,78,81,83,81,78]},
];
function groove(start, end, intensity=1, progressionStart=0) {
  const beats=(end-start)/beat;
  for(let b=0;b<beats;b++) {
    const t=start+b*beat;
    kick(t,.59*intensity);
    if(b%2===1) clap(t,.28*intensity);
    for(let sub=0;sub<4;sub++) {
      const when=t+sub*beat/4;
      if(when>=end)continue;
      const open=sub===2;
      hat(when,open,([.045,.027,.085,.037][sub])*intensity,sub%2?-.25:.25);
      if(sub===1||sub===3)shaker(when+.009,.022*intensity,sub===1?.42:-.42);
    }
  }
  for(let bar=0;start+bar*beat*4<end;bar++) {
    const from=start+bar*beat*4;
    const harmony=progression[(bar+progressionStart)%4];
    const pattern=[[0,0,.31],[.75,12,.17],[1.5,0,.18],[1.75,7,.13],[2.5,0,.20],[3,12,.16],[3.5,7,.14]];
    for(const [offset,interval,duration] of pattern) {
      if(from+offset*beat<end-.03) bass(from+offset*beat,harmony.root+interval,duration,.255*intensity);
    }
    for(const offset of [.5,1.5,2.25,3.5]) {
      if(from+offset*beat<end-.08) chord(from+offset*beat,harmony.tones,.054*intensity);
    }
    const phrase=[0,.75,1.5,2.25,2.75,3.5];
    phrase.forEach((offset,j)=>{
      if(from+offset*beat<end-.09)lead(from+offset*beat,harmony.melody[j],.115*intensity,.37,j%2?.17:-.17);
    });
  }
}

// Opening groove enters immediately, with a filtered, restrained density.
groove(0,3.05,.63);
sweep(2.65,.58,.16,.15);
// The hero reveal opens up the arrangement.
groove(3.2,12.65,1,0);
spring(4.4);
for(const [time,note] of [[7,78],[8.5,81],[10,86],[11.3,81]]) {
  lead(time,note,.16,.52,time<8?-.3:.3);
  sweep(time-.15,.24,.08);
}
// Leave a deliberate beat of comic space under the first punchline.
chord(12.8,[62,66,69,73],.08,.25);
event(effects,12.8,.16,t=>Math.sin(tau*(210*t-170*t*t))*Math.exp(-t*20)*smooth(t/.002),.15);
groove(13.25,18.95,.96,2);
chord(15.6,[61,64,69,73],.075,.45);
sweep(18.55,.55,.19,-.2);
// Brand lockup: tonic resolution and one final two-bar drive.
groove(19.1,22.68,1.03,0);
chord(19.1,[50,62,66,69,73,76],.062,1.15);
const cadence=22.736;
kick(cadence,.54);
bass(cadence,38,.7,.29);
chord(cadence,[50,62,66,69,73,76],.085,1.2);
lead(cadence,86,.09,.85,.2);
sweep(cadence,.65,.10);

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
  const breakFade=t>=12.72&&t<13.25 ? smooth((12.82-t)/.1)*.7 : 1;
  const fade=smooth(t/.006)*smooth((seconds-t)/.35);
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
const output=path.join(path.dirname(fileURLToPath(import.meta.url)),'soundtrack-energetic-raw.wav');
fs.writeFileSync(output,wav);
console.log(JSON.stringify({output,seconds,bpm:132,sampleRate:rate,channels:2,samplePeakDBFS:-2,rmsDBFS:20*Math.log10(Math.sqrt(sum/(count*2))*gain)},null,2));
