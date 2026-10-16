// anti-clickjacking (a meta CSP cannot set frame-ancestors): never run inside someone else's frame
if (window.top !== window.self) { try { window.top.location = window.self.location; } catch (e) { document.documentElement.style.display = 'none'; } }
const T={
ru:{nav_how:"Как работает",nav_dl:"Скачать",eyebrow:"программы · видео · студия",h1a:"Mochi Labs",h1b:"Studios",lead:"Программы, видео и всё, что мы придумываем. Три части одной студии — и все связаны между собой.",cta1:"Программы",cta2:"Видео",demo_a:"Двигай мышью.",demo_b:"Смотри, как это будет в видео.",lg1:"как двигалась рука",lg2:"как будет в видео",hint:"кликни — авто-зум",how_h:"Как это работает",c1h:"Курсор отдельно",c1p:"Курсор записывается отдельно от картинки. Его можно сгладить, увеличить или заменить уже после записи.",c2h:"Клики решают, куда смотреть",c2p:"Камера сама приближается к месту клика и плавно возвращается назад.",c3h:"Монтаж без лишнего",c3p:"Разрез, удаление, скорость, ручной зум, текст. Всё на одном таймлайне.",dl_h:"Скачать",dl_s:"Две версии: macOS — полная, Windows — первая рабочая сборка.",win_p:"Распакуйте архив и запустите MotionRecord.exe. ffmpeg внутри.",win_btn:"Скачать для Windows",mac_p:"Пока собирается из исходников. Готовый установщик — вместе с 2.0.",vid_b:"Как скачать и запустить за 47 секунд",vid_s:"Видео-инструкция на YouTube",tz_e:"тссс…",tz_soon:"скоро",tz_p:"Мы кое-что делаем. Подпишитесь на репозиторий, чтобы не пропустить выход.",b_hero:"Привет!",b_demo:"Поводи мышью!",b_how:"Всё просто!",b_dl:"Забирай!",era_t:"ЭРА II",era_s:"Mochi Labs Studios — вторая эра",b_tz:"Тссс…",pres:"представляет",nav_prog:"Программы",nav_vid:"Видео",nav_studio:"Студия",ch1:"Программы",ch2:"Видео",ch3:"Студия",p_name:"MotionRecord",p_sub:"Запись экрана, после которой видео уже готово. Плавный курсор, авто-зум по кликам, монтаж на таймлайне, экспорт в MP4.",v_h:"Наши ролики",v_s:"Видео-работы студии: туториалы и короткие ролики — чёрно-белые, без воды.",s_h:"Две студии. Одна команда.",s_s:"Mochilabstudios — главная студия. Motion делает программы, Clips — видео, а вместе они показывают, на что способны.",n1:"Программы",n1s:"представляет MotionRecord",n2s:"основная студия",n3:"Видео",n3s:"представляет ролики и тизеры",b_vid:"Смотри!",b_studio:"Это мы!"},
en:{nav_how:"How it works",nav_dl:"Download",eyebrow:"programs · videos · studio",h1a:"Mochi Labs",h1b:"Studios",lead:"Programs, videos and everything we dream up. Three parts of one studio — all connected.",cta1:"Programs",cta2:"Videos",demo_a:"Move your mouse.",demo_b:"See how it will look in the video.",lg1:"how your hand moved",lg2:"how it looks in the video",hint:"click — auto-zoom",how_h:"How it works",c1h:"Cursor on its own",c1p:"The cursor is recorded separately from the picture. Smooth it, enlarge it or replace it after recording.",c2h:"Clicks decide where to look",c2p:"The camera zooms toward each click and glides back on its own.",c3h:"Editing without the clutter",c3p:"Cut, delete, speed, manual zoom, text. All on one timeline.",dl_h:"Download",dl_s:"Two versions: macOS is the full one, Windows is the first working build.",win_p:"Unzip and run MotionRecord.exe. ffmpeg is included.",win_btn:"Download for Windows",mac_p:"Builds from source for now. A ready installer ships with 2.0.",vid_b:"How to download and run it in 47 seconds",vid_s:"Video guide on YouTube",tz_e:"shhh…",tz_soon:"soon",tz_p:"We're building something. Watch the repository so you don't miss the release.",b_hero:"Hi there!",b_demo:"Move the mouse!",b_how:"So simple!",b_dl:"Grab it!",era_t:"ERA II",era_s:"Mochi Labs Studios — the second era",b_tz:"Shhh…",pres:"presents",nav_prog:"Programs",nav_vid:"Videos",nav_studio:"Studio",ch1:"Programs",ch2:"Videos",ch3:"Studio",p_name:"MotionRecord",p_sub:"Screen recording that leaves the video already done. Smooth cursor, auto-zoom on clicks, timeline editing, export to MP4.",v_h:"Our videos",v_s:"The studio's video work: guides and short films — black and white, no fluff.",s_h:"Two studios. One team.",s_s:"Mochilabstudios is the main studio. Motion makes programs, Clips makes videos, and together they show what they can do.",n1:"Programs",n1s:"presents MotionRecord",n2s:"the main studio",n3:"Videos",n3s:"presents films and teasers",b_vid:"Watch!",b_studio:"That's us!"},
de:{nav_how:"So funktioniert's",nav_dl:"Download",eyebrow:"Programme · Videos · Studio",h1a:"Mochi Labs",h1b:"Studios",lead:"Programme, Videos und alles, was wir uns ausdenken. Drei Teile eines Studios — alle verbunden.",cta1:"Programme",cta2:"Videos",demo_a:"Beweg die Maus.",demo_b:"Sieh, wie es im Video aussieht.",lg1:"so bewegte sich die Hand",lg2:"so sieht es im Video aus",hint:"klicken — Auto-Zoom",how_h:"So funktioniert's",c1h:"Cursor separat",c1p:"Der Cursor wird getrennt vom Bild aufgenommen. Glätten, vergrößern oder austauschen — auch nach der Aufnahme.",c2h:"Klicks bestimmen den Blick",c2p:"Die Kamera zoomt von selbst zum Klick und gleitet danach zurück.",c3h:"Schnitt ohne Ballast",c3p:"Schneiden, löschen, Tempo, manueller Zoom, Text. Alles auf einer Timeline.",dl_h:"Herunterladen",dl_s:"Zwei Versionen: macOS ist die vollständige, Windows der erste lauffähige Build.",win_p:"Archiv entpacken und MotionRecord.exe starten. ffmpeg ist enthalten.",win_btn:"Für Windows herunterladen",mac_p:"Vorerst aus dem Quellcode bauen. Ein fertiger Installer kommt mit 2.0.",vid_b:"Download und Start in 47 Sekunden",vid_s:"Video-Anleitung auf YouTube",tz_e:"psst…",tz_soon:"bald",tz_p:"Wir bauen gerade etwas. Beobachte das Repository, um den Release nicht zu verpassen.",b_hero:"Hallo!",b_demo:"Beweg die Maus!",b_how:"So einfach!",b_dl:"Hol dir!",era_t:"ÄRA II",era_s:"Mochi Labs Studios — die zweite Ära",b_tz:"Psst…",pres:"präsentiert",nav_prog:"Programme",nav_vid:"Videos",nav_studio:"Studio",ch1:"Programme",ch2:"Videos",ch3:"Studio",p_name:"MotionRecord",p_sub:"Bildschirmaufnahme, nach der das Video schon fertig ist. Flüssiger Cursor, Auto-Zoom bei Klicks, Schnitt auf der Timeline, Export als MP4.",v_h:"Unsere Videos",v_s:"Die Videoarbeit des Studios: Anleitungen und Kurzfilme — schwarz-weiß, ohne Füllwörter.",s_h:"Zwei Studios. Ein Team.",s_s:"Mochilabstudios ist das Hauptstudio. Motion macht Programme, Clips Videos, und zusammen zeigen sie, was sie können.",n1:"Programme",n1s:"präsentiert MotionRecord",n2s:"das Hauptstudio",n3:"Videos",n3s:"präsentiert Filme und Teaser",b_vid:"Schau!",b_studio:"Das sind wir!"}
};
function setLang(l){
  document.documentElement.lang=l;
  document.querySelectorAll('[data-i]').forEach(e=>{const v=T[l][e.dataset.i];if(v!==undefined)e.textContent=v});
  document.querySelectorAll('.lang button').forEach(b=>b.classList.toggle('on',b.dataset.l===l));
  try{localStorage.setItem('mr-lang',l)}catch(e){}
  if(window.__after)window.__after();
}
document.querySelectorAll('.lang button').forEach(b=>b.onclick=()=>setLang(b.dataset.l));
(function(){let l='ru';try{l=localStorage.getItem('mr-lang')||''}catch(e){}
 if(!T[l]){const n=(navigator.language||'ru').slice(0,2);l=T[n]?n:'ru'} setLang(l)})();

