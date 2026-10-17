'use strict';
const T={
ru:{yt_btn:'Смотреть премьеру',yt_load:'Открыть премьеру здесь',hint2:'Листайте дальше',hint:'Листайте, чтобы лететь внутрь',cd_in:'До старта',cd_live:'Прямо сейчас',cd_d:'дн',cd_h:'ч',cd_m:'мин',cd_s:'с',tag:'Nova is here',h_c:'Не просто запись. Целая вселенная.',s_c:'Каждая функция — звезда. Вместе они складываются в созвездие.',back:'← Студия',nav_f:'Функции',nav_t:'Трейлер',eyebrow:'Mochi Labs Studios представляет',lead:'Nova is here. Новая эра записи экрана на Mac: чёрно-белая, кинематографичная и совершенно бесплатная.',price:'БЕСПЛАТНО',dl:'Скачать',soon:'скоро',more:'Что нового',h_f:'Всё, что нужно для кадра',s_f:'Тринадцать возможностей в одном приложении.',
f1t:'Shorts в одно касание',f1d:'Формат 9:16, камера сама следует за курсором.',f2t:'Автозум по кликам',f2d:'Кадр плавно приближается туда, где вы нажимаете.',f3t:'Новый редактор',f3d:'Чёрно-белая тема и переработанный таймлайн.',f4t:'Mochi в кадре',f4d:'Маскот студии оживляет ваши записи.',f5t:'Блюр и скрытие',f5d:'Закройте пароли и личное: размытие или заливка частей кадра.',f6t:'Субтитры и текст',f6d:'Добавляйте подписи и титры прямо на таймлайне.',f7t:'Экспорт до 4K 60fps',f7d:'MP4 в максимальном качестве.',f8t:'RU / EN / DE',f8d:'Интерфейс на трёх языках.',f9t:'Начальная заставка',f9d:'Кинематографичное вступление для каждого проекта.',f10t:'Подсветка курсора',f10d:'Всё затемняется, кроме круга вокруг курсора: взгляд зрителя там, где нужно.',f11t:'След за курсором',f11d:'Мягкий затухающий шлейф: движение читается даже на быстром монтаже.',f12t:'Маркеры и горячие клавиши',f12d:'M ставит маркер, [ и ] прыгают между ними, ? показывает все клавиши.',f13t:'Титул и пресеты зума',f13d:'Титульная карта в один клик, зум Мягко / Обычно / Сильно.',
h_s:'Shorts: камера следует за вами',s_s:'Подвигайте курсором — вертикальный кадр 9:16 поедет за ним.',phone:'Результат: готовый вертикальный Short',h_t:'Трейлер',prem:'Премьера в понедельник',prem2:'19 октября, 18:00 по Берлину (19:00 МСК)',h_e:'Era II начинается'},
en:{yt_btn:'Watch the premiere',yt_load:'Open the premiere here',hint2:'Keep scrolling',hint:'Scroll to fly inside',cd_in:'Starts in',cd_live:'Live now',cd_d:'d',cd_h:'h',cd_m:'min',cd_s:'s',tag:'Nova is here',h_c:'Not just a recording. A whole universe.',s_c:'Every feature is a star. Together they form a constellation.',back:'← Studio',nav_f:'Features',nav_t:'Trailer',eyebrow:'Mochi Labs Studios presents',lead:'Nova is here. A new era of screen recording on Mac: black and white, cinematic and completely free.',price:'FREE',dl:'Download',soon:'soon',more:"What's new",h_f:'Everything for the perfect shot',s_f:'Thirteen capabilities in one app.',
f1t:'One-tap Shorts',f1d:'9:16 format, the camera follows your cursor.',f2t:'Auto-zoom on clicks',f2d:'The frame smoothly zooms to where you click.',f3t:'New editor',f3d:'Black-and-white theme and a redesigned timeline.',f4t:'Mochi on screen',f4d:'The studio mascot brings your recordings to life.',f5t:'Blur and hide',f5d:'Cover passwords and private info: blur or fill parts of the frame.',f6t:'Subtitles and text',f6d:'Add captions and titles right on the timeline.',f7t:'Export up to 4K 60fps',f7d:'MP4 in top quality.',f8t:'RU / EN / DE',f8d:'Interface in three languages.',f9t:'Intro splash',f9d:'A cinematic opening for every project.',f10t:'Cursor spotlight',f10d:'Everything dims except a circle around the cursor, so the eye goes where it should.',f11t:'Cursor trail',f11d:'A soft fading trail: motion stays readable even in a fast edit.',f12t:'Markers and shortcuts',f12d:'M drops a marker, [ and ] jump between them, ? shows every key.',f13t:'Title card and zoom presets',f13d:'A title card in one click, zoom Soft / Normal / Strong.',
h_s:'Shorts: the camera follows you',s_s:'Move your cursor — the vertical 9:16 frame will follow.',phone:'Result: a ready vertical Short',h_t:'Trailer',prem:'Premiere on Monday',prem2:'October 19, 6 PM Berlin time (7 PM Moscow)',h_e:'Era II begins'},
de:{yt_btn:'Premiere ansehen',yt_load:'Premiere hier öffnen',hint2:'Weiter scrollen',hint:'Scrollen, um ins Innere zu fliegen',cd_in:'Start in',cd_live:'Jetzt live',cd_d:'T',cd_h:'Std',cd_m:'Min',cd_s:'Sek',tag:'Nova is here',h_c:'Nicht nur eine Aufnahme. Ein ganzes Universum.',s_c:'Jede Funktion ist ein Stern. Zusammen bilden sie ein Sternbild.',back:'← Studio',nav_f:'Funktionen',nav_t:'Trailer',eyebrow:'Mochi Labs Studios präsentiert',lead:'Nova is here. Eine neue Ära der Bildschirmaufnahme auf dem Mac: schwarz-weiß, kinoreif und völlig kostenlos.',price:'KOSTENLOS',dl:'Herunterladen',soon:'bald',more:'Neuigkeiten',h_f:'Alles für den perfekten Take',s_f:'Dreizehn Funktionen in einer App.',
f1t:'Shorts mit einem Tipp',f1d:'9:16-Format, die Kamera folgt dem Cursor.',f2t:'Auto-Zoom bei Klicks',f2d:'Das Bild zoomt sanft dorthin, wo Sie klicken.',f3t:'Neuer Editor',f3d:'Schwarz-weißes Design und neue Timeline.',f4t:'Mochi im Bild',f4d:'Das Studio-Maskottchen erweckt Ihre Aufnahmen zum Leben.',f5t:'Unschärfe und Ausblenden',f5d:'Passwörter und Privates abdecken: Teile des Bildes verwischen oder füllen.',f6t:'Untertitel und Text',f6d:'Beschriftungen und Titel direkt in der Timeline.',f7t:'Export bis 4K 60fps',f7d:'MP4 in höchster Qualität.',f8t:'RU / EN / DE',f8d:'Oberfläche in drei Sprachen.',f9t:'Intro-Splash',f9d:'Ein filmischer Einstieg für jedes Projekt.',f10t:'Cursor-Hervorhebung',f10d:'Alles wird abgedunkelt, nur um den Cursor bleibt ein Kreis: der Blick geht dahin, wo er soll.',f11t:'Spur hinter dem Cursor',f11d:'Eine weiche, ausklingende Spur: Bewegung bleibt auch im schnellen Schnitt lesbar.',f12t:'Marker und Tastenkürzel',f12d:'M setzt einen Marker, [ und ] springen dazwischen, ? zeigt alle Tasten.',f13t:'Titelkarte und Zoom-Presets',f13d:'Eine Titelkarte mit einem Klick, Zoom Sanft / Normal / Stark.',
h_s:'Shorts: die Kamera folgt Ihnen',s_s:'Bewegen Sie den Cursor — der vertikale 9:16-Rahmen folgt.',phone:'Ergebnis: ein fertiger vertikaler Short',h_t:'Trailer',prem:'Premiere am Montag',prem2:'19. Oktober, 18:00 Uhr (MESZ)',h_e:'Era II beginnt'}};
function setLang(l){document.documentElement.lang=l;
 document.querySelectorAll('[data-i]').forEach(e=>{const v=T[l][e.dataset.i];if(v!=null)e.textContent=v});
 document.querySelectorAll('.lang button').forEach(b=>b.classList.toggle('on',b.dataset.l===l));
 try{localStorage.setItem('mr-lang',l)}catch(e){}}
