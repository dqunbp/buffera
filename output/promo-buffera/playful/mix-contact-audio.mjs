import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const directory = path.dirname(fileURLToPath(import.meta.url));
const file = name => path.join(directory, name);
function ffmpeg(args) {
  const result = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-y', ...args], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stderr;
}

// Keep the recorded timing and pitch. The outer silence has no useful vocal detail.
ffmpeg(['-i', file('assets/female-sigh.mp3'), '-af',
  'atrim=start=0.25:end=1.05,asetpts=PTS-STARTPTS,highpass=f=90,lowpass=f=11000,volume=18dB,afade=t=in:d=0.015,afade=t=out:st=0.72:d=0.08,aecho=0.95:1:35|57:0.055|0.03',
  '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s24le', file('assets/female-sigh-contact.wav')]);

// One breath at contact. A gradual 2.5 dB duck gives the quiet recording room.
const duck = "volume='pow(10,-2.5/20*min(1,max(0,(t-8.36)/0.1))*min(1,max(0,(9.32-t)/0.2)))':eval=frame";
ffmpeg(['-i', file('soundtrack-contact-bed.wav'), '-i', file('assets/female-sigh-contact.wav'),
  '-filter_complex', `[0:a]${duck}[bed];[1:a]adelay=8350:all=1[breath];[bed][breath]amix=inputs=2:duration=first:normalize=0,atrim=end_sample=768000[mix]`,
  '-map', '[mix]', '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s24le', file('soundtrack-contact-premaster.wav')]);

const analysisLog = ffmpeg(['-i', file('soundtrack-contact-premaster.wav'), '-af',
  'loudnorm=I=-16:TP=-1.7:LRA=8:print_format=json', '-f', 'null', '-']);
const match = analysisLog.match(/\{\s*"input_i"[\s\S]*?\}/);
if (!match) throw new Error('Missing loudness measurement');
const measured = JSON.parse(match[0]);
const master = `loudnorm=I=-16:TP=-1.7:LRA=8:measured_I=${measured.input_i}:measured_TP=${measured.input_tp}:measured_LRA=${measured.input_lra}:measured_thresh=${measured.input_thresh}:offset=${measured.target_offset}:linear=true:print_format=json`;
const masterLog = ffmpeg(['-i', file('soundtrack-contact-premaster.wav'), '-af', master,
  '-ar', '48000', '-ac', '2', '-t', '16', '-c:a', 'pcm_s24le', file('soundtrack-contact.wav')]);
const verifyLog = ffmpeg(['-i', file('soundtrack-contact.wav'), '-af', 'ebur128=peak=true', '-f', 'null', '-']);
fs.writeFileSync(file('audio-contact-levels.log'), `${analysisLog}\n${masterLog}\n${verifyLog}`);
console.log(verifyLog.slice(verifyLog.lastIndexOf('Summary:')));
