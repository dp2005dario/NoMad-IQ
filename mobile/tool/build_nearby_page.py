# Crea assets/nearby/cerca.html a partir de la maqueta "Cerca de ti".
# Uso: python3 tool/build_nearby_page.py <maqueta.html> assets/nearby/cerca.html
#
# Se queda TODO lo de la maqueta (pestañas, mapa 3D, tarjetas, paseo) y solo
# se quitan los datos de ejemplo y las notas. Los textos en tu idioma y los
# sitios REALES (OpenStreetMap) los pone la app
# (lib/features/nearby/nearby_screen.dart) en la marca /*ECLIPTA*/.
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
# Solo la página (sin el envoltorio del visor de artefactos).
a = s.find('<title>')
head = ('<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n')
s = head + s[a:]


def rep(old, new, count=1):
    global s
    assert s.count(old) >= 1, old[:90]
    s = s.replace(old, new, count)


# El visor de la maqueta quitaba el margen del body: aquí también.
rep('html,body{height:100%}', 'html,body{height:100%;margin:0}')

# --- Cabecera: sin la etiqueta "Datos de ejemplo"; barrio y hora reales.
rep('<button class="back" aria-label="Volver">', '<button class="back" id="back">')
rep('<div class="ht"><h1>Cerca de ti</h1><p>Madrid &middot; Sol &middot; ahora 18:20</p></div><span class="ex">Datos de ejemplo</span>',
    '<div class="ht"><h1 id="t_title"></h1><p id="t_sub"></p></div>')
rep('<button class="tab" role="tab" data-t="0" aria-selected="true">Ofertas ya</button><button class="tab" role="tab" data-t="1" aria-selected="false">Gratis</button><button class="tab" role="tab" data-t="2" aria-selected="false">Tengo 2 horas</button>',
    '<button class="tab" role="tab" data-t="0" aria-selected="false"></button><button class="tab" role="tab" data-t="1" aria-selected="false"></button><button class="tab" role="tab" data-t="2" aria-selected="false"></button>')
for old, new in (('<button id="zi" aria-label="Acercar">', '<button id="zi">'),
                 ('<button id="zo" aria-label="Alejar">', '<button id="zo">'),
                 ('<button id="t3" aria-label="Inclinacion 3D" aria-pressed="true">', '<button id="t3" aria-pressed="true">'),
                 ('<button id="rc" aria-label="Centrar en mi posicion">', '<button id="rc">'),
                 ('<button id="ex" aria-label="Ampliar mapa" aria-pressed="false">', '<button id="ex" aria-pressed="false">')):
    rep(old, new)
rep('<div class="credit">Mapa ilustrativo generado</div>', '<div class="credit" id="t_credit"></div>')
# Estilo del aviso de lista vacía (mismo look que una tarjeta).
rep('.foot{', '.empty{padding:22px 18px;border-radius:22px;background:linear-gradient(160deg,var(--panel2),var(--panel));border:1px solid var(--line);color:var(--mut);font-weight:600;text-align:center;display:flex;flex-direction:column;gap:12px;align-items:center;animation:up .55s cubic-bezier(.2,.8,.2,1) both}\n.empty .go{align-self:center}\n.foot{')

