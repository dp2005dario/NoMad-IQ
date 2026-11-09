// Inicio con tus datos de verdad. La app pone los datos en window.ECL (ver
// lib/features/home/home_page.dart) y manda lo nuevo con window.ECLin({...}).
// Lo que tocas se le pide a la app con toApp("...").
(function(){
var E=window.ECL||{};
function esc(t){return String(t==null?'':t).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
var CK='<svg class="i ckk" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.500l4.500 4.500L19 7.500"/></svg>';

// --- Arriba: dónde estás y "Probar aviso" (repite el último aviso de Flyra).
function place(){var c=$('q-place'),t=E.place||'';c.style.display=t?'':'none';$('q-place-t').textContent=t}
$('tst').onclick=function(){toApp('note')};

// --- Flyra: mantener pulsada la bola = hablarle; o escribirle.
var held=false;
orb.addEventListener('pointerdown',function(){if(held)return;held=true;toApp('hold:1')});
['pointerup','pointercancel','pointerleave'].forEach(function(n){orb.addEventListener(n,function(){if(!held)return;held=false;toApp('hold:0')})});
$('talk').onsubmit=function(e){e.preventDefault();var v=$('msg').value.trim();if(!v)return;$('msg').value='';$('msg').blur();toApp('ask:0:'+pack({q:v}))};

// --- Mi pasaporte: tus datos (escribiéndose uno a uno cuando llegan).
var pass=$('pass'),F={'f-ape':'ape','f-nom':'nom','f-nac':'nac','f-blood':'blood','f-num':'num','f-exp':'exp','f-dni':'dni','f-nacim':'nacim','f-val':'val'},first=true;
function typeTo(el,txt,cb){el.classList.remove('em');el.classList.add('tp');el.textContent='';var k=0;var iv=setInterval(function(){k++;el.textContent=txt.slice(0,k);if(k>=txt.length){clearInterval(iv);el.classList.remove('tp');el.insertAdjacentHTML('beforeend',CK);if(cb)cb()}},42)}
function fill(){var P=E.pass||{},jobs=[];
 Object.keys(F).forEach(function(id){var el=$(id),v=P[F[id]]||'';if(el.dataset.v===v)return;var was=el.dataset.v;el.dataset.v=v;
  if(!v){el.textContent=E.empty||'';el.classList.add('em');return}
  if(first||was===undefined){el.textContent=v;el.classList.remove('em');return}
  jobs.push([el,v])});
 var m=$('f-mrz');if(P.mrz){m.innerHTML=P.mrz.map(esc).join('<br>');m.classList.remove('em2')}else{m.textContent=E.mrzEmpty||'';m.classList.add('em2')}
 $('f-cta').querySelector('span').textContent=P.cta||'';pass.classList.toggle('done',!!P.done);
 var ph=$('q-photo'),add=$('q-addph');if(P.photo){ph.src=P.photo;ph.style.display='';add.style.display='none'}else{ph.style.display='none';add.style.display=''}
 first=false;if(!jobs.length)return;
 pass.scrollIntoView({behavior:'smooth',block:'center'});
 var i=0;(function nx(){if(i>=jobs.length)return;var j=jobs[i++];typeTo(j[0],j[1],function(){setTimeout(nx,120)})})()}
pass.addEventListener('click',function(e){if(e.target.closest('#q-addph,#q-photo'))return;toApp('scan')});
pass.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();toApp('scan')}});
$('q-addph').addEventListener('click',function(e){e.stopPropagation();toApp('photo')});
$('q-photo').addEventListener('click',function(e){e.stopPropagation();toApp('photo')});

