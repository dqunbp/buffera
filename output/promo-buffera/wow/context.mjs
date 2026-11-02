// A deterministic source → clipboard → destination layer for the two use cases.
const clamp = x => Math.max(0, Math.min(1, x));
const ease = x => 1 - (1 - clamp(x)) ** 3;
const mix = (a, b, p) => a + (b - a) * p;
const fade = (s, start, end) => ease((s - start) / (end - start));

const map = (className = '') => `<svg class="${className}" viewBox="0 0 500 240" aria-hidden="true"><rect width="500" height="240" fill="#dfd2ec"/><g fill="#c4afd9"><rect x="24" y="22" width="110" height="60" rx="12"/><rect x="345" y="120" width="130" height="89" rx="16"/><rect x="155" y="150" width="95" height="66" rx="10"/></g><g stroke="#fbf9fd" stroke-width="23" fill="none"><path d="M-30 110L535 72M-20 222L525 180M95-30L220 280M330-25L420 270"/></g><path d="M284 85c-19 0-27 21-15 35l15 18 15-18c12-14 4-35-15-35" fill="#8a4ac2"/><circle cx="284" cy="105" r="6" fill="#fff"/></svg>`;

export function createContext(root) {
  const style = document.createElement('style');
  style.textContent = `
    #film > canvas{z-index:0}#film > .shot{z-index:2}
    #film-context{position:absolute;inset:0;z-index:1;pointer-events:none;color:#2a2034;font-family:inherit}
    #film-context *{box-sizing:border-box}
    .cx-scene{position:absolute;inset:0;visibility:hidden}
    .cx-window{position:absolute;left:80px;top:330px;width:600px;height:455px;background:#fcfaff;border:1px solid #ded5e8;border-radius:24px;overflow:hidden;box-shadow:0 35px 70px -30px #0005;transform-origin:70% 50%}
    .cx-bar{height:65px;display:flex;align-items:center;padding:20px 22px;gap:25px;border-bottom:1px solid #eae3f0;background:#f4f0f8}
    .cx-dots{display:flex;gap:8px}.cx-dots i{display:block;width:12px;height:12px;border-radius:50%;background:#ff655d}.cx-dots i:nth-child(2){background:#ffbf35}.cx-dots i:nth-child(3){background:#31c94d}
    .cx-app{font-size:25px;letter-spacing:-.5px;color:#8e8099}
    .cx-content{padding:35px 30px}.cx-content h2{font-size:37px;font-weight:620;letter-spacing:-1.3px;margin:0 0 26px}
    .cx-selection{position:relative;display:inline-block;padding:12px 13px;border-radius:8px;background:#eee6f8;font-size:30px;font-weight:500;letter-spacing:-.7px;color:#613c86;white-space:nowrap;box-shadow:inset 0 0 0 1px #dcc8ee}
    .cx-lines{margin-top:33px;display:grid;gap:13px}.cx-lines i{display:block;background:#e4dce9;height:10px;border-radius:5px}.cx-lines i:nth-child(2){width:87%}.cx-lines i:nth-child(3){width:62%}
    .cx-caption{font-size:25px;color:#8a7a96;margin-top:28px;letter-spacing:-.5px}
    #cx-notes{left:115px;top:370px;width:565px;height:415px;box-shadow:0 30px 70px -15px #39254945}
    #cx-notes .cx-content{padding:30px}#cx-notes h2{font-size:34px;margin-bottom:21px}
    #cx-notes .cx-selection{font-size:28px;line-height:1.45;white-space:normal;width:490px}
    .cx-status{position:absolute;left:105px;top:865px;font-size:30px;line-height:1.25;letter-spacing:-.6px;color:#c3a7df;display:flex;align-items:center;gap:13px}
    .cx-status b{font-size:23px;font-weight:500;background:#ffffff16;color:inherit;border-radius:50%;width:34px;height:34px;display:inline-flex;align-items:center;justify-content:center}
    .cx-status small{display:block;font-size:24px;color:#8e7c9e;margin-top:6px}
    #cx-copy[data-mode="copy2"] .cx-status{color:#765199}#cx-copy[data-mode="copy2"] .cx-status b{background:#e8dcef}
    .cx-path{position:absolute;inset:0;overflow:visible;fill:none;stroke:#c096e7;stroke-width:2.5;opacity:.4}
    #cx-chip{position:absolute;left:0;top:0;padding:14px 22px;border:1px solid #d3b5f2;border-radius:13px;background:#fbf7ff;color:#714797;font-size:27px;font-weight:550;letter-spacing:-.7px;box-shadow:0 10px 35px #21102c30;white-space:nowrap;transform-origin:center}
    #cx-history .cx-status{top:900px;left:100px}.cx-earlier{position:absolute;left:120px;top:247px;font-size:28px;color:#9f8ead;letter-spacing:-.6px}
    #cx-history-check{position:absolute;left:1548px;top:303px;width:48px;height:48px;border-radius:50%;font-size:29px;line-height:48px;text-align:center;background:#ddc7f3;color:#77439e;box-shadow:0 8px 24px #0002}
    #paste-link .browser{left:520px;width:1260px}#paste-link .address{flex:1;width:auto}#paste-link .page-name{font-size:51px}
    #cx-return-card{position:absolute;left:110px;top:420px;width:330px;height:250px;border-radius:21px;border:1px solid #d9c8e8;background:#fffaff;padding:29px;box-shadow:0 15px 45px #40264b1d;transform:rotate(-7deg)}
    .cx-return-label{font-size:26px;color:#9b7cae;margin-bottom:27px}.cx-return-title{font-size:32px;font-weight:620;line-height:1.1;letter-spacing:-1px}.cx-return-url{font-size:21px;color:#966eb5;margin-top:22px;white-space:nowrap}
    #cx-return-status{left:110px;top:735px;color:#765199;font-size:28px;line-height:1.3}
    #cx-paste-trace{position:absolute;left:393px;top:540px;width:100px;height:1px;background:#be9dd6}
    #cx-chat .cx-window{top:310px;height:505px}.cx-chat-body{padding:25px 28px}.cx-bubble{display:inline-block;background:#eee5f8;padding:15px 22px;border-radius:19px 19px 19px 4px;font-size:29px;letter-spacing:-.7px;margin-bottom:18px}
    .cx-shared{border-radius:16px;overflow:hidden;background:#faf6ff;border:1px solid #d6c5e6}.cx-shared-text{font-size:28px;font-weight:550;letter-spacing:-.8px;padding:16px 18px;color:#5d397b}.cx-shared svg{display:block;width:100%;height:183px;object-fit:cover}
    #cx-chat .cx-status{top:864px}.cx-context-menu{position:absolute;left:84px;top:785px;width:370px;padding:9px;border-radius:17px;border:1px solid #d7c4e5;background:#faf6ffe8;backdrop-filter:blur(15px);box-shadow:0 20px 35px #3d1e5b2e;font-size:28px;letter-spacing:-.7px}
    .cx-context-menu div{padding:13px 15px;border-radius:9px;color:#85738e}.cx-context-menu .cx-selected{color:white;background:#9869bf}
    #extract-action{display:none}#cx-extract .cx-status{left:1210px;top:812px;color:#7e4ba1}
    #paste-address .route{left:140px;width:900px;padding:42px 40px}#paste-address .route-field{font-size:43px;letter-spacing:-1.4px;padding:25px;gap:25px}#paste-address .route-name{font-size:28px}
    #cx-map{position:absolute;left:1120px;top:330px;width:650px;height:520px;border:1px solid #d7c9e2;border-radius:27px;overflow:hidden;background:#e2d9eb;box-shadow:0 35px 65px -38px #47265f44;transform-origin:30% 50%}
    #cx-map svg{display:block;width:650px;height:520px}.cx-map-tag{position:absolute;top:23px;left:23px;z-index:1;padding:10px 17px;background:#fffafbea;border-radius:12px;font-size:28px;letter-spacing:-.5px;color:#725382;box-shadow:0 4px 14px #46275912}
    #cx-route-line{stroke-dasharray:700;stroke-dashoffset:700}.cx-map-destination{transform-origin:505px 155px}
    #cx-cursor{position:absolute;left:0;top:0;width:42px;height:54px;z-index:4;pointer-events:none;filter:drop-shadow(0 4px 5px #0005);opacity:0}
    #cx-cursor path{fill:white;stroke:#382c45;stroke-width:2.5;stroke-linejoin:round}
    #cx-click{position:absolute;left:0;top:0;width:58px;height:58px;border:2px solid #b581df;border-radius:50%;z-index:3;pointer-events:none;opacity:0}
  `;
  root.append(style);
  const layer = document.createElement('div');
  layer.id = 'film-context';
  layer.innerHTML = `
    <section id="cx-copy" class="cx-scene">
      <div id="cx-browser" class="cx-window"><div class="cx-bar"><span class="cx-dots"><i></i><i></i><i></i></span><span class="cx-app">Браузер</span></div><div class="cx-content"><h2>Гайд по интерфейсам</h2><div id="cx-link-selection" class="cx-selection">design.example/guide</div><div class="cx-lines"><i></i><i></i><i></i></div><div class="cx-caption">Та самая полезная ссылка.</div></div></div>
      <div id="cx-notes" class="cx-window"><div class="cx-bar"><span class="cx-dots"><i></i><i></i><i></i></span><span class="cx-app">Заметки</span></div><div class="cx-content"><h2>Идея для проекта</h2><div id="cx-text-selection" class="cx-selection">Меньше вкладок.<br>Больше хороших идей.</div><div class="cx-lines"><i></i><i></i></div></div></div>
      <div class="cx-status"><b>✓</b><div>Сохранено в истории<small id="cx-count">1 запись</small></div></div>
    </section>
    <section id="cx-history" class="cx-scene"><div class="cx-earlier">Ранее</div><div id="cx-history-check">✓</div><div class="cx-status"><b>✓</b><div>Ссылка найдена</div></div></section>
    <section id="cx-return" class="cx-scene"><div id="cx-return-card"><div class="cx-return-label">Из истории</div><div class="cx-return-title">Та самая<br>ссылка</div><div class="cx-return-url">design.example/guide</div></div><div id="cx-return-status" class="cx-status">Из истории<br>прямо в браузер</div></section>
    <section id="cx-chat" class="cx-scene"><div class="cx-window"><div class="cx-bar"><span class="cx-dots"><i></i><i></i><i></i></span><span class="cx-app">Сообщения</span></div><div class="cx-chat-body"><div class="cx-bubble">Встречаемся здесь</div><div class="cx-shared"><div class="cx-shared-text">Улица Примеров, 12</div>${map()}</div></div></div><div class="cx-status"><b>✓</b><div>Скриншот в истории</div></div></section>
    <section id="cx-extract" class="cx-scene"><div class="cx-context-menu"><div>Копировать</div><div class="cx-selected">Текст с картинки</div></div><div class="cx-status"><b>✓</b><div>Текст скопирован</div></div></section>
    <section id="cx-route" class="cx-scene"><div id="cx-map"><div class="cx-map-tag">Маршрут</div><svg viewBox="0 0 650 520" aria-hidden="true"><rect width="650" height="520" fill="#e4dcec"/><g fill="#cdbbdf"><rect x="25" y="32" width="145" height="100" rx="17"/><rect x="405" y="22" width="210" height="75" rx="15"/><rect x="365" y="305" width="240" height="145" rx="17"/><rect x="45" y="340" width="125" height="126" rx="17"/></g><g fill="none" stroke="#fffaff" stroke-width="38"><path d="M-40 195L700 140M-25 332L695 282M-20 485L695 436M195-30L265 560M350-20L390 570M540-20L595 550"/></g><path d="M-40 195L700 140M-25 332L695 282M-20 485L695 436M195-30L265 560M350-20L390 570M540-20L595 550" stroke="#d7cce1" stroke-width="2" fill="none"/><path id="cx-route-line" d="M120 443L249 453L229 315L370 305L360 166L505 155" stroke="#9761c5" stroke-width="12" stroke-linecap="round" stroke-linejoin="round" fill="none"/><circle cx="120" cy="443" r="12" fill="#fff" stroke="#9c6ac8" stroke-width="6"/><g id="cx-map-pin" class="cx-map-destination"><path d="M505 111c-22 0-33 25-18 43l18 22 18-22c15-18 4-43-18-43" fill="#8750b5"/><circle cx="505" cy="135" r="8" fill="#fff"/></g></svg></div></section>
    <svg id="cx-flow" class="cx-path" viewBox="0 0 1920 1080"><path id="cx-flow-path" d=""/></svg>
    <div id="cx-chip"></div>
  `;
  root.append(layer);
  const cursor = document.createElement('div');
  cursor.id = 'cx-cursor';
  cursor.innerHTML = '<svg viewBox="0 0 45 58"><path d="M7 3L38 33L23 35L17 50Z"/></svg>';
  const click = document.createElement('div');click.id = 'cx-click';
  root.append(cursor, click);
  const get = id => layer.querySelector(`#${id}`);
  const scenes = [...layer.querySelectorAll('.cx-scene')];
  const set = (id, opacity, transform = '') => {const el = get(id);el.style.opacity = clamp(opacity);el.style.transform = transform;};
  const cursorAt = (x, y, opacity = 1, scale = 1) => {cursor.style.opacity = clamp(opacity);cursor.style.transform = `translate(${x}px,${y}px) scale(${scale})`;};
  const clickAt = (x, y, s, when) => {
    const p = clamp((s - when) / .26);
    click.style.opacity = s >= when && p < 1 ? (1-p)*.8 : 0;
    click.style.transform = `translate(${x-21}px,${y-21}px) scale(${.2+p*1.4})`;
  };
  function fly(s, start, duration, from, to, text) {
    const p = clamp((s - start) / duration),e = ease(p);
    get('cx-chip').textContent = text;
    const visible = s >= start && p < 1;
    const x = mix(from[0],to[0],e),y = mix(from[1],to[1],e)-Math.sin(Math.PI*p)*75;
    set('cx-chip',visible?1:0,`translate(${x}px,${y}px) scale(${mix(.82,.50,e)}) rotate(${mix(-4,4,e)}deg)`);
    get('cx-flow-path').setAttribute('d',`M${from[0]+60} ${from[1]+30} Q${(from[0]+to[0])/2} ${Math.min(from[1],to[1])-70} ${to[0]+60} ${to[1]+30}`);
    get('cx-flow').style.opacity = visible ? .28*Math.sin(Math.PI*p) : 0;
  }
  function render(shot) {
    const {id,local:s}=shot;
    for(const el of scenes)el.style.visibility='hidden';
    cursor.style.opacity=0;click.style.opacity=0;set('cx-chip',0);get('cx-flow').style.opacity=0;
    if(id==='copy1'||id==='copy2'){
      get('cx-copy').style.visibility='visible';get('cx-copy').dataset.mode=id;
      const second=id==='copy2';
      set('cx-browser',second?.35:1,`perspective(1200px) rotateY(${second?7:5}deg) rotateZ(${second?-2:-1}deg)`);
      set('cx-notes',second?1:0,`translateY(${mix(90,0,ease(s/.24))}px) rotate(-2deg)`);
      const selected=get(second?'cx-text-selection':'cx-link-selection');
      selected.style.background=s>.14?'#dcc4f2':'#eee6f8';
      get('cx-count').textContent=second?'2 записи':'1 запись';
      const status=get('cx-copy').querySelector('.cx-status');status.style.opacity=fade(s,second?.5:.7,second?.66:.9);
      const p=ease(s/.20),point=second?[460,572]:[433,532];
      cursorAt(mix(594,point[0],p),mix(775,point[1],p),1-fade(s,.38,.55),s>.18&&s<.27?.87:1);
      clickAt(point[0],point[1],s,.18);
      fly(s,second?.21:.26,second?.32:.48,[420,second?570:520],[1095,530],second?'Меньше вкладок.':'design.example/guide');
    }else if(id==='history'){
      get('cx-history').style.visibility='visible';
      const p=ease((s-.4)/.48);cursorAt(mix(547,1220,p),mix(780,535,p),fade(s,.28,.4)*(1-fade(s,1.45,1.65)));
      clickAt(1220,535,s,1.18);set('cx-history-check',fade(s,1.18,1.36),`scale(${mix(.6,1,ease((s-1.18)/.2))})`);
      get('cx-history').querySelector('.cx-status').style.opacity=fade(s,1.18,1.4);
    }else if(id==='paste-link'){
      get('cx-return').style.visibility='visible';
      set('cx-return-card',1,`rotate(-7deg) translateY(${mix(20,0,ease(s/.25))}px)`);
      get('cx-return-status').style.opacity=fade(s,.35,.55);
      fly(s,.05,.3,[240,500],[1050,405],'design.example/guide');
      cursorAt(mix(470,1220,ease(s/.18)),mix(600,430,ease(s/.18)),1-fade(s,.35,.5));clickAt(1220,430,s,.22);
    }else if(id==='screenshot'){
      get('cx-chat').style.visibility='visible';
      const win=get('cx-chat').querySelector('.cx-window');win.style.transform=`perspective(1200px) rotateY(5deg) translateY(${mix(35,0,ease(s/.25))}px)`;
      get('cx-chat').querySelector('.cx-shared').style.boxShadow=s>.2?'0 0 0 3px #b484d9':'none';
      get('cx-chat').querySelector('.cx-status').style.opacity=fade(s,.74,.95);
      cursorAt(mix(620,487,ease(s/.2)),mix(786,627,ease(s/.2)),1-fade(s,.45,.6));clickAt(487,627,s,.22);
      fly(s,.3,.45,[420,600],[1095,530],'Скриншот');
    }else if(id==='extract'){
      get('cx-extract').style.visibility='visible';
      const menu=get('cx-extract').querySelector('.cx-context-menu');menu.style.opacity=fade(s,0,.12)*(1-fade(s,.65,.84));menu.style.transform=`translateY(${mix(14,0,ease(s/.15))}px)`;
      cursorAt(mix(440,300,ease(s/.18)),mix(700,880,ease(s/.18)),1-fade(s,.48,.68),s>.15&&s<.25?.85:1);clickAt(300,880,s,.18);
      get('cx-extract').querySelector('.cx-status').style.opacity=fade(s,1.2,1.43);
    }else if(id==='paste-address'){
      get('cx-route').style.visibility='visible';
      set('cx-map',1,`perspective(1300px) rotateY(${mix(-10,-2,ease(s/.4))}deg) translateX(${mix(80,0,ease(s/.4))}px)`);
      const p=ease((s-.22)/.85);get('cx-route-line').style.strokeDashoffset=String(700*(1-p));
      get('cx-map-pin').style.opacity=fade(s,.76,1.02);get('cx-map-pin').style.transform=`scale(${mix(.4,1,ease((s-.76)/.3))})`;
      cursorAt(mix(780,720,ease(s/.2)),mix(720,550,ease(s/.2)),1-fade(s,.4,.6));clickAt(720,550,s,.22);
    }
  }
  return {render};
}
