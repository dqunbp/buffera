import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import path from 'node:path';

const require = createRequire('/Users/dqunbp/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/package.json');
const { chromium } = require('playwright');
const sharp = require('sharp');
const root = path.dirname(fileURLToPath(import.meta.url));
const preview = process.argv.includes('--preview');
await mkdir(path.join(root,'review'),{recursive:true});
const browser = await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--disable-background-timer-throttling','--disable-renderer-backgrounding']});
try {
  const page = await browser.newPage({viewport:{width:1920,height:1080},deviceScaleFactor:1});
  await page.goto(new URL('./film.html',import.meta.url).href);
  await page.evaluate(()=>document.fonts.ready);
  if(preview){
    const times=[1.9,3.9,4.55,7.9,10.9,12,14,17.2,21.7];
    const tiles=[];
    for(let i=0;i<times.length;i++){
      await page.evaluate(t=>window.setFrame(t),times[i]);
      const shot=await page.screenshot({type:'png'});
      await writeFile(path.join(root,'review',`frame-${times[i]}.png`),shot);
      tiles.push({input:await sharp(shot).resize(640,360).toBuffer(),left:(i%3)*640,top:Math.floor(i/3)*360});
    }
    await sharp({create:{width:1920,height:1080,channels:3,background:'#fff'}}).composite(tiles).png().toFile(path.join(root,'review','contact-sheet.png'));
    console.log('Review frames and contact sheet saved.');
  }else{
    const encoder=spawn('/opt/homebrew/bin/ffmpeg',['-hide_banner','-loglevel','warning','-y','-f','image2pipe','-framerate','30','-vcodec','mjpeg','-i','pipe:0','-an','-c:v','libx264','-preset','medium','-crf','17','-pix_fmt','yuv420p','-movflags','+faststart','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709',path.join(root,'silent.mp4')],{stdio:['pipe','inherit','inherit']});
    const finished=once(encoder,'close');
    for(let frame=0;frame<720;frame++){
      await page.evaluate(t=>window.setFrame(t),frame/30);
      const shot=await page.screenshot({type:'jpeg',quality:97});
      if(!encoder.stdin.write(shot)) await once(encoder.stdin,'drain');
      if(frame%90===0) console.log(`Rendered ${frame}/720 frames`);
    }
    encoder.stdin.end();
    const [code]=await finished;
    if(code!==0)throw new Error(`ffmpeg exited ${code}`);
    console.log('Rendered silent.mp4: 1920×1080, 30 fps, 24 seconds.');
  }
} finally {await browser.close()}