// --- El álbum: tus cromos (los sellos de los monumentos), en páginas de 4.
var MON='<path d="M3 21h18M5 18V10M9.500 18V10M14.500 18V10M19 18V10M3 10l9-6 9 6z"/>';
var cur=0,open=false,busy=false,sw={done:false};
var pgR=$('pgR'),cb=$('cb'),leaf=$('leaf'),lf=$('lf'),lb=$('lb'),cov=$('cov'),bk=$('book');
function PG(){var p=(E.album||{}).pages||[];return p.length?p:[{t:'',c:[]},{t:'',c:[]}]}
function pg(k){var p=PG()[k]||{t:'',c:[]},h='<h4>'+esc(p.t)+'</h4>';for(var j=0;j<4;j++){var c=p.c[j];h+=c?'<div class="cd '+c.cl+'"><svg class="i" viewBox="0 0 24 24">'+MON+'</svg><small>'+esc(c.n)+'</small></div>':'<div class="cd e">?</div>'}return h+'<div class="pn">'+(k+1)+'</div>'}
function draw(){cb.innerHTML=pg(cur);pgR.innerHTML=pg(cur+1);label()}
function label(){var n=PG().length;$('pgn').textContent='Páginas '+(cur+1)+'–'+(cur+2)+' de '+n;$('pv').disabled=cur<=0;$('nx').disabled=cur>=n-2}
function setOpen(o){open=o;bk.dataset.open=o?1:0;cov.classList.toggle('open',o);$('pgbar').classList.toggle('on',o);$('swh').classList.toggle('on',o&&!sw.done);$('tap').style.display=o?'none':'';if(!o){cur=0}draw()}
function flip(d){if(!open||busy)return;var n=cur+d*2;if(n<0||n>PG().length-2)return;busy=true;sw.done=true;$('swh').classList.remove('on');
 leaf.classList.remove('anim');
 if(d>0){lf.innerHTML=pg(cur+1);lb.innerHTML=pg(n);pgR.innerHTML=pg(n+1);leaf.style.transform='rotateY(0)';leaf.classList.add('vis');void leaf.offsetWidth;leaf.classList.add('anim');leaf.style.transform='rotateY(-180deg)'}
 else{lb.innerHTML=pg(cur);lf.innerHTML=pg(n+1);cb.innerHTML=pg(n);leaf.style.transform='rotateY(-180deg)';leaf.classList.add('vis');void leaf.offsetWidth;leaf.classList.add('anim');leaf.style.transform='rotateY(0)'}
 setTimeout(function(){cur=n;leaf.classList.remove('anim','vis');draw();busy=false},900)}
$('covf').onclick=function(){if(!open)setOpen(true)};$('covf').onkeydown=function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();if(!open)setOpen(true)}};
$('bclose').onclick=function(){setOpen(false)};$('pv').onclick=function(e){e.stopPropagation();flip(-1)};$('nx').onclick=function(e){e.stopPropagation();flip(1)};
var sx=null,bw=$('bw');bw.addEventListener('pointerdown',function(e){sx=e.clientX});
bw.addEventListener('pointerup',function(e){if(sx===null||!open)return;var dx=e.clientX-sx;sx=null;if(dx<-30)flip(1);else if(dx>30)flip(-1);else if(Math.abs(dx)<8&&!e.target.closest('.nav')){var r=bk.getBoundingClientRect(),mid=r.left+(r.width/2);flip(e.clientX>mid?1:-1)}});
var FC=['#3DDC97','#9B7BFF','#FF8A65'];
function album(){var A=E.album||{};if(cur>PG().length-2)cur=0;draw();
 $('tap').innerHTML=esc(A.tap||'')+(A.howto?'<br>'+esc(A.howto):'');
 $('q-fsub').textContent=A.friends||'';
 var f=A.faces||[];$('q-faces').innerHTML=f.length?f.map(function(n,i){return'<i style="background:'+FC[i%3]+'">'+esc(n)+'</i>'}).join(''):'<img alt="" src="'+document.querySelector('.core img').src+'" style="width:34px;height:34px;border-radius:50%">'}

// --- SOS: al acabar la cuenta atrás, tus contactos con el mensaje y tu
// ubicación de verdad (WhatsApp o SMS) y el número de emergencias de donde
// estás.
var COL=['#FF8A9A','#58B4E6','#3DDC97','#FFC857','#9B7BFF','#FF8A65'];
function people(){return (E.contacts||[]).slice(0,3).map(function(c,i){return{n:c.n,p:c.p,c:COL[i%COL.length]}})}
function ecAv(c){return'<span class="eca" style="background:'+c.c+';--ac:'+c.c+'">'+esc(c.n.charAt(0).toUpperCase())+'</span>'}
window.ecAv=ecAv;
function sosInfo(){var S=E.sos||{};$('q-where').textContent=S.where||'';$('sp112').lastChild.textContent='Llamar al '+(S.call||'112');
 var m=document.querySelector('#spl .spmsg');if(m)m.innerHTML='<b>Mensaje que se enviará</b>«'+esc(S.msg||'')+'»'}
