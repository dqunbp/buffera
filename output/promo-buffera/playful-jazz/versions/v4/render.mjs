import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import path from 'node:path';
import {FPS,DURATION} from './timeline.mjs';
const require=createRequire('/Users/dqunbp/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/package.json');
const {chromium}=require('playwright'),sharp=require('sharp');
const root=path.dirname(fileURLToPath(import.meta.url)),serveRoot=path.dirname(root);
const preview=process.argv.includes('--preview'),frames=Math.round(FPS*DURATION);
const server=createServer(async(req,res)=>{
 try{
  const target=path.resolve(serveRoot,'.'+new URL(req.url,'http://localhost').pathname);
  if(!target.startsWith(serveRoot+path.sep)){res.writeHead(403).end();return}
  const body=await readFile(target),type=target.endsWith('.html')?'text/html':/\.m?js$/.test(target)?'text/javascript':'application/octet-stream';
  res.writeHead(200,{'Content-Type':type}).end(body);
 }catch{res.writeHead(404).end()}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
await mkdir(path.join(root,'review'),{recursive:true});
let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--disable-background-timer-throttling','--disable-renderer-backgrounding']});
 const page=await browser.newPage({viewport:{width:1920,height:1080},deviceScaleFactor:1});
 page.on('pageerror',err=>console.error('PAGE ERROR:',err.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/playful-jazz/film.html`);
 await page.evaluate(()=>window.__ready);await page.evaluate(()=>document.fonts.ready);
 if(preview){
  async function contact(times,name,columns){
   const tiles=[];
   for(let i=0;i<times.length;i++){
    await page.evaluate(t=>window.setFrame(t),times[i]);
    const shot=await page.screenshot({type:'png'});
    await writeFile(path.join(root,'review',`${name}-${times[i].toFixed(2)}.png`),shot);
    tiles.push({input:await sharp(shot).resize(480,270).toBuffer(),left:i%columns*480,top:Math.floor(i/columns)*270});
   }
   await sharp({create:{width:columns*480,height:Math.ceil(times.length/columns)*270,channels:3,background:'#000'}}).composite(tiles).png().toFile(path.join(root,'review',`${name}.png`));
  }
  await contact([.5,1.6,3.4,4.6,6.2,7.4,8.3,9.0,9.8,11.5,13.5,15.1],'contact-sheet',4);
  await contact([5.9,6.5,6.85,7.2,7.6,7.9,8.2,8.65,9.05,10.3],'insertion',5);
  await contact([.78,.96,1.14,1.32,4.13,4.31,4.49,4.67,11.28,11.46,11.64,11.82,13.23,13.41,13.59,13.77],'spring-reactions',4);
  const inspect=[];for(let frame=Math.round(5.6*FPS);frame<Math.round(10.8*FPS);frame++)inspect.push(await page.evaluate(t=>window.inspectFrame(t),frame/FPS));
  await writeFile(path.join(root,'review','insertion-diagnostics.json'),JSON.stringify(inspect,null,2));
  console.log('Preview and dense insertion sequence complete.');
 }else{
  const encoder=spawn('/opt/homebrew/bin/ffmpeg',['-hide_banner','-loglevel','warning','-y','-f','image2pipe','-framerate',String(FPS),'-vcodec','mjpeg','-i','pipe:0','-an','-c:v','libx264','-preset','medium','-crf','17','-pix_fmt','yuv420p','-movflags','+faststart',path.join(root,'silent-buffera-v4.mp4')],{stdio:['pipe','inherit','inherit']});
  const finished=once(encoder,'close');
  for(let frame=0;frame<frames;frame++){
   await page.evaluate(t=>window.setFrame(t),frame/FPS);
   const shot=await page.screenshot({type:'jpeg',quality:98});
   if(!encoder.stdin.write(shot))await once(encoder.stdin,'drain');
   if(frame%120===0)console.log(`Rendered ${frame}/${frames}`);
  }
  encoder.stdin.end();const[code]=await finished;if(code!==0)throw Error(`ffmpeg exited ${code}`);
  console.log(`Complete: ${DURATION}s, ${FPS}fps, 1920x1080.`);
 }
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve))}
