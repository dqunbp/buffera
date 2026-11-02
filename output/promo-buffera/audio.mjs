// Original Buffera promo score and sound design. No samples or external assets.
// Rebuild: node output/promo-buffera/audio.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const sampleRate = 48000;
const duration = 24;
const length = sampleRate * duration;
const channels = [new Float64Array(length), new Float64Array(length)];
const ambience = [new Float64Array(length), new Float64Array(length)];
const tau = 2 * Math.PI;
let seed = 0x42554646;
function random() {
  seed ^= seed << 13;
  seed ^= seed >>> 17;
  seed ^= seed << 5;
  return (seed >>> 0) / 4294967296 * 2 - 1;
}
function midi(note) { return 440 * 2 ** ((note - 69) / 12); }
function smooth(x) { return x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x); }
function event(start, seconds, synth, gain = 1, pan = 0, wet = 0.18) {
  const first = Math.round(start * sampleRate);
  const n = Math.round(seconds * sampleRate);
  const l = Math.cos((pan + 1) * Math.PI / 4);
  const r = Math.sin((pan + 1) * Math.PI / 4);
  for (let j = 0; j < n; j++) {
    const i = first + j;
    if (i < 0 || i >= length) continue;
    const value = synth(j / sampleRate, j) * gain;
    channels[0][i] += value * l;
    channels[1][i] += value * r;
    ambience[0][i] += value * l * wet;
    ambience[1][i] += value * r * wet;
  }
}

// Satin-soft major ninth harmonies, with independently drifting voices.
function pad(start, seconds, notes, gain = 0.045) {
  notes.forEach((note, index) => {
    const frequency = midi(note);
    event(start, seconds, t => {
      const envelope = smooth(t / 1.6) * smooth((seconds - t) / 1.8);
      const phase = tau * frequency * t;
      const detuned = Math.sin(phase * 1.0012 + index * 0.7);
      const fundamental = Math.sin(phase + 0.09 * Math.sin(tau * 0.3 * t));
      const upper = 0.12 * Math.sin(2 * phase + 0.8);
      return (0.6 * fundamental + 0.4 * detuned + upper) * envelope;
    }, gain, (index / (notes.length - 1) - 0.5) * 1.25, 0.42);
  });
}

// Rounded low pulse: no sawtooth edge or aggressive compression.
function bass(start, note, seconds = 0.75, gain = 0.16) {
  const f = midi(note);
  event(start, seconds, t => {
    const envelope = smooth(t / 0.018) * Math.exp(-t * 3.6) * smooth((seconds - t) / 0.1);
    return (Math.sin(tau * f * t) + 0.15 * Math.sin(tau * 2 * f * t)) * envelope;
  }, gain, 0, 0.025);
}

// A glass/mallet voice: softly struck, lightly inharmonic, long airy tail.
function glass(start, note, gain = 0.12, pan = 0) {
  const f = midi(note);
  event(start, 2.6, t => {
    const attack = smooth(t / 0.007);
    const body = Math.sin(tau * f * t + 0.62 * Math.exp(-t * 12) * Math.sin(tau * f * 2 * t));
    const bell = Math.sin(tau * f * 2.006 * t) * 0.24 * Math.exp(-t * 5);
    const air = Math.sin(tau * f * 3.991 * t) * 0.055 * Math.exp(-t * 9);
    return attack * (body * Math.exp(-t * 2.9) + bell + air) * smooth((2.6 - t) / 0.15);
  }, gain, pan, 0.5);
}

function tap(start, gain = 0.022, pan = 0) {
  let filtered = 0;
  event(start, 0.055, (t) => {
    const n = random();
    filtered = 0.82 * filtered + 0.18 * n;
    return (n - filtered) * Math.exp(-t * 110) * smooth(t / 0.0007);
  }, gain, pan, 0.18);
}

function kick(start, gain = 0.11) {
  let phase = 0;
  event(start, 0.28, t => {
    const f = 49 + 60 * Math.exp(-t * 45);
    phase += tau * f / sampleRate;
    return Math.sin(phase) * Math.exp(-t * 17) * smooth(t / 0.003);
  }, gain, 0, 0);
}

// Air crossing the stereo field. Low-pass noise avoids a harsh hiss.
function sweep(start, seconds, gain = 0.06, pan = 0) {
  let low = 0;
  let slower = 0;
  event(start, seconds, t => {
    const p = t / seconds;
    const rate = 0.03 + 0.22 * Math.sin(Math.PI * p) ** 2;
    low += rate * (random() - low);
    slower += 0.008 * (low - slower);
    return (low - slower) * Math.sin(Math.PI * p) ** 2;
  }, gain, pan, 0.65);
}

// Elastic, restrained spring accent at the on-screen poke.
function spring(start) {
  let phase = 0;
  event(start, 1.02, t => {
    const f = 128 + 250 * Math.exp(-t * 11) + 46 * Math.sin(tau * 8.5 * t) * Math.exp(-t * 4.8);
    phase += tau * f / sampleRate;
    const tone = Math.sin(phase) + 0.24 * Math.sin(phase * 2.01) * Math.exp(-t * 6);
    return tone * smooth(t / 0.004) * Math.exp(-t * 5.1) * smooth((1.02 - t) / 0.1);
  }, 0.19, -0.05, 0.18);
  tap(start, 0.05, -0.1);
}

