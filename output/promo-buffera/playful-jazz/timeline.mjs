export const FPS = 60;
export const DURATION = 16;
export const SHOTS = [
  {id:'copy', start:0, duration:3},
  {id:'find', start:3, duration:2.6},
  {id:'insert', start:5.6, duration:5.2},
  {id:'result', start:10.8, duration:2.2},
  {id:'brand', start:13, duration:3},
].map((shot,index)=>({...shot,index,end:shot.start+shot.duration}));
export function shotAt(time){
  const t=Math.max(0,Math.min(DURATION-1e-8,time));
  const shot=SHOTS.find(s=>t<s.end)??SHOTS.at(-1);
  return {...shot,local:t-shot.start,progress:(t-shot.start)/shot.duration};
}
export const ACTIONS={copy:.65,found:4.05,approach:6.5,insert:7.9,settle:9.3,paste:11.2,brand:13.15};