// reveal on scroll
const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target)}}),{threshold:.12});
document.querySelectorAll('.rv').forEach(e=>io.observe(e));

// interactive cursor demo: raw jittery dots vs a smoothed line, click = auto-zoom
(function(){
  const cv=document.getElementById('cv'),c=cv.getContext('2d');let W,H,dpr;
  function size(){dpr=Math.min(2,devicePixelRatio||1);W=cv.clientWidth;H=cv.clientHeight;cv.width=W*dpr;cv.height=H*dpr;c.setTransform(dpr,0,0,dpr,0,0)}
  size();addEventListener('resize',size);
  let mx=W/2,my=H/2,sx=mx,sy=my,raw=[],trail=[],zoom=1,zt=1,zx=W/2,zy=H/2,ripple=null,auto=true,t0=performance.now();
  function pos(e){const r=cv.getBoundingClientRect();const p=e.touches?e.touches[0]:e;return[p.clientX-r.left,p.clientY-r.top]}
  cv.addEventListener('pointermove',e=>{auto=false;[mx,my]=pos(e)});
  cv.addEventListener('pointerleave',()=>{auto=true});
  cv.addEventListener('pointerdown',e=>{[mx,my]=pos(e);auto=false;click(mx,my)});
  function click(x,y){ripple={x,y,t:performance.now()};zt=2.1;zx=x;zy=y;setTimeout(()=>{zt=1},1400)}
  function frame(now){
    const t=(now-t0)/1000;
    if(auto){mx=W/2+Math.sin(t*.9)*W*.3;my=H/2+Math.sin(t*1.5+1)*H*.28;
      if(Math.floor(t/3.4)!==Math.floor((t-.017)/3.4)&&t>1)click(mx,my)}
    // raw (jittery) sample + smoothed position
    const jx=mx+(Math.random()-.5)*34,jy=my+(Math.random()-.5)*34;
    raw.push([jx,jy,now]);if(raw.length>46)raw.shift();
    sx+=(mx-sx)*.11;sy+=(my-sy)*.11;trail.push([sx,sy]);if(trail.length>90)trail.shift();
    zoom+=(zt-zoom)*.07;
    c.clearRect(0,0,W,H);c.save();
    c.translate(W/2,H/2);c.scale(zoom,zoom);const k=(zoom-1)/1.1;c.translate(-(W/2+(zx-W/2)*k),-(H/2+(zy-H/2)*k));
    // page skeleton
    c.fillStyle='rgba(255,255,255,.07)';for(let i=0;i<6;i++){const y=60+i*58;rr(40,y,W*(.5-((i*37)%90)/400),16,8);rr(40,y+26,W*(.32-((i*29)%70)/400),11,6)}
    c.fillStyle='#fff';rr(W-210,H-120,150,48,24);c.fillStyle='#000';c.font='700 15px -apple-system,Segoe UI,sans-serif';c.textAlign='center';c.fillText('Export',W-135,H-90);c.textAlign='left';
    // raw dots
    raw.forEach(([x,y],i)=>{c.fillStyle='rgba(255,255,255,'+(.08+.4*i/raw.length)+')';c.beginPath();c.arc(x,y,3.2/Math.sqrt(zoom),0,7);c.fill()});
    // smooth line
    c.strokeStyle='#fff';c.lineWidth=5/Math.sqrt(zoom);c.lineCap=c.lineJoin='round';c.beginPath();trail.forEach(([x,y],i)=>i?c.lineTo(x,y):c.moveTo(x,y));c.stroke();
    // ripple
    if(ripple){const u=(now-ripple.t)/650;if(u<1){c.strokeStyle='rgba(255,255,255,'+(.7*(1-u))+')';c.lineWidth=3;c.beginPath();c.arc(ripple.x,ripple.y,10+80*u,0,7);c.stroke()}else ripple=null}
    // cursor
    c.save();c.translate(sx,sy);c.scale(1.5/Math.sqrt(zoom),1.5/Math.sqrt(zoom));c.fillStyle='#000';c.strokeStyle='#fff';c.lineWidth=2;c.beginPath();c.moveTo(0,0);c.lineTo(0,17);c.lineTo(4.2,13.2);c.lineTo(7,19.6);c.lineTo(9.6,18.5);c.lineTo(6.9,12.2);c.lineTo(12.4,12.2);c.closePath();c.fill();c.stroke();c.restore();
    c.restore();
    if(zoom>1.08){c.fillStyle='#fff';rr(W-110,16,84,34,17);c.fillStyle='#000';c.font='700 14px -apple-system,Segoe UI,sans-serif';c.textAlign='center';c.fillText(zoom.toFixed(1)+'×',W-68,38);c.textAlign='left'}
    requestAnimationFrame(frame)
  }
  function rr(x,y,w,h,r){c.beginPath();c.roundRect?c.roundRect(x,y,w,h,r):c.rect(x,y,w,h);c.fill()}
  if(matchMedia('(prefers-reduced-motion: reduce)').matches){frame(performance.now());} else requestAnimationFrame(frame);
})();


