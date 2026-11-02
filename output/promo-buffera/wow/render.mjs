import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import path from 'node:path';
import {FPS,DURATION,SHOTS} from './timeline.mjs';

const require=createRequire('/Users/dqunbp/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/package.json');
const {chromium}=require('playwright'),sharp=require('sharp');
const root=path.dirname(fileURLToPath(import.meta.url));
const preview=process.argv.includes('--preview'),fps=FPS,duration=DURATION,frames=Math.round(fps*duration);
const server=createServer(async(req,res)=>{
 try{
  const target=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);
  if(!target.startsWith(root+path.sep)) {res.writeHead(403).end();return}
  const body=await readFile(target);
  const type=target.endsWith('.html')?'text/html':/\.m?js$/.test(target)?'text/javascript':'application/octet-stream';
  res.writeHead(200,{'Content-Type':type}).end(body);
 }catch{res.writeHead(404).end()}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
await mkdir(path.join(root,'review'),{recursive:true});
let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--disable-background-timer-throttling','--disable-renderer-backgrounding']});
 const page=await browser.newPage({viewport:{width:1920,height:1080},deviceScaleFactor:1});
 page.on('pageerror',error=>console.error('PAGE ERROR:',error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/film.html`);
 await page.evaluate(()=>window.__ready);
 await page.evaluate(()=>document.fonts.ready);
 if(preview){
  const history=SHOTS.find(shot=>shot.id==='history');
  const overlapFailures=[];
  for(let frame=history.startFrame;frame<history.endFrame;frame++){
   const state=await page.evaluate(t=>window.inspectFrame(t),frame/fps);
   for(let i=0;i<state.cards.length;i++)for(let j=i+1;j<state.cards.length;j++){
    const a=state.cards[i],b=state.cards[j];
    if(Math.min(a.right,b.right)>Math.max(a.left,b.left)&&Math.min(a.bottom,b.bottom)>Math.max(a.top,b.top))overlapFailures.push({frame,a:a.id,b:b.id});
   }
  }
  await writeFile(path.join(root,'review','history-overlap-check.json'),JSON.stringify({checkedFrames:history.frames,failures:overlapFailures},null,2));
  if(overlapFailures.length)throw Error(`History overlap in ${overlapFailures.length} checks`);
  const times=[.45,1.0,1.75,2.45,3.1,3.9,4.95,5.9,7.2,8.3,9.7,11.5];
  const tiles=[];
  for(let i=0;i<times.length;i++){
   await page.evaluate(t=>window.setFrame(t),times[i]);
   const shot=await page.screenshot({type:'png'});
   await writeFile(path.join(root,'review',`frame-${times[i]}.png`),shot);
   tiles.push({input:await sharp(shot).resize(480,270).toBuffer(),left:(i%4)*480,top:Math.floor(i/4)*270});
  }
  await sharp({create:{width:1920,height:810,channels:3,background:'#000'}}).composite(tiles).png().toFile(path.join(root,'review','contact-sheet.png'));
  const sequence=[];
  for(let i=0;i<8;i++){
   const t=history.start+i*(history.duration-1/fps)/7;
   await page.evaluate(t=>window.setFrame(t),t);
   const shot=await page.screenshot({type:'png'});
   sequence.push({input:await sharp(shot).resize(480,270).toBuffer(),left:(i%4)*480,top:Math.floor(i/4)*270});
  }
  await sharp({create:{width:1920,height:540,channels:3,background:'#000'}}).composite(sequence).png().toFile(path.join(root,'review','history-fixed-sequence.png'));
  console.log(`Preview complete. History: ${history.frames} frames without card overlaps.`);
 }else{
  const encoder=spawn('/opt/homebrew/bin/ffmpeg',['-hide_banner','-loglevel','warning','-y','-f','image2pipe','-framerate',String(fps),'-vcodec','mjpeg','-i','pipe:0','-an','-c:v','libx264','-preset','medium','-crf','17','-pix_fmt','yuv420p','-movflags','+faststart',path.join(root,'silent-editorial.mp4')],{stdio:['pipe','inherit','inherit']});
  const finished=once(encoder,'close');
  for(let frame=0;frame<frames;frame++){
   await page.evaluate(t=>window.setFrame(t),frame/fps);
   const shot=await page.screenshot({type:'jpeg',quality:98});
   if(!encoder.stdin.write(shot))await once(encoder.stdin,'drain');
   if(frame%96===0)console.log(`Rendered ${frame}/${frames}`);
  }
  encoder.stdin.end();
  const [code]=await finished;
  if(code!==0)throw Error(`ffmpeg exited ${code}`);
  console.log(`Complete: ${duration}s, ${fps}fps, 1920x1080.`);
 }
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve))}