// Intro: an intimate, slow reveal. Score begins with space around the mark.
pad(0, 7.9, [50, 57, 61, 66, 76], 0.036);
sweep(0.15, 2.8, 0.1, -0.35);
glass(0.65, 86, 0.045, 0.35);
glass(2.65, 81, 0.055, -0.3);
sweep(2.85, 0.65, 0.08, 0.35);
bass(3.2, 38, 1.2, 0.17);
glass(3.2, 78, 0.13, -0.16);
glass(3.45, 81, 0.07, 0.2);
spring(4.4);
glass(5.2, 73, 0.07, 0.25);
bass(5.7, 45, 0.7, 0.09);

// Cards: 120 BPM pulse and a concise ascending signature.
pad(6.35, 7.15, [47, 54, 57, 61, 66], 0.039);
sweep(6.35, 0.8, 0.11, -0.3);
const bassGrid = [[7,35],[8,42],[9,35],[10,42],[11,38],[12,45]];
for (const [time,note] of bassGrid) { bass(time,note); kick(time,0.07); }
for (let t = 7.25, k = 0; t < 12.5; t += 0.5, k++) tap(t,0.019,k % 2 ? -0.35 : 0.35);
glass(7, 74, 0.135, -0.3);
glass(7.75, 78, 0.065, 0.25);
glass(8.5, 78, 0.14, 0.15);
glass(9.25, 81, 0.06, -0.2);
glass(10, 81, 0.14, 0.3);
glass(10.75, 78, 0.062, -0.2);
sweep(10.9, 0.65, 0.075, 0.3);
glass(11.3, 86, 0.145, 0.05);
glass(11.55, 81, 0.06, -0.2);
glass(12, 78, 0.052, 0.25);

// Comic line: a tiny pause and a dry punctuation, never a comedy sting.
pad(12.6, 6.8, [43, 50, 57, 59, 66], 0.036);
sweep(12.35, 0.7, 0.075, -0.3);
bass(12.8,31,1.0,0.16);
glass(12.8,79,0.11,-0.18);
tap(12.8,0.026,0.15);
glass(14.3,74,0.075,0.25);
bass(14.3,38,0.75,0.1);

// The rejoinder clicks into place, then leads into the warm closing chord.
glass(15.6,81,0.13,0.18);
tap(15.6,0.038,-0.12);
bass(15.6,33,1.0,0.15);
pad(15.6,4.2,[45,52,57,62,64],0.027);
glass(16.35,76,0.075,-0.25);
bass(16.6,40,0.75,0.1);
glass(17.1,78,0.09,0.2);
bass(17.6,45,0.8,0.09);
glass(17.85,81,0.075,-0.15);
sweep(18.25,1.1,0.1,0.25);

// Final logo resolve; a bespoke five-note signature, not a borrowed mnemonic.
pad(18.8,5.2,[38,50,57,61,66],0.047);
bass(19.1,38,1.8,0.19);
kick(19.1,0.075);
glass(19.1,74,0.13,-0.22);
glass(19.35,78,0.09,0.22);
glass(19.6,81,0.08,-0.15);
glass(20.1,76,0.075,0.2);
glass(20.6,86,0.085,0.1);
sweep(20.4,2.2,0.035,-0.2);

// Diffuse stereo echoes: no feedback accumulation, no tail beyond 24 s.
const taps = [
  [0.073,0.24,false],[0.113,0.21,true],[0.173,0.18,false],
  [0.251,0.16,true],[0.337,0.13,false],[0.461,0.10,true],
  [0.619,0.078,false],[0.821,0.052,true],[1.109,0.031,false],
];
for (const [delay,gain,cross] of taps) {
  const shift = Math.round(delay * sampleRate);
  for (let ch=0;ch<2;ch++) {
    let smoothed = 0;
    const source = ambience[cross ? 1-ch : ch];
    for(let i=shift;i<length;i++) {
      smoothed += 0.25 * (source[i-shift] - smoothed);
      channels[ch][i] += gain * smoothed;
    }
  }
}

// A gentle final fade and conservative peak normalization.
let peak=0, sum=0;
for(let i=0;i<length;i++) {
  const t=i/sampleRate;
  const fade=smooth(t/0.03)*smooth((24-t)/1.5);
  for(let ch=0;ch<2;ch++) {
    channels[ch][i] *= fade;
    peak=Math.max(peak,Math.abs(channels[ch][i]));
    sum += channels[ch][i]**2;
  }
}
const desiredPeak=10**(-1.7/20);
const gain=desiredPeak/peak;
const wav=Buffer.alloc(44+length*4);
wav.write('RIFF',0); wav.writeUInt32LE(wav.length-8,4); wav.write('WAVE',8);
wav.write('fmt ',12); wav.writeUInt32LE(16,16); wav.writeUInt16LE(1,20);
wav.writeUInt16LE(2,22); wav.writeUInt32LE(sampleRate,24);
wav.writeUInt32LE(sampleRate*4,28); wav.writeUInt16LE(4,32); wav.writeUInt16LE(16,34);
wav.write('data',36); wav.writeUInt32LE(length*4,40);
for(let i=0;i<length;i++) for(let ch=0;ch<2;ch++) {
  const dither=(random()+random())/65536;
  const v=Math.max(-1,Math.min(1,channels[ch][i]*gain+dither));
  wav.writeInt16LE(Math.round(v*32767),44+(i*2+ch)*2);
}
const output=path.join(path.dirname(fileURLToPath(import.meta.url)),'soundtrack.wav');
fs.writeFileSync(output,wav);
console.log(JSON.stringify({output,duration,sampleRate,channels:2,bits:16,peakDBFS:-1.7,rmsDBFS:20*Math.log10(Math.sqrt(sum/(length*2))*gain),bytes:wav.length},null,2));