document.querySelectorAll('.lang button').forEach(b=>b.addEventListener('click',()=>setLang(b.dataset.l)));
(function(){let l='ru';try{l=localStorage.getItem('mr-lang')||''}catch(e){}
 if(!T[l]){const n=(navigator.language||'ru').slice(0,2);l=T[n]?n:'ru'}setLang(l)})();
// reveal on scroll
const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target)}}),{threshold:.12});
document.querySelectorAll('.rv').forEach(e=>io.observe(e));
// cards: light follows the pointer
document.querySelectorAll('.card').forEach(c=>c.addEventListener('pointermove',e=>{const r=c.getBoundingClientRect();c.style.setProperty('--mx',(e.clientX-r.left)+'px');c.style.setProperty('--my',(e.clientY-r.top)+'px')}));
// premiere countdown: Monday 19 Oct 2026, 18:00 Berlin (CEST) = 19:00 Moscow = 16:00 UTC (matches the YouTube premiere)
(function(){const T0=Date.parse('2026-10-19T16:00:00Z'),$=id=>document.getElementById(id);
 const two=n=>String(n).padStart(2,'0');
 function tick(){const d=T0-Date.now();const live=d<=0;$('cdBox').hidden=live;$('liveBox').hidden=!live;if(live)return;
  const s=Math.floor(d/1000);$('cd_d').textContent=Math.floor(s/86400);$('cd_h').textContent=two(Math.floor(s%86400/3600));$('cd_m').textContent=two(Math.floor(s%3600/60));$('cd_s').textContent=two(s%60)}
 tick();setInterval(tick,1000)})();
