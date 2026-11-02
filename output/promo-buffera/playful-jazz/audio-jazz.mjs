import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const directory = path.dirname(fileURLToPath(import.meta.url));
const file = name => path.join(directory, name);
const logs = [];
function ffmpeg(args) {
  const result = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-y', ...args], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stderr;
}
function normalize(input, output, integrated, peak) {
  const settings = `I=${integrated}:TP=${peak}:LRA=8`;
  const analysis = ffmpeg(['-i', input, '-af', `loudnorm=${settings}:print_format=json`, '-f', 'null', '-']);
  const match = analysis.match(/\{\s*"input_i"[\s\S]*?\}/);
  if (!match) throw new Error('Missing loudness measurement');
  const m = JSON.parse(match[0]);
  const filter = `loudnorm=${settings}:measured_I=${m.input_i}:measured_TP=${m.input_tp}:measured_LRA=${m.input_lra}:measured_thresh=${m.input_thresh}:offset=${m.target_offset}:linear=true:print_format=json`;
  const master = ffmpeg(['-i', input, '-af', filter, '-ar', '48000', '-ac', '2', '-t', '16', '-c:a', 'pcm_s24le', output]);
  logs.push(analysis, master);
}

// A real instrumental performance. Preserve its tempo and pitch.
ffmpeg(['-i', file('assets/pink-panther.mp3'), '-af',
  'atrim=start=10:end=26,asetpts=PTS-STARTPTS,afade=t=in:d=0.035,afade=t=out:st=15.15:d=0.85',
  '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s24le', file('soundtrack-jazz-excerpt.wav')]);
normalize(file('soundtrack-jazz-excerpt.wav'), file('soundtrack-jazz-bed.wav'), -17, -3);

// Same single recorded sigh as the previous cut. No resynthesis or pitch shift.
// +5.5 dB at the source; the final gain raises it about 6 dB versus the prior master.
ffmpeg(['-i', file('assets/female-sigh.mp3'), '-af',
  'atrim=start=0.25:end=1.05,asetpts=PTS-STARTPTS,highpass=f=90,lowpass=f=11000,volume=23.5dB,afade=t=in:d=0.015,afade=t=out:st=0.72:d=0.08,aecho=0.95:1:35|57:0.055|0.03',
  '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s24le', file('assets/female-sigh-jazz.wav')]);

// A short, quiet copy-contact tick; no tonal boing or vocal-like synthesis.
ffmpeg(['-f', 'lavfi', '-i', 'anoisesrc=color=pink:sample_rate=48000:duration=0.045:amplitude=0.3:seed=936', '-af',
  'highpass=f=500,lowpass=f=3500,afade=t=in:d=0.001,afade=t=out:st=0.002:d=0.043,volume=0.35',
  '-ac', '2', '-c:a', 'pcm_s24le', file('assets/copy-tick.wav')]);

const duck = "volume='pow(10,-5/20*min(1,max(0,(t-8.40)/0.10))*min(1,max(0,(9.45-t)/0.22)))':eval=frame";
ffmpeg(['-i', file('soundtrack-jazz-bed.wav'), '-i', file('assets/female-sigh-jazz.wav'), '-i', file('assets/copy-tick.wav'),
  '-filter_complex', `[0:a]${duck}[bed];[1:a]adelay=8450:all=1[breath];[2:a]adelay=650:all=1[tick];[bed][breath][tick]amix=inputs=3:duration=first:normalize=0,atrim=end_sample=768000[mix]`,
  '-map', '[mix]', '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s24le', file('soundtrack-jazz-premaster.wav')]);
normalize(file('soundtrack-jazz-premaster.wav'), file('soundtrack-jazz.wav'), -16, -1.7);
const verify = ffmpeg(['-i', file('soundtrack-jazz.wav'), '-af', 'ebur128=peak=true', '-f', 'null', '-']);
logs.push(verify);
fs.writeFileSync(file('audio-jazz-levels.log'), logs.join('\n'));
console.log(verify.slice(verify.lastIndexOf('Summary:')));
