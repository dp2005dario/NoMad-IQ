# Crea assets/copy_trip/copiar.html a partir de la maqueta "Copiar".
# Uso: python3 tool/build_copy_page.py <maqueta.html> assets/copy_trip/copiar.html
#
# Se queda TODO lo de la maqueta (historias arriba, tarjetas con el dibujo de
# la ciudad, mapa 3D con la ruta, estrellas, "Copiar este viaje", carga al
# bajar con esqueletos y el visor de historias) y solo se quitan los datos de
# ejemplo y las notas. Lo real lo pone la app
# (lib/features/copy_trip/copy_page.dart) en la marca /*ECLIPTA*/:
#   - los viajes que la gente PUBLICA en el muro (con su nombre, su texto,
#     lo que pagó por cada cosa, sus votos de verdad);
#   - abrir un viaje con su código sigue funcionando con su enlace
#     (/copy-trip?code=...);
#   - la cara de cada autor es un dibujo hecho a partir de su nombre (no hay
#     fotos de perfil), y el mapa es un dibujo sin nombres de calles.
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
a = s.find('<title>')
head = ('<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n')
s = head + s[a:]


def rep(old, new, count=1):
    global s
    assert s.count(old) >= 1, old[:90]
    s = s.replace(old, new, count)


def cut(start, end, new):
    """Cambia lo que va de [start] (incluido) a [end] (sin incluir)."""
    global s
    a = s.find(start)
    b = s.find(end, a)
    assert a >= 0 and b > a, (start[:40], end[:40])
    s = s[:a] + new + s[b:]


rep('html,body{height:100%}', 'html,body{height:100%;margin:0}')
# --- Cabecera: sin "Datos de ejemplo" (nada más cambia).
rep('<h1>Copia este viaje</h1><p>Rutas de otros viajeros, listas para hacerlas tuyas</p></div><span class="ex">Datos de ejemplo</span>',
    '<h1 id="t_title"></h1><p id="t_sub"></p></div>')
rep('.ex{', ''
    '.msg{padding:26px 18px;border-radius:24px;background:linear-gradient(160deg,var(--panel2),var(--panel));border:1px solid var(--line);text-align:center;color:#c6d3d0;font-weight:600;display:flex;flex-direction:column;gap:12px;align-items:center}\n'
    '.msg:empty{display:none}.msg button{padding:10px 18px;border-radius:14px;background:var(--panel2);border:1px solid var(--line);font-weight:700}\n'
    '.tb p:empty{display:none}\n'
    '.ex{')
rep('<div class="stories" id="stories" aria-label="Historias destacadas"></div>', '<div class="stories" id="stories"></div>')
rep(' <div class="feed" id="feed"></div>', ' <div class="msg" id="msg"></div>\n <div class="feed" id="feed"></div>')
cut(' <div class="foot">', '</div>\n<div class="sv"', '')
rep('<div class="sv" id="sv">', '</div>\n<div class="sv" id="sv">')
s = s.replace('</div>\n</div>\n<div class="sv" id="sv">', '</div>\n<div class="sv" id="sv">', 1)

# --- Mapa: sin nombres de calles ni de estaciones inventados.
rep("var ST_DEF=['Centro','Norte','Plaza Mayor','Sur','Mercado','Univ.','Parque','Puerto','Este','Oeste'],STR_DEF=['Calle Mayor','Avenida Central','Calle del Sol','Paseo del Río','Calle Nueva','Calle Larga','Plaza Vieja','Calle Real','Gran Vía','Calle del Mar'];",
    'var ST_DEF=[],STR_DEF=[];')
rep("if(s>.5){ctx.font='700 '+(s>1.5?15:10)+'px Manrope,sans-serif';ctx.textAlign='center';", "if(s>.5&&m.str.length){ctx.font='700 '+(s>1.5?15:10)+'px Manrope,sans-serif';ctx.textAlign='center';")
rep("if(s>.3){ctx.textAlign='left';ctx.lineWidth=3;", "if(s>.3&&m.st[q]){ctx.textAlign='left';ctx.lineWidth=3;")