// ---- deep space: a 3D star field that keeps drifting, reacts to the pointer and rushes past on scroll ----
(function(){
 const sky=document.getElementById('sky'),sc=sky.getContext('2d'),star=document.getElementById('star'),gc=star.getContext('2d');
 const fly=document.getElementById('fly'),mochi=document.getElementById('mochi'),white=document.getElementById('white'),hero=document.getElementById('top'),cue=document.getElementById('cue'),cueT=document.getElementById('cueT'),arrive=document.getElementById('arrive');let mw=90,flyH=1,heroFit=1;
 const still=matchMedia('(prefers-reduced-motion:reduce)').matches;
 const small=innerWidth<720;let W,H,D,S,stars=[],shoot=[];
 const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),sm=(a,b,x)=>{const t=clamp((x-a)/(b-a));return t*t*(3-2*t)};
 function build(){const N=small?380:900;stars=[];for(let i=0;i<N;i++){const a=Math.random()*6.2832,r=Math.sqrt(Math.random())*3.4;stars.push({x:Math.cos(a)*r,y:Math.sin(a)*r,z:Math.random(),m:.5+Math.random()*1.5,t:Math.random()*9,k:Math.random()})}}
 let lastW=0,lastH=0;function resize(){const nw=innerWidth,nh=innerHeight;if(lastW&&nw===lastW&&Math.abs(nh-lastH)<160)return;lastW=nw;lastH=nh;D=Math.min(devicePixelRatio||1,1.5);W=nw;H=nh;mw=mochi.getBoundingClientRect().width||90;flyH=fly.offsetHeight;hero.style.transform='none';{const hh=hero.offsetHeight;heroFit=Math.min(1,(nh-8)/hh)}for(const c of [sky,star]){c.width=W*D;c.height=H*D}
  sc.setTransform(D,0,0,D,0,0);gc.setTransform(D,0,0,D,0,0);S=Math.max(W,H)*.55}
 build();resize();addEventListener('resize',resize);
 let mx=0,my=0,tx=0,ty=0;
 addEventListener('pointermove',e=>{tx=(e.clientX/W-.5)*2;ty=(e.clientY/H-.5)*2},{passive:true});
 if(window.DeviceOrientationEvent&&small)addEventListener('deviceorientation',e=>{if(e.gamma==null)return;tx=clamp(e.gamma/30,-1,1);ty=clamp((e.beta-45)/30,-1,1)},{passive:true});
 let lastScroll=0,p=0,pS=0,lastP=0,speed=0,tPrev=0,vis=true;
 addEventListener('scroll',()=>{lastScroll=performance.now()/1000},{passive:true});
 document.addEventListener('visibilitychange',()=>{vis=!document.hidden;if(vis)requestAnimationFrame(frame)});
 function prog(){if(still)return 0;const span=flyH-H*1.55;return span>0?clamp(scrollY/span):1}
 function drawStar(t){
  gc.clearRect(0,0,W,H);const cx=W/2,cy=H*.5,base=Math.min(W,H)*(small?.3:.26);
  // moon and a quiet guest
  const ma=clamp(1-p*3);if(ma>0){const mxp=W*.82,myp=H*.2,r=Math.min(W,H)*.05;gc.save();gc.globalAlpha=ma*.9;gc.fillStyle='#fff';gc.beginPath();gc.arc(mxp,myp,r,0,7);gc.fill();gc.globalCompositeOperation='destination-out';gc.beginPath();gc.arc(mxp-r*.38,myp-r*.16,r*.86,0,7);gc.fill();gc.restore()}
  const grow=1+Math.pow(p,4)*13,a=1-sm(.78,.88,p),pulse=1+.045*Math.sin(t*2.2);
  if(a<=0)return;
  const R=base*grow*pulse;
  let g=gc.createRadialGradient(cx,cy,0,cx,cy,R*2.1);g.addColorStop(0,'rgba(255,255,255,'+.42*a+')');g.addColorStop(.25,'rgba(255,255,255,'+.12*a+')');g.addColorStop(1,'rgba(255,255,255,0)');gc.fillStyle=g;{const q2=R*2.1;gc.fillRect(cx-q2,cy-q2,q2*2,q2*2)}
  g=gc.createRadialGradient(cx,cy,0,cx,cy,R*.42);g.addColorStop(0,'rgba(255,255,255,'+a+')');g.addColorStop(1,'rgba(255,255,255,0)');gc.fillStyle=g;{const q3=R*.42;gc.fillRect(cx-q3,cy-q3,q3*2,q3*2)}
  gc.save();gc.translate(cx,cy);gc.rotate(t*.04);gc.fillStyle='rgba(255,255,255,'+.95*a+')';
  for(let k=0;k<4;k++){gc.save();gc.rotate(k*Math.PI/2);const L=R*(k%2?.75:1.25),w=R*.045;gc.beginPath();gc.moveTo(-w,0);gc.quadraticCurveTo(-w*.2,L*.2,0,L);gc.quadraticCurveTo(w*.2,L*.2,w,0);gc.closePath();gc.fill();gc.restore()}
  gc.rotate(Math.PI/4+t*.03);for(let k=0;k<4;k++){gc.save();gc.rotate(k*Math.PI/2);const L=R*.7,w=R*.03;gc.beginPath();gc.moveTo(-w,0);gc.quadraticCurveTo(0,L*.25,0,L);gc.quadraticCurveTo(0,L*.25,w,0);gc.closePath();gc.globalAlpha=.7*a;gc.fill();gc.restore()}
  gc.restore();
 }
 function frame(ts){
  if(!vis)return;const t=ts/1000,dt=Math.min(.05,t-tPrev||.016);tPrev=t;
  p=prog();pS+=(p-pS)*Math.min(1,dt*7);const dp=Math.abs(pS-lastP)/Math.max(dt,.001);lastP=pS;speed+=(dp-speed)*Math.min(1,dt*6);
  mx+=(tx-mx)*Math.min(1,dt*3);my+=(ty-my)*Math.min(1,dt*3);
  hero.style.opacity=clamp(1-pS*2.6).toFixed(3);hero.style.transform='translate3d(0,'+(pS*-70).toFixed(1)+'px,0) scale('+(heroFit*(1+pS*.25)).toFixed(3)+')';
  white.style.opacity=(sm(.82,.87,pS)*(1-sm(.885,.935,pS))).toFixed(3);
  {const idle=t-lastScroll;const intro=pS<.8&&(pS<.03||idle>1.6),hold=pS>.985&&idle>1.4&&scrollY<flyH+H*.2;const want=!still&&(intro||hold);const key=hold&&!intro?'hint2':'hint';if(cue.dataset.k!==key){cue.dataset.k=key;const L=T[document.documentElement.lang]||T.ru;cueT.textContent=L[key];cueT.dataset.i=key}cue.classList.toggle('on',want)}
  arrive.style.opacity=sm(.93,.99,pS).toFixed(3);arrive.style.transform='translate3d(0,calc(-50% + '+((1-sm(.93,.99,pS))*30).toFixed(1)+'px),0)';
  // sky
  sc.clearRect(0,0,W,H);const cx=W/2,cy=H/2,travel=pS*pS*7+t*.018;
  const hy=sm(.1,.45,pS)*(1-sm(.95,1,pS)*.8),streak=Math.max(Math.min(.34,speed*.55),hy*.16);
  for(const s of stars){
   let z=((s.z-travel)%1+1)%1;if(z<.012)z=.012;
   const inv=1/(.12+.88*z),ox=mx*26*(1-z),oy=my*18*(1-z);
   const px=cx+s.x*S*inv*.5+ox,py=cy+s.y*S*inv*.5+oy;
   if(px<-60||px>W+60||py<-60||py>H+60)continue;
   const tw=.55+.45*Math.sin(t*(.8+s.k*2.4)+s.t),al=clamp(.25+(1-z)*1.1)*tw*(.8+.2*hy);
   const r=Math.min(3.4,s.m*(.45+inv*.2));
   if(streak>.01&&hy>.02){const z2=Math.min(1,z+streak*hy),i2=1/(.12+.88*z2),qx=cx+s.x*S*i2*.5+ox,qy=cy+s.y*S*i2*.5+oy;sc.strokeStyle='rgba(255,255,255,'+(al*.9).toFixed(3)+')';sc.lineWidth=Math.max(.6,r*.8);sc.beginPath();sc.moveTo(qx,qy);sc.lineTo(px,py);sc.stroke()}
   else{sc.fillStyle='rgba(255,255,255,'+al.toFixed(3)+')';sc.beginPath();sc.arc(px,py,r,0,6.2832);sc.fill()}
  }
  if(!still){ if(Math.random()<.007)shoot.push({x:Math.random()*W,y:Math.random()*H*.5,l:1,v:10+Math.random()*8});
   shoot=shoot.filter(s=>s.l>0);for(const s of shoot){sc.strokeStyle='rgba(255,255,255,'+s.l+')';sc.lineWidth=1.4;sc.beginPath();sc.moveTo(s.x,s.y);sc.lineTo(s.x-s.v*9,s.y-s.v*4.5);sc.stroke();s.x+=s.v;s.y+=s.v*.5;s.l-=.022} }
  // hero star + Mochi
  if(pS<1.001){drawStar(t);
   const q=pS,ease=q*q*(1.8-.8*q),w=mw;
   const x=W*(.14+.1*Math.sin(t*.27))*(1-ease)+W*.5*ease+Math.sin(t*.9)*18*(1-ease),y=H*(.3+.08*Math.sin(t*.6))*(1-ease)+H*.5*ease;
   const sc2=1-.92*ease;mochi.style.transform='translate('+(x-w/2)+'px,'+(y-w/2)+'px) rotate('+(Math.sin(t*.8)*.12-ease*.5)+'rad) scale('+sc2+')';
   mochi.style.opacity=(1-sm(.62,.82,q)).toFixed(3);
  }
  if(!still)requestAnimationFrame(frame)
 }
 requestAnimationFrame(frame);
 if(still){addEventListener('scroll',()=>requestAnimationFrame(frame),{passive:true})}
})();
// premiere player: nothing from YouTube is loaded until the visitor asks for it
(function(){const box=document.getElementById('yt'),b=document.getElementById('ytLoad');if(!box||!b)return;
 b.addEventListener('click',()=>{const f=document.createElement('iframe');f.src='https://www.youtube-nocookie.com/embed/'+box.dataset.id+'?rel=0&autoplay=1';f.title='MotionRecord Nova premiere';f.allow='autoplay; encrypted-media; picture-in-picture; fullscreen';f.allowFullscreen=true;box.replaceChildren(f)})})();
// shorts demo
(function(){const scr=document.getElementById('scr'),frm=document.getElementById('frm'),cur=document.getElementById('cur');
 let tx=.5,fx=.5,cx=.5;
 scr.addEventListener('pointermove',e=>{const r=scr.getBoundingClientRect();tx=Math.min(1,Math.max(0,(e.clientX-r.left)/r.width));cur.style.top=(e.clientY-r.top)+'px'});
 let t0=0;function f(t){const r=scr.getBoundingClientRect();if(!t0)t0=t;if(!scr.matches(':hover'))tx=.5+.35*Math.sin((t-t0)/1500);cur.style.top=cur.style.top||'50%';
  fx+=(tx-fx)*.08;cx=tx;const fw=frm.offsetWidth;frm.style.transform='translateX('+(fx*(r.width-fw))+'px)';cur.style.left=(cx*r.width)+'px';requestAnimationFrame(f)}
 requestAnimationFrame(f)})();