# --- Iconos nuevos para lo que hay de verdad en el mapa (agua, baños, wifi,
# enchufes, monumentos y castillos), con el mismo dibujo que los de la maqueta.
rep(" church:{c:['#ffe28a','#d19b1d'],g:'M12 2v5M9.5 4.5h5M5 21V12l7-5 7 5v9M10 21v-5h4v5',n:'Templo'}};",
    " church:{c:['#ffe28a','#d19b1d'],g:'M12 2v5M9.5 4.5h5M5 21V12l7-5 7 5v9M10 21v-5h4v5',n:'Templo'},\n"
    " water:{c:['#9fd8ff','#2f8fe0'],g:'M12 3c3 4.5 6 8 6 11a6 6 0 0 1-12 0c0-3 3-6.5 6-11z',n:''},\n"
    " wc:{c:['#c9f0ff','#4aa3c9'],g:'M7 4.5h.01M17 4.5h.01M5 8h4l-.5 6H8v6M6 14v6M15 8h4l1.5 7H14L15.5 8M16 15v5M18 15v5',n:''},\n"
    " wifi:{c:['#d6c8ff','#8B7CF6'],g:'M2 9a15 15 0 0 1 20 0M5.5 12.5a10 10 0 0 1 13 0M9 16a5 5 0 0 1 6 0M12 19.5h.01',n:''},\n"
    " plug:{c:['#ffe9a0','#e0a92a'],g:'M9 3v5M15 3v5M6 8h12v3a6 6 0 0 1-12 0zM12 17v4',n:''},\n"
    " monument:{c:['#ffc9a8','#d9774a'],g:'M12 2l2 4v13h-4V6zM7 21h10M8 19h8',n:''},\n"
    " castle:{c:['#e0d0b8','#9a7b55'],g:'M4 21V8h3v3h3V8h4v3h3V8h3v13zM10 21v-5h4v5',n:''}};\n"
    "/* Todo lo que viene de OpenStreetMap se escapa antes de pintarlo. */\n"
    "function esc(v){return String(v==null?'':v).replace(/[&<>\"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c]})}")
rep("font-size=\"10.5\" fill=\"#fff\" letter-spacing=\".4\">'+initials+'</text>'", "font-size=\"10.5\" fill=\"#fff\" letter-spacing=\".4\">'+esc(initials)+'</text>'")

# --- Los datos de ejemplo -> los sitios reales que manda la app.
a = s.find('/* ---------- datos de ejemplo ---------- */')
b = s.find("TABS.forEach(function(L,ti)")
assert a > 0 and b > a
s = s[:a] + '''/* ---------- datos reales (los pone la app) ----------
   offers: ofertas (aún no hay fuente fiable: vacío = "Sin datos")
   free: sitios gratis cerca (OpenStreetMap) · plans: planes de hasta 2 h
   d = metros, a = ángulo (0 = este, hacia abajo = sur) */
var ECL=/*ECLIPTA*/{"lang":"es","t":{},"offers":[],"free":[],"plans":[],"tab":1,"place":"","attr":"","msg":"","retry":false};
var T=ECL.t||{};function tx(k){return T[k]||k}
var TABS=[ECL.offers||[],ECL.free||[],ECL.plans||[]];
/* El mapa es una ilustración: sin nombres de calles ni estaciones inventados. */
var cur={ang:.2,seed:5,ro:-900,ph:1.1,ra:.45,st:[],str:[]};
function post2(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}}
''' + s[b:]
rep("o.id=ti*20+i;", "o.id=ti*100+i;")
# Sin nombres de calles ni de estaciones (serían inventados).
rep("if(s>.5){ctx.font='700 '+(s>1.5?15:10)+'px Manrope,sans-serif';", "if(s>.5&&m.str.length){ctx.font='700 '+(s>1.5?15:10)+'px Manrope,sans-serif';")
rep("if(s>.3){ctx.textAlign='left';ctx.lineWidth=3;", "if(s>.3&&m.st[q]){ctx.textAlign='left';ctx.lineWidth=3;")
rep("var RINGS=[[400,'5 min'],[800,'10 min'],[1600,'20 min a pie']]",
    "var RINGS=[[400,tx('min').replace('{n}',5)],[800,tx('min').replace('{n}',10)],[1600,tx('minWalk').replace('{n}',20)]]")
# Horas en tu idioma y con el reloj del móvil.
rep("function hm(m){var h=Math.floor(m/60),r=Math.round(m%60);return h?(r?h+' h '+r+' min':h+' h'):r+' min'}",
    "function hm(m){var h=Math.floor(m/60),r=Math.round(m%60),H_=tx('h').replace('{h}',h),M_=tx('min').replace('{n}',r);return h?(r?H_+' '+M_:H_):M_}")