# --- Un dibujo para las ciudades que no son una de las seis de la maqueta.
rep('var ILL={', '''var ILL={
generic:function(i){var s=sky(i,.5);
 for(var k=0;k<11;k++){var x=k*30-6+H(k,3,1)*8,w=22+H(k,4,1)*12,h=28+H(k,5,1)*58;s+='<rect x="'+x.toFixed(0)+'" y="'+(140-h).toFixed(0)+'" width="'+w.toFixed(0)+'" height="'+h.toFixed(0)+'" fill="url(#st'+i+')" stroke="#e9fff5" stroke-width=".7" opacity="'+(.55+H(k,6,1)*.35).toFixed(2)+'"/>';
  for(var y=140-h+6;y<132;y+=10)for(var c=x+4;c<x+w-5;c+=7)s+='<rect x="'+c.toFixed(0)+'" y="'+y.toFixed(0)+'" width="3" height="4" fill="'+(H(c|0,y|0,k)>.55?'#F5B84B':'#0e2a28')+'" opacity=".8"/>'}
 s+='<circle cx="160" cy="58" r="20" fill="#3DDC97" opacity=".25"/><circle cx="160" cy="58" r="11" fill="#3DDC97"/><path d="M160 69V96" stroke="#e9fff5" stroke-width="2.4"/><circle cx="160" cy="58" r="4" fill="#06281a"/>';
 return s+ground(i)},''')