var _panel=sosPanel;sosPanel=function(){toApp('sos');_panel()};
sosGo=function(){var l=$('spl'),C=people(),WA='<svg class="i" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20l1.3-4.2A8 8 0 118 18.8z"/><path d="M9 9c0 3 3 6 6 6l1-1.500-2-1-1 .8c-1-.5-1.800-1.300-2.300-2.300l.8-1-1-2z"/></svg>';
 l.innerHTML='<li class="spmsg"></li>'+(C.length?C.map(function(c,i){return'<li id="sp'+i+'" class="spx">'+ecAv(c)+'<div class="spxm"><b>'+esc(c.n)+'</b><small>'+esc(c.p)+'</small><a href="#" class="spsms" data-sms="'+i+'">Enviar por SMS</a></div><span class="stt pend" id="st'+i+'"><i></i><em>Pendiente</em></span><button type="button" class="spwa" data-wa="'+i+'">'+WA+'Enviar a '+esc(c.n)+' por WhatsApp</button></li>'}).join(''):'<li class="spmsg"><b>Aún no tienes contactos de emergencia</b>Añádelos abajo, en «Tus 3 contactos de emergencia». Puedes llamar al número de emergencias.</li>');
 sosInfo();$('spt').textContent=C.length?'Pulsa Enviar en WhatsApp para avisar':'Llama al número de emergencias';$('spw').hidden=true;$('sp2').hidden=false;
 if(!l._h){l._h=1;l.addEventListener('click',function(e){
  var w=e.target.closest('[data-wa]'),s=e.target.closest('[data-sms]');
  if(!w&&!s)return;e.preventDefault();
  var i=+(w?w.dataset.wa:s.dataset.sms),li=$('sp'+i),st=$('st'+i);if(!li)return;
  toApp((w?'wa:':'sms:')+i);
  // No podemos saber si pulsaste Enviar: se marca como abierto.
  li.classList.add('ok');st.classList.remove('pend');st.querySelector('em').textContent=w?'Abierto en WhatsApp':'Abierto en SMS';
  if(document.querySelectorAll('#spl .spx.ok').length===people().length)$('spt').textContent='Mensajes abiertos para tus contactos'})}};
$('sp112').onclick=function(){toApp('call')};

// --- Tus contactos de emergencia (los 3 primeros que guardaste).
var L=$('ecl'),B=$('ecok'),ST=$('ecs'),ok=false,SEL=[false,false,false],sig='';
function render(){var C=people(),now=JSON.stringify(C);if(now!==sig){sig=now;ok=false;ST.textContent=''}
 var h='';for(var i=0;i<3;i++){var c=C[i];
  h+=c?'<li class="'+(ok?'ok':SEL[i]?'sel':'')+'" data-s="'+i+'" role="button" tabindex="0" aria-pressed="'+(!!SEL[i])+'">'+ecAv(c)+'<div class="ect"><b>'+esc(c.n)+'</b><span class="ecp">'+esc(c.p)+'</span>'+(ok?'<span class="ectag e">CONFIRMADO</span>':'<span class="ectag c">ELEGIDO POR TI</span>')+'</div><span class="ecck" aria-hidden="true">&#10003;</span><div class="ecact"><button type="button" class="ecb2" data-i="'+i+'" aria-label="Cambiar el contacto '+(i+1)+'">Cambiar</button></div></li>'
   :'<li data-s2="'+i+'"><span class="eca" style="background:#1B2730;--ac:#33444E;color:#9FB0B8">+</span><div class="ect"><b>Contacto '+(i+1)+'</b><span class="ecp" style="color:#9FB0B8">'+esc(E.empty||'')+'</span></div><div class="ecact"><button type="button" class="ecb2" data-i="'+i+'" aria-label="Añadir el contacto '+(i+1)+'">Añadir</button></div></li>'}
 L.innerHTML=h;B.textContent=ok?'Contactos confirmados':'Confirmar contactos';B.classList.toggle('done',ok);B.disabled=!C.length}
L.addEventListener('click',function(e){var b=e.target.closest('[data-i]');if(b){toApp('pick:'+b.dataset.i);return}var c=e.target.closest('[data-s]');if(c){SEL[+c.dataset.s]=!SEL[+c.dataset.s];render()}});
$('ecmore').addEventListener('click',function(){toApp('more')});
B.addEventListener('click',function(){if(!people().length)return;ok=true;ST.textContent='Listo. Si pulsas el SOS, avisaremos a '+(people().length===1?'esta persona.':'estas '+people().length+' personas.');render()});

window.ECLin=function(d){Object.assign(E,d||{});place();fill();album();render();sosInfo()};
place();fill();album();render();sosInfo();
})();