rep("function clock(add){var t=18*60+20+add;", "function clock(add){var d0=new Date(),t=d0.getHours()*60+d0.getMinutes()+add;")
rep("function remain(o){return Math.max(1,o.end-Math.floor((Date.now()-now0)/60000))}",
    "function remain(o){return Math.max(1,o.end-Math.floor((Date.now()-now0)/60000))}\n"
    "function left(o){return (tab===1?tx('closesIn'):tx('endsIn')).replace('{time}',hm(remain(o)))}")

# --- Tarjetas.
a = s.find('function render(){')
b = s.find('function pick(o,scroll){')
s = s[:a] + r'''function render(){
 var L=items(),h='';
 if(tab===2&&L.length)h+='<div class="tools"><span>'+esc(tx('fit'))+'</span><div class="seg" id="seg"><button data-s="dur" aria-pressed="'+(sortBy==='dur')+'">'+esc(tx('sortDur'))+'</button><button data-s="walk" aria-pressed="'+(sortBy==='walk')+'">'+esc(tx('sortWalk'))+'</button><button data-s="pr" aria-pressed="'+(sortBy==='pr')+'">'+esc(tx('sortPrice'))+'</button></div></div>';
 L.forEach(function(o,i){var chap,bar='',tx_='';
  if(tab===2){var f=o.dur/120;
   /* Precio: "Gratis" si OSM lo dice; si no se sabe, no se pone nada. */
   tx_='<div class="tx"><span style="color:var(--mint)">'+esc(tx('endsAt').replace('{time}',clock(o.walk+o.dur)))+'</span>'+(o.pr==null?'':'<span style="color:var(--mut);font-weight:700">'+esc(o.pr===0?tx('free'):o.pr+' €')+'</span>')+'</div>';
   bar='<div class="pr"><i style="width:'+Math.round(f*100)+'%;background:linear-gradient(90deg,#8B7CF6,#3DDC97)"></i></div>';
   chap='<div class="chapa" style="background:linear-gradient(150deg,#fff,'+KIND[o.k].c[0]+')"><b>'+esc(o.dur>=60?tx('h').replace('{h}',Math.floor(o.dur/60))+(o.dur%60?' '+o.dur%60:''):tx('min').replace('{n}',o.dur))+'</b><small>'+esc(tx('plan').toLocaleUpperCase(ECL.lang))+'</small></div>'}
  else{chap='<div class="chapa" style="background:linear-gradient(150deg,#fff,'+esc(o.cp[2])+' 65%)"><b>'+esc(o.cp[0])+'</b><small>'+esc(o.cp[1])+'</small></div>';
   if(o.end!=null){var r=remain(o),f=r/o.tot,col=r<30?'var(--red)':'var(--amber)';
    tx_='<div class="tx" style="color:'+col+'"><span class="rm" data-i="'+i+'">'+esc(left(o))+'</span></div>';
    bar='<div class="pr"><i class="rb" style="width:'+Math.min(100,Math.round(f*100))+'%;background:'+col+'"></i></div>'}
   else if(o.hrs)tx_='<div class="tx" style="color:var(--mut)"><span>'+esc(o.hrs)+'</span></div>'}
  h+='<article class="card'+(sel===o?' sel':'')+'" data-id="'+o.id+'" style="animation-delay:'+(i*70)+'ms"><div class="fa">'+facade(o.k,o.id,o.ini)+chap+'<div class="bg" style="background:'+grad(o.k)+'">'+glyph(o.k)+'</div></div>'+
  '<div class="cb"><h3>'+esc(o.t)+'</h3><div class="vn"><span>'+esc(o.v)+'</span></div><div class="vn">'+WALK+'<b>'+esc(tab===2?tx('walkMin').replace('{n}',o.walk):tx('m').replace('{m}',o.d))+'</b><span>'+esc(tab===2?tx('toFirst'):'· '+tx('walkMin').replace('{n}',Math.max(1,Math.round(o.d/75))))+'</span></div>'+
  '<div class="row"><div class="tm">'+tx_+bar+'</div><button class="go" data-go="'+o.id+'" aria-pressed="'+(sel===o&&showRoute)+'">'+esc(tx('go'))+'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14M13 6l6 6-6 6"/></svg></button></div></div></article>'});
 /* Lista vacía: por qué (sin GPS, sin red, sin datos) y, si se puede, reintentar. */
 if(!L.length)h+='<div class="empty"><span>'+esc(ECL.msg||[tx('noOffers'),tx('noFree'),tx('noPlans')][tab])+'</span>'+(ECL.retry?'<button class="go" id="retry">'+esc(tx('retry'))+'</button>':'')+'</div>';
 if(ECL.attr)h+='<div class="foot">'+esc(ECL.attr)+'</div>';
 $('#list').innerHTML=h;
 var info=[tx('infoOffers'),tx('infoFree'),tx('infoPlans')][tab];$('#mapinfo').innerHTML='<b>'+L.length+'</b> &middot; '+esc(info);
 pinsEl.innerHTML='';pinEls=[];
 L.forEach(function(o){var e=document.createElement('button');e.className='pin'+(sel===o?' sel':'');e._h=o;e.setAttribute('aria-label',o.dest);
  e.innerHTML='<div class="bd" style="background:'+grad(o.k)+'">'+glyph(o.k)+'</div><div class="tg">'+esc((o.cp?o.cp[0]+' · ':'')+o.dest)+'</div>';
  e.addEventListener('pointerdown',function(ev){ev.stopPropagation()});e.addEventListener('click',function(){pick(o,true)});var sh=document.createElement('div');sh.className='psh';e._s=sh;pinsEl.appendChild(sh);pinsEl.appendChild(e);pinEls.push(e)});
 me=document.createElement('div');me.className='me';me.innerHTML='<div class="t">'+esc(tx('you'))+'</div><div class="d"></div>';pinsEl.appendChild(me);dirty=true}
''' + s[b:]
rep("var g=e.target.closest('.go'),c=e.target.closest('.card'),seg=e.target.closest('#seg button');",
    "var g=e.target.closest('.go'),c=e.target.closest('.card'),seg=e.target.closest('#seg button');\n if(e.target.closest('#retry')){post2('retry');return}")