# --- Los autores y viajes de ejemplo -> los viajes reales del muro.
cut('function es(n,d){', 'var SKIN=', r'''var ECL=/*ECLIPTA*/{"lang":"es","t":{},"trips":[],"msg":"","retry":false,"toast":""};
var T=ECL.t||{},LANG=ECL.lang||"es";function tx(k){return T[k]||k}
function esc(v){return String(v==null?'':v).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function toApp(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}}
function es(n,d){return n.toLocaleString(LANG,{minimumFractionDigits:d||0,maximumFractionDigits:d||0})}
function fill(k,o){var v=tx(k);for(var q in o)v=v.split('{'+q+'}').join(o[q]);return v}
''')
cut('/* ---------- viajes de ejemplo ---------- */', 'var STAR=', r'''/* ---------- los viajes del muro (los pone la app) ---------- */
var TRIPS=(ECL.trips||[]).map(function(x,i){return {id:i,u:x.u,days:x.days,daysT:x.daysT,cost:x.cost,perDay:x.perDay,votes:x.votes||0,avg:x.avg,mine:x.mine||0,own:!!x.own,copied:!!x.copied,ago:x.ago,author:x.a,
 d:{k:ILL[x.ill]?x.ill:'generic',city:x.city,title:x.title,desc:x.note,seed:x.seed,stops:x.stops.map(function(p){return p.n}),prices:x.stops.map(function(p){return p.p})}}});
/* La ruta del dibujo: una parada por cada cosa del viaje (como mucho 8). */
function routeFor(d,seed){var pts=[],stops=[],n=Math.max(1,Math.min(8,d.stops.length)),f=3/Math.max(1,n-1);for(var i=0;i<n;i++){var a=-1.2+i*.9*f+H(seed,i,1)*.3,r=380+H(seed,i,2)*260;var x=Math.cos(a)*r*(i%2?1:-1)*.9+(i-(n-1)/2)*120*f,y=Math.sin(a*1.4)*r*.7-80+i*60*f;stops.push({x:x,y:y})}
 for(i=0;i<stops.length-1;i++){var A=stops[i],Bq=stops[i+1],mx=(A.x+Bq.x)/2+(H(seed,i,9)-.5)*160,my=(A.y+Bq.y)/2+(H(seed,i,8)-.5)*160;for(var t=0;t<=1;t+=.1){var u=1-t;pts.push([u*u*A.x+2*u*t*mx+t*t*Bq.x,u*u*A.y+2*u*t*my+t*t*Bq.y])}}return {pts:pts,stops:stops}}
function mapSpec(tr,big){var r=routeFor(tr.d,tr.d.seed*3+tr.id%3),cx=0,cy=0,n=r.stops.length;r.stops.forEach(function(s){cx+=s.x/n;cy+=s.y/n});return {seed:tr.d.seed+tr.id%3*7,cx:cx,cy:cy,s:big?.42:.5,yaw:.5,pitch:1.0,route:r.pts,stops:r.stops,pins:r.stops.map(function(s,i){return {x:s.x,y:s.y,name:tr.d.stops[i],type:fill('stop',{n:i+1}),main:i===0,col:'#3DDC97'}})}}
function mapLabel(n){return n===1?tx('map1'):fill('mapN',{n:n})}
function votesText(n){return n===1?tx('vote1'):fill('votesN',{n:es(n)})}
''')
cut('function cardHTML(t){', 'var MMS={}', r'''function cardHTML(t){var k='c'+(uid++),d=t.d;t._k=k;
 var sc=ILL[d.k]('b'+k),n=Math.min(8,d.stops.length);
 return '<div class="th"><div class="av">'+avatar(t.u,k)+'</div><div><b>'+esc(t.author)+'</b><span>@'+esc(t.author)+' &middot; '+esc(t.ago)+'</span></div><em>'+esc(d.city)+'</em></div>'+
 '<div class="ban"><svg viewBox="0 0 320 150" preserveAspectRatio="xMidYMid slice" role="img" aria-label="'+esc(d.city)+'">'+sc+'</svg><div class="chips"><i>'+esc(t.daysT)+'</i><i>'+esc(t.cost)+'</i></div><h3>'+esc(d.title)+'</h3></div>'+
 '<div class="mapb"><canvas id="m'+k+'"></canvas><div class="lb">'+esc(mapLabel(n))+'</div></div>'+
 '<div class="tb"><p>'+esc(d.desc)+'</p><div class="stats"><div><span>'+esc(tx('duration'))+'</span><b>'+esc(t.daysT)+'</b></div><div><span>'+esc(tx('stops'))+'</span><b>'+d.stops.length+'</b></div><div><span>'+esc(tx('cost'))+'</span><b>'+esc(t.cost)+'</b></div><div><span>'+esc(tx('perDay'))+'</span><b>'+esc(t.perDay)+'</b></div></div>'+
 '<div class="rate"><div class="stars" role="radiogroup">'+[1,2,3,4,5].map(function(n){return '<button data-v="'+n+'" role="radio" aria-label="'+n+' ★">'+STAR+'</button>'}).join('')+'</div><div class="rt"></div></div>'+
 '<button class="copy'+(t.copied?' done':'')+'">'+'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="3"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg><span>'+esc(tx(t.copied?'copied':'copy'))+'</span></button></div>'}
function paint(el,t,anim){var btns=el.querySelectorAll('.stars button'),v=t.mine||Math.round(t.avg||0);[].forEach.call(btns,function(b,i){b.classList.toggle('on',i<v);b.classList.remove('pop');if(anim&&i<v){b.style.animationDelay=(i*70)+'ms';void b.offsetWidth;b.classList.add('pop')}});
 el.querySelector('.rt').innerHTML=(t.votes?'<b>'+es(t.avg,1)+'</b> &middot; '+esc(votesText(t.votes)):esc(tx('noVotes')))+' &middot; '+esc(t.own?tx('yours'):t.mine?fill('yourVote',{n:t.mine}):tx('tapRate'))}
/* Copiar: el botón se queda en "Copiado" y la app lo guarda en tus viajes. */
function copyTrip(t,b){if(t.copied)return;t.copied=true;b.classList.add('done');b.querySelector('span').textContent=tx('copied');toast(tx('copiedToast'));toApp('copy:'+t.id);
 [].forEach.call(document.querySelectorAll('.trip'),function(el){if(el._t===t){var cb=el.querySelector('.copy');cb.classList.add('done');cb.querySelector('span').textContent=tx('copied')}})}
''')
rep("el.querySelector('.stars').addEventListener('click',function(e){var b=e.target.closest('button');if(!b)return;var v=+b.dataset.v;if(t.mine){t.avg=(t.avg*t.votes-t.mine+v)/t.votes}else{t.avg=(t.avg*t.votes+v)/(t.votes+1);t.votes++}t.mine=v;paint(el,t,true);toast('Gracias por puntuar con '+v+(v===1?' estrella':' estrellas'))});",
    "el.querySelector('.stars').addEventListener('click',function(e){var b=e.target.closest('button');if(!b)return;if(t.own){toast(tx('ownRate'));return}var v=+b.dataset.v;if(t.mine){t.avg=(t.avg*t.votes-t.mine+v)/t.votes}else{t.avg=((t.avg||0)*t.votes+v)/(t.votes+1);t.votes++}t.mine=v;paint(el,t,true);toast(v===1?tx('thanks1'):fill('thanksN',{n:v}));toApp('rate:'+t.id+':'+v)});")
rep("var cb=el.querySelector('.copy');cb.addEventListener('click',function(){t.copied=!t.copied;cb.classList.toggle('done',t.copied);cb.querySelector('span').textContent=t.copied?'Copiado a Mis viajes':'Copiar este viaje';if(t.copied)toast('Viaje copiado (ejemplo)')});",
    "var cb=el.querySelector('.copy');cb.addEventListener('click',function(){copyTrip(t,cb)});")