// ===================== scroll choreography =====================
(function(){
  const RM=matchMedia('(prefers-reduced-motion: reduce)').matches;
  const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),lerp=(a,b,t)=>a+(b-a)*t,ease=t=>t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;
  // --- word split + scroll-lit text ---
  function splitWords(el){
    const txt=el.textContent.replace(/\s+/g,' ').trim();el.textContent='';
    txt.split(' ').forEach((w,k)=>{const o=document.createElement('span');o.className='wd';const i=document.createElement('i');i.style.setProperty('--k',k);i.textContent=w;o.appendChild(i);el.appendChild(o);el.appendChild(document.createTextNode(' '))});
  }
  let sweeps=[];
  function prep(){
    document.querySelectorAll('h1 [data-i],h2 [data-i],h2[data-i]').forEach(splitWords);
    sweeps=[...document.querySelectorAll('.sub,.tz p')].map(el=>{
      const txt=el.textContent.replace(/\s+/g,' ').trim();el.textContent='';el.classList.add('sweep');
      return{el,words:txt.split(' ').map(w=>{const s=document.createElement('span');s.textContent=w+' ';el.appendChild(s);return s})}});
    requestAnimationFrame(()=>requestAnimationFrame(()=>document.querySelector('h1').classList.add('go')));
  }
  window.__after=prep;prep();
  // stagger siblings
  document.querySelectorAll('.grid .card,.dl .os').forEach((e,i)=>e.style.transitionDelay=(i%3)*110+'ms');

  // --- Mochi companion ---
  const M=document.getElementById('mochi'),slot=document.getElementById('mslot'),bub=document.getElementById('bub'),eyes=M.querySelector('.eyes'),svg=M.querySelector('svg');
  let vel=0,lastY=scrollY,tilt=0,curMood='',bubT;
  function say(key){const l=document.documentElement.lang||'ru';bub.textContent=(T[l]&&T[l][key])||'';bub.classList.add('on');clearTimeout(bubT);bubT=setTimeout(()=>bub.classList.remove('on'),2600)}
  function jump(){M.classList.remove('jump');void M.offsetWidth;M.classList.add('jump');setTimeout(()=>M.classList.remove('jump'),750)}
  function mood(m,key){if(m===curMood)return;curMood=m;M.dataset.mood=m;jump();if(key)say(key)}
  const secs=[['#top','idle','b_hero'],['#programs','idle','b_demo'],['#how','happy','b_how'],['#download','wink','b_dl'],['.tz','shh','b_tz'],['#videos','happy','b_vid'],['#studio','happy','b_studio']].map(([q,m,k])=>({el:document.querySelector(q),m,k}));
  let burst=false;
  function place(){
    const sy=scrollY,W=innerWidth,H=innerHeight,mob=W<820;
    const r=slot.getBoundingClientRect();const slotSize=r.width;
    const ds=mob?.42:.55;
    const hero=document.getElementById('top').offsetHeight;
    const p=ease(clamp(sy/(hero*.55)));
    const sX=r.left+r.width/2-100*(slotSize/200),sS=slotSize/200;
    // slot rect already moves with the page; use it directly until docked
    const sYy=r.top+r.height/2-100*sS;
    const dock=200*ds,dX=W-dock-(mob?10:28),dY=H-dock-(mob?10:28);
    const x=lerp(sX,dX,p),y=lerp(sYy,dY,p),s=lerp(sS,ds,p);
    M.style.transform=`translate(${x}px,${y}px) scale(${s})`;M.style.opacity=1;
    // tilt from scroll velocity (happy wobble)
    vel=lerp(vel,(sy-lastY),.25);lastY=sy;tilt=lerp(tilt,clamp(vel*.35,-12,12),.2);svg.style.transform=`rotate(${tilt}deg)`;
    // mood by section
    let cur=secs[0];secs.forEach(o=>{if(o.el.getBoundingClientRect().top<H*.55)cur=o});mood(cur.m,cur.k);
    if(cur.m==='wink'&&!burst){burst=true;confetti(W-dock/2-(mob?10:28),dY)}
    // progress bar + parallax + demo scale + sweeps
    document.getElementById('prog').style.transform=`scaleX(${clamp(sy/(document.body.scrollHeight-H))})`;
    const g=document.getElementById('glow');if(g)g.style.transform=`translateY(${sy*.28}px)`;
    const d=document.querySelector('.demo');if(d){const q=d.getBoundingClientRect();const k=clamp((H-q.top)/(H*.7));d.style.setProperty('--ds',(.92+.08*ease(k)).toFixed(3))}
    sweeps.forEach(o=>{const q=o.el.getBoundingClientRect();const k=clamp((H*.9-q.top)/(H*.45));const n=Math.round(k*o.words.length);o.words.forEach((w,i)=>w.classList.toggle('lit',i<n))});
    // scroll-linked scramble for the 2.0 title
    const sc=document.getElementById('scr');if(sc){const q=sc.getBoundingClientRect();const k=clamp((H-q.top)/(H*.3));const tg='MotionRecord 2.0',gl='#%&@$*+?=/<>';
      sc.textContent=[...tg].map((ch,i)=>(ch===' '||i<k*tg.length)?ch:gl[(Math.floor(performance.now()/55)+i*7)%gl.length]).join('')}
  }
  // eyes follow the pointer
  addEventListener('pointermove',e=>{const r=M.getBoundingClientRect();const cx=r.left+r.width/2,cy=r.top+r.height*.62;
    const dx=clamp((e.clientX-cx)/Math.max(r.width,1)*14,-7,7),dy=clamp((e.clientY-cy)/Math.max(r.height,1)*9,-4.5,4.5);
    eyes.style.transform=`translate(${dx}px,${dy}px)`});
  addEventListener('pointerdown',e=>{const r=M.getBoundingClientRect();if(e.clientX>r.left&&e.clientX<r.right&&e.clientY>r.top&&e.clientY<r.bottom){jump();say('b_hero');confetti(r.left+r.width/2,r.top+r.height*.4)}});
  // --- tiny confetti ---
  const cvs=document.createElement('canvas');cvs.className='confetti';document.body.appendChild(cvs);const cx=cvs.getContext('2d');let parts=[],run=false;
  function fit(){cvs.width=innerWidth;cvs.height=innerHeight}fit();addEventListener('resize',fit);
  function confetti(x,y){if(RM)return;for(let i=0;i<46;i++){const a=-Math.PI/2+(Math.random()-.5)*2.2,v=4+Math.random()*7;parts.push({x,y,vx:Math.cos(a)*v,vy:Math.sin(a)*v,r:Math.random()*6,w:5+Math.random()*7,s:.4+Math.random()*.6,l:1})}if(!run){run=true;requestAnimationFrame(tick)}}
  function tick(){cx.clearRect(0,0,cvs.width,cvs.height);parts=parts.filter(p=>p.l>0);parts.forEach(p=>{p.vy+=.22;p.vx*=.992;p.x+=p.vx;p.y+=p.vy;p.r+=.2;p.l-=.011;cx.save();cx.globalAlpha=Math.max(0,p.l);cx.translate(p.x,p.y);cx.rotate(p.r);cx.fillStyle='rgba(255,255,255,'+p.s+')';cx.fillRect(-p.w/2,-p.w/4,p.w,p.w/2);cx.restore()});if(parts.length)requestAnimationFrame(tick);else run=false}
  // --- main loop ---
  let ticking=false;function onScroll(){if(!ticking){ticking=true;requestAnimationFrame(()=>{place();ticking=false})}}
  addEventListener('scroll',onScroll,{passive:true});addEventListener('resize',onScroll);
  (function loop(){place();requestAnimationFrame(loop)})();   // keeps velocity/tilt and scramble alive
  setTimeout(()=>say('b_hero'),900);
})();