rep("setInterval(function(){if(tab===2)return;var L=TABS[tab];[].forEach.call(document.querySelectorAll('.rm'),function(el){var o=L[+el.dataset.i];if(o)el.textContent=(tab===1?'Abierto ':'Acaba ')+'en '+hm(remain(o))})},20000);",
    "setInterval(function(){$('#t_sub').textContent=sub();if(tab===2)return;var L=TABS[tab];[].forEach.call(document.querySelectorAll('.rm'),function(el){var o=L[+el.dataset.i];if(o&&o.end!=null)el.textContent=left(o)})},20000);")

# --- Paseo: sin calles inventadas; el destino sí es real.
rep("function streetName(g,vert){var m=cur;return vert?m.str[(Math.abs(Math.round(g/B))+7)%10]:m.str[(Math.abs(Math.round(g/B))+3)%10]}",
    "function streetName(g,vert){return ''}")
rep("name:last?o.v.split(' ·')[0]:streetName(", "name:last?o.dest:streetName(")
rep("if(r.len<5){toast('Ya estás aquí');return}", "if(r.len<5){toast(tx('here'));return}")
rep("if(w.arrived){l1='Has llegado';l2=w.dest.v.split(' ·')[0]+' · '+(w.dest.cp?w.dest.cp[0]+' '+w.dest.cp[1].toLowerCase():'')}",
    "if(w.arrived){l1=tx('arrived');l2=w.dest.dest+(w.dest.cp?' · '+w.dest.cp[0]:'')}")