# --- Historias: las de los viajes del muro (los primeros, como mucho 8).
rep("var SU=[0,1,2,3,4,5,7,6].map(function(u,j){return {u:u,tr:TRIPS[(j*3)%30]}});",
    "var SU=TRIPS.slice(0,8).map(function(t){return {u:t.u,tr:t}});")
rep("var us=USERS[s.u];return '<button class=\"st\" data-j=\"'+j+'\"><div class=\"ring\"><div>'+avatar(s.u,'s'+j)+'</div></div><span>'+us[0].split(' ')[0]+'</span></button>'",
    "return '<button class=\"st\" data-j=\"'+j+'\"><div class=\"ring\"><div>'+avatar(s.u,'s'+j)+'</div></div><span>'+esc(s.tr.author.split(' ')[0])+'</span></button>'")
rep("d=t.d,us=USERS[s.u],box=", "d=t.d,box=")
rep("<div><b>'+us[0]+'</b><span>'+d.city+' &middot; '+t.ago+'</span></div><button id=\"sxc\" aria-label=\"Cerrar\">&times;</button>",
    "<div><b>'+esc(t.author)+'</b><span>'+esc(d.city)+' &middot; '+esc(t.ago)+'</span></div><button id=\"sxc\" aria-label=\"'+esc(tx('close'))+'\">&times;</button>")
rep("sc='<div class=\"sc\"><h2>'+d.title+'</h2><p>'+d.desc+'</p></div>'", "sc='<div class=\"sc\"><h2>'+esc(d.title)+'</h2><p>'+esc(d.desc)+'</p></div>'")
rep("sc='<div class=\"sc\"><h2>La ruta, parada a parada</h2><p>Mira el recorrido en 3D y gira el mapa mentalmente: '+d.stops.join(', ')+'.</p></div>'",
    "sc='<div class=\"sc\"><h2>'+esc(tx('routeTitle'))+'</h2><p>'+esc(fill('routeBody',{list:d.stops.slice(0,8).join(', ')}))+'</p></div>'")
rep("sc='<div class=\"sc\"><h2>'+t.days+' días &middot; '+es(t.cost)+' €</h2><ul>'+d.stops.map(function(p,q){return '<li><i>'+(q+1)+'</i>'+p+'<span>día '+(q%t.days+1)+'</span></li>'}).join('')+'</ul><button class=\"copy\" id=\"svc\"><span>Copiar este viaje</span></button></div>'",
    "sc='<div class=\"sc\"><h2>'+esc(t.daysT)+' &middot; '+esc(t.cost)+'</h2><ul>'+d.stops.slice(0,6).map(function(p,q){return '<li><i>'+(q+1)+'</i>'+esc(p)+'<span>'+esc(d.prices[q])+'</span></li>'}).join('')+'</ul><button class=\"copy'+(t.copied?' done':'')+'\" id=\"svc\"><span>'+esc(tx(t.copied?'copied':'copy'))+'</span></button></div>'")
rep("var sc2=$('#svc');if(sc2)sc2.onclick=function(){t.copied=true;toast('Viaje copiado (ejemplo)');this.classList.add('done');this.querySelector('span').textContent='Copiado a Mis viajes'};",
    "var sc2=$('#svc');if(sc2)sc2.onclick=function(){copyTrip(t,sc2)};")
# --- Arranque: textos, botones de la cabecera y el aviso si no hay viajes.
rep('loadMore(3);requestAnimationFrame(frame);',
    "$('#t_title').textContent=tx('title');$('#t_sub').textContent=tx('sub');\n"
    "var MSG=ECL.msg||(TRIPS.length?'':tx('empty'));if(MSG){$('#msg').innerHTML='<span>'+esc(MSG)+'</span>'+(ECL.retry?'<button id=\"rt\">'+esc(tx('retry'))+'</button>':'');var rb=$('#rt');if(rb)rb.onclick=function(){toApp('retry')}}\n"
    "if(ECL.toast)setTimeout(function(){toast(ECL.toast)},300);\n"
    "if(TRIPS.length)loadMore(Math.min(3,TRIPS.length));requestAnimationFrame(frame);")
assert 'ejemplo' not in s.lower(), s[s.lower().find('ejemplo') - 200:s.lower().find('ejemplo') + 50]
assert 'USERS' not in s and 'DST' not in s
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