// ===== ERA II: the flare star and the little ship, driven by scroll =====
(function(){
  const sec=document.getElementById('era'); if(!sec) return;
  const RM=matchMedia('(prefers-reduced-motion: reduce)').matches;
  const cv=document.createElement('canvas'); cv.id='eraCv'; sec.prepend(cv); const c=cv.getContext('2d');
  let W=0,H=0,dpr=1,visible=false,stars=[];
  function size(){dpr=Math.min(2,devicePixelRatio||1);W=sec.clientWidth;H=sec.clientHeight;cv.width=W*dpr;cv.height=H*dpr;c.setTransform(dpr,0,0,dpr,0,0);
    stars=[];for(let i=0;i<150;i++)stars.push({x:Math.random()*W,y:Math.random()*H,r:.5+Math.random()*1.6,l:Math.random(),t:Math.random()*6})}
  size();addEventListener('resize',size);
  new IntersectionObserver(es=>{visible=es[0].isIntersecting},{rootMargin:'100px'}).observe(sec);
  const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),ease=t=>1-Math.pow(1-clamp(t),3);
  function glow(x,y,r,a){const g=c.createRadialGradient(x,y,0,x,y,r);g.addColorStop(0,'rgba(255,255,255,'+a+')');g.addColorStop(1,'rgba(255,255,255,0)');c.fillStyle=g;c.beginPath();c.arc(x,y,r,0,7);c.fill()}
  function flare(x,y,u){
    if(u<.01)return;
    glow(x,y,Math.min(W,H)*.75*u,.42*u);glow(x,y,Math.min(W,H)*.2*u,.9*u);
    const w=W*1.1*u,h=3+3*u; let g=c.createLinearGradient(x-w/2,0,x+w/2,0);
    g.addColorStop(0,'rgba(255,255,255,0)');g.addColorStop(.5,'rgba(255,255,255,1)');g.addColorStop(1,'rgba(255,255,255,0)');c.fillStyle=g;c.fillRect(x-w/2,y-h/2,w,h);
    const v=Math.min(H*.5,360)*u; g=c.createLinearGradient(0,y-v,0,y+v);
    g.addColorStop(0,'rgba(255,255,255,0)');g.addColorStop(.5,'rgba(255,255,255,.95)');g.addColorStop(1,'rgba(255,255,255,0)');c.fillStyle=g;c.fillRect(x-1.6,y-v,3.2,2*v);
  }
  function ship(x,y,s,fl,t){
    c.save();c.translate(x,y);c.scale(s,s);
    // flame
    for(let k=0;k<4;k++){const w=(34-k*7)*fl,L=(190-k*38)*fl*(1+.14*Math.sin(t*38+k*7));c.fillStyle='rgba(255,255,255,'+(.12+.16*k)+')';
      c.beginPath();c.moveTo(-w,150);c.quadraticCurveTo(-w*.9,150+L*.55,0,150+L);c.quadraticCurveTo(w*.9,150+L*.55,w,150);c.fill()}
    // fins
    c.fillStyle='#dcdcdc';for(const sx of[-1,1]){c.beginPath();c.moveTo(sx*62,30);c.lineTo(sx*126,126);c.quadraticCurveTo(sx*92,118,sx*62,110);c.closePath();c.fill()}
    // body
    const g=c.createLinearGradient(-66,0,66,0);g.addColorStop(0,'#fff');g.addColorStop(1,'#9e9e9e');c.fillStyle=g;
    c.beginPath();c.moveTo(-66,122);c.lineTo(-66,-50);c.bezierCurveTo(-66,-140,-26,-200,0,-228);c.bezierCurveTo(26,-200,66,-140,66,-50);c.lineTo(66,122);c.quadraticCurveTo(0,140,-66,122);c.fill();
    c.fillStyle='#141414';c.fillRect(-66,52,132,12);c.fillRect(-66,76,132,4);
    // window with Mochi
    c.fillStyle='#0d0d0d';c.beginPath();c.arc(0,-74,40,0,7);c.fill();c.strokeStyle='#777';c.lineWidth=5;c.stroke();
    c.fillStyle='#fff';c.beginPath();c.roundRect?c.roundRect(-26,-80,52,40,16):c.rect(-26,-80,52,40);c.fill();
    c.strokeStyle='#000';c.lineWidth=4;c.lineCap='round';for(const sx of[-1,1]){c.beginPath();c.moveTo(sx*11-6,-58);c.quadraticCurveTo(sx*11,-67,sx*11+6,-58);c.stroke()}
    c.fillStyle='#fff';c.strokeStyle='#000';c.lineWidth=2.5;c.beginPath();c.moveTo(-18,-80);c.quadraticCurveTo(-4,-98,6,-114);c.quadraticCurveTo(10,-96,18,-80);c.closePath();c.fill();c.stroke();
    c.restore();
  }
  function frame(now){
    requestAnimationFrame(frame);
    if(!visible&&!RM)return;
    const t=now/1000,r=sec.getBoundingClientRect();
    const p=RM?1:clamp((innerHeight*.95-r.top)/(r.height*.62));
    c.clearRect(0,0,W,H);
    for(const s of stars){const tw=.55+.45*Math.sin(t*(.8+s.l*2)+s.t);const dy=(p*60*s.l);c.fillStyle='rgba(255,255,255,'+(.25+.7*s.l)*tw*clamp(p*2.5)+')';c.beginPath();c.arc(s.x,(s.y+dy)%H,s.r*(.6+s.l),0,7);c.fill()}
    const sx=W/2,sy=H*.3;
    // the ship climbs towards the star while you scroll and dissolves into its light
    const climb=ease(p*1.15),shipA=clamp(1-(p-.72)/.22);
    if(shipA>0.01){c.save();c.globalAlpha=shipA*clamp(p*4);ship(sx,H*.86-(H*.86-sy-60)*climb,.55-.3*climb,.9,t);c.restore()}
    flare(sx,sy,ease((p-.55)/.4));
  }
  requestAnimationFrame(frame);
})();