rep("l1='Faltan '+min+' min · '+Math.round(rem/5)*5+' m';", "l1=tx('left').replace('{min}',min).replace('{m}',Math.round(rem/5)*5);")
rep("if(Math.abs(cr)<1)rot=0;l2=(rot?'Gira a la '+(rt?'derecha':'izquierda')+' en '+nx.name:'Sigue por '+nx.name)+' · en '+Math.round(toEnd/5)*5+' m'}\n  else l2='Sigue recto por '+sg.name+' · '+Math.round(toEnd/5)*5+' m'}",
    "if(Math.abs(cr)<1)rot=0;l2=(rot?(rt?tx('right'):tx('leftTurn')):tx('straight'))+(nx.name?' · '+nx.name:'')+' · '+tx('inM').replace('{m}',Math.round(toEnd/5)*5)}\n  else l2=tx('straight')+(sg.name?' · '+sg.name:'')+' · '+tx('inM').replace('{m}',Math.round(toEnd/5)*5)}")
rep("""'<div class="wb"><button id="wpp" aria-label="Pausar">'+PAUSE+'<span>Pausa</span></button><button id="wsp" aria-pressed="false" aria-label="Velocidad">x1</button><button class="sx" id="wx">Salir</button></div>';""",
    """'<div class="wb"><button id="wpp">'+PAUSE+'<span>'+esc(tx('pause'))+'</span></button><button id="wsp" aria-pressed="false">x1</button><button id="wmp">'+ROUTE+'<span>'+esc(tx('route'))+'</span></button><button class="sx" id="wx">'+esc(tx('exit'))+'</button></div>';""")
rep("this.innerHTML=(walk.playing?PAUSE+'<span>Pausa</span>':PLAY+'<span>Seguir</span>')};",
    "this.innerHTML=(walk.playing?PAUSE+'<span>'+esc(tx('pause'))+'</span>':PLAY+'<span>'+esc(tx('resume'))+'</span>')};\n"
    " $('#wmp').onclick=function(){if(walk.dest)post2('route:'+walk.dest.id)};")
rep("var PLAY='<svg", "var ROUTE='<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M9 4L3 6v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14\"/></svg>';\nvar PLAY='<svg")
rep("for(var k=1;k<w.segs.length;k++){var pt=w.pts[k],sg=w.segs[k];", "for(var k=1;k<w.segs.length;k++){var pt=w.pts[k],sg=w.segs[k];if(!sg.name)continue;")

# Precio desconocido: al final al ordenar por precio.
rep("a.pr-b.pr})", "(a.pr==null?1e9:a.pr)-(b.pr==null?1e9:b.pr)})")

# --- Arranque: textos, pestaña inicial y botón de volver.
rep("yaw=-.7;pitch=.2;view.s=.28;",
    "function sub(){var n=tx('now').replace('{time}',clock(0));return ECL.place?ECL.place+' · '+n:n}\n"
    "$('#t_title').textContent=tx('title');$('#t_sub').textContent=sub();$('#t_credit').textContent=tx('credit');\n"
    "[].forEach.call(document.querySelectorAll('.tab'),function(b,i){b.textContent=tx(['tabOffers','tabFree','tabPlans'][i])});\n"
    "[['#back','back'],['#zi','zoomIn'],['#zo','zoomOut'],['#t3','tilt'],['#rc','center'],['#ex','expand']].forEach(function(p){$(p[0]).setAttribute('aria-label',tx(p[1]))});\n"
    "$('#back').onclick=function(){post2('back')};\n"
    "tab=ECL.tab|0;[].forEach.call(document.querySelectorAll('.tab'),function(b,i){b.setAttribute('aria-selected',i===tab)});\n"
    "yaw=-.7;pitch=.2;view.s=.28;")

for bad in ('Datos de ejemplo', 'Madrid', 'Farolillo', 'Mapa ilustrativo', "'Ofertas activas'"):
    assert bad not in s, bad
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
