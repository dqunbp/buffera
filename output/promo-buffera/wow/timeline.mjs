// Unequal editorial lengths: 52, 84, 136 frames approximate successive phi ratios.
// Longer shots carry retrieval/recognition; quick confirmation shots keep momentum.
export const FPS = 60;
const specification = [
  ['copy1', 84], ['copy2', 52], ['history', 136], ['paste-link', 52],
  ['screenshot', 84], ['extract', 136], ['paste-address', 84], ['end', 140],
];
let frame = 0;
export const SHOTS = specification.map(([id, frames], index) => {
  const startFrame = frame;
  frame += frames;
  return { id, index, frames, startFrame, endFrame: frame, start: startFrame / FPS, duration: frames / FPS };
});
export const DURATION = frame / FPS;
export function shotAt(time) {
  const t = Math.max(0, Math.min(DURATION - 1e-8, time));
  const shot = SHOTS.find(item => t < item.endFrame / FPS) ?? SHOTS.at(-1);
  const local = t - shot.start;
  return { ...shot, local, progress: local / shot.duration };
}
export const ACTIONS = {
  copyLink: .20,
  copyText: SHOTS[1].start + .18,
  historyOpen: SHOTS[2].start + .12,
  linkSelected: SHOTS[2].start + 1.18,
  pasteLink: SHOTS[3].start + .22,
  screenshotCopy: SHOTS[4].start + .22,
  scanStart: SHOTS[5].start + .15,
  textReady: SHOTS[5].start + 1.2,
  pasteAddress: SHOTS[6].start + .22,
  brandSpring: SHOTS[7].start + .08,
};
