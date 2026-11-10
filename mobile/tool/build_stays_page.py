# Crea assets/stays/hoteles.html a partir de la maqueta "Hoteles".
# Uso: python3 tool/build_stays_page.py <maqueta.html> assets/stays/hoteles.html
#
# Se queda TODO lo de la maqueta (chips de monumentos, tarjeta con su dibujo,
# mapa con pines de precio, hoja con el total con tren) y solo se quitan los
# datos de ejemplo y las notas. Lo real lo pone la app
# (lib/features/stays/stays_page.dart) en la marca /*ECLIPTA*/:
#   - las ZONAS para dormir de OpenStreetMap (junto al sitio y estaciones de
#     tren o metro con alojamientos), a su distancia y dirección reales;
#   - los precios: los que TÚ apuntas después de verlos en Booking. La app no
#     se inventa ninguno: sin precio, el pin enseña cuántos alojamientos hay.
#
# OJO (11-11-2026): por la lista de errores de DARIO se cambió el HTML de la
# página directamente en assets/ (no en este script). Si se vuelve a crear
# desde la maqueta, hay que repetir esos cambios: ver `git log` del asset.
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
# --- Cabecera y leyenda: sin "Datos de ejemplo"; textos en tu idioma.
rep('ECLIPTA<small>Hoteles</small></div>\n    <span class="ex">Datos de ejemplo</span>', 'ECLIPTA<small id="t_brand"></small></div>')
rep('<nav class="chips" id="chips" aria-label="Monumento elegido">', '<nav class="chips" id="chips">')
rep('<div class="leg"><span style="color:var(--ink);font-weight:700">Dormir barato</span>\n      <span><i style="background:var(--mint)"></i>Barato</span><span><i style="background:var(--amber)"></i>Medio</span><span><i style="background:var(--red)"></i>Caro</span></div>',
    '<div class="leg"><span style="color:var(--ink);font-weight:700" id="t_leg"></span>\n      <span><i style="background:var(--mint)"></i><b id="t_cheap" style="font-weight:600"></b></span><span><i style="background:var(--amber)"></i><b id="t_mid" style="font-weight:600"></b></span><span><i style="background:var(--red)"></i><b id="t_dear" style="font-weight:600"></b></span></div>')
for old, new in (('<button id="zi" aria-label="Acercar">', '<button id="zi">'),
                 ('<button id="zo" aria-label="Alejar">', '<button id="zo">'),
                 ('<button id="t3" aria-label="Inclinacion 3D" aria-pressed="false">', '<button id="t3" aria-pressed="false">'),
                 ('<button id="rc" aria-label="Centrar en el monumento">', '<button id="rc">'),
                 ('<div class="credit">Mapa ilustrativo generado</div>', '<div class="credit" id="t_credit"></div>'),
                 ('<div class="sheet" id="sheet" role="dialog" aria-label="Detalle del hotel">', '<div class="sheet" id="sheet" role="dialog">')):
    rep(old, new)
# --- Estilos que faltaban: pin sin precio (violeta), casillas para apuntar
# el precio con la misma letra que los números, y el segundo botón.
rep('.pin.sel{z-index:6}',
    '.pin.n .pl{background:linear-gradient(#ded8ff,#a596fa)}\n'
    '.pin.sel{z-index:6}')
rep('.pin.best::before{content:"Mejor total";', '.pin.best::before{content:attr(data-best);')
rep('.cta{', '.st input{display:block;width:100%;min-width:0;margin:0;padding:0 0 1px;background:none;border:0;border-bottom:1px dashed rgba(61,220,151,.6);color:var(--ink);font:700 16px var(--display);font-variant-numeric:tabular-nums;outline:none}\n'
    '.st input::placeholder{color:var(--mint);opacity:.8;font:700 13px var(--body)}\n'
    '.cta2{border:1px solid var(--line);border-radius:14px;padding:10px;text-align:center;font-weight:700;color:var(--ink);background:var(--panel2)}\n'
    '.cta{')
rep('.ttl p{', '.ttl p:empty{display:none}\n.ttl p{')

# --- Escapar todo lo que viene de OpenStreetMap o de lo que apuntas.
rep('function eur(v,d){return v.toLocaleString(\'es-ES\',{minimumFractionDigits:d==null?0:d,maximumFractionDigits:d==null?0:d})+\' €\'}\nfunction km(v){return v.toLocaleString(\'es-ES\',{minimumFractionDigits:1,maximumFractionDigits:1})+\' km\'}',
    'var ECL=/*ECLIPTA*/{"lang":"es","t":{},"chips":[],"cur":0,"zones":[],"nights":3,"msg":"","retry":false,"attr":""};\n'
    'var T=ECL.t||{},LANG=ECL.lang||"es";function tx(k){return T[k]||k}\n'
    "function esc(v){return String(v==null?'':v).replace(/[&<>\"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c]})}\n"
    "function post(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}}\n"
    "function eur(v,d){return v.toLocaleString(LANG,{minimumFractionDigits:d==null?0:d,maximumFractionDigits:d==null?0:d})+' €'}\n"
    "function km(v){return v.toLocaleString(LANG,{minimumFractionDigits:1,maximumFractionDigits:1})+' km'}")

# --- Un dibujo para los sitios que no son uno de los seis monumentos: una
# ciudad de noche con la diana del sitio (mismo estilo que los demás).
rep('var ILL={', '''var ILL={
generic:function(i){var s=sky(i,.5);
 for(var k=0;k<11;k++){var x=k*30-6+H(k,3,1)*8,w=22+H(k,4,1)*12,h=28+H(k,5,1)*58;s+='<rect x="'+x.toFixed(0)+'" y="'+(140-h).toFixed(0)+'" width="'+w.toFixed(0)+'" height="'+h.toFixed(0)+'" fill="url(#st'+i+')" stroke="#e9fff5" stroke-width=".7" opacity="'+(.55+H(k,6,1)*.35).toFixed(2)+'"/>';
  for(var y=140-h+6;y<132;y+=10)for(var c=x+4;c<x+w-5;c+=7)s+='<rect x="'+c.toFixed(0)+'" y="'+y.toFixed(0)+'" width="3" height="4" fill="'+(H(c|0,y|0,k)>.55?'#F5B84B':'#0e2a28')+'" opacity=".8"/>'}
 s+='<circle cx="160" cy="58" r="20" fill="#3DDC97" opacity=".25"/><circle cx="160" cy="58" r="11" fill="#3DDC97"/><path d="M160 69V96" stroke="#e9fff5" stroke-width="2.4"/><circle cx="160" cy="58" r="4" fill="#06281a"/>';
 return s+ground(i)},''')

# --- Los monumentos de ejemplo y sus hoteles inventados -> chips y zonas reales.
cut('/* ---------- datos de ejemplo ---------- */', 'function rail(m,t){', r'''/* ---------- datos reales (los pone la app) ----------
   chips: tu destino, cerca de ti, seis monumentos famosos y "en el mapa".
   zones: zonas para dormir de OpenStreetMap; x/y en metros desde el sitio
   (este y sur), km, minutos estimados y los precios que tú apuntas. */
var LOOK={eiffel:[.17,11,.6,-1100,.62],sagrada:[.72,23,2.1,1500,-.5],coliseo:[-.35,37,4.0,900,.3],bigben:[.05,41,1.2,-700,-.18],brandeburgo:[.4,53,3.1,1300,0],disney:[.28,67,5.2,-1600,.9]};
var MON=(ECL.chips||[]).map(function(c,i){var L=LOOK[c.ill]||[.3,7+i*13,1.4,-900,.4];
 return {id:c.ill,kind:c.kind,name:c.name,short:c.short,city:c.city,h:c.h||'',yr:c.yr||'',ang:L[0],seed:L[1],ph:L[2],ro:L[3],ra:L[4],st:[],str:[]}});
function makeHotels(m){
 var ts=[-6400,-4600,-3100,-1700,-600,600,1900,3300,4800,6400];
 return (ECL.zones||[]).map(function(z,k){var best=0,bd=1e9;ts.forEach(function(tt,q){var pp=rail(m,tt),dd=Math.hypot(pp[0]-z.x,pp[1]-z.y);if(dd<bd){bd=dd;best=q}});
  return {id:k,x:z.x,y:z.y,d:z.km,t0:ts[best],st:z.name||'',stars:3,price:z.night,fare:z.by==='walk'?0:z.fare,min:z.min,by:z.by,n:z.n,budget:z.budget,ex:z.ex||[],
   name:z.name||tx('nearSite')}})}
''')
# Sin nombres de estaciones ni de calles (el mapa es un dibujo).
rep("if(s>.1){ctx.font='700 '+(10.5/s)+'px Manrope,sans-serif';ctx.textAlign='left';", "if(s>.1&&m.st[q]){ctx.font='700 '+(10.5/s)+'px Manrope,sans-serif';ctx.textAlign='left';")
rep("if(s>.5){ctx.font='600 '+(10.5/s)+'px Manrope,sans-serif';", "if(s>.5&&m.str.length){ctx.font='600 '+(10.5/s)+'px Manrope,sans-serif';")
# Zonas hasta 35 km: se puede alejar más; de muy lejos no se dibuja cada manzana.
rep('MINS=.075,', 'MINS=.008,')
rep(' ctx.save();ctx.rotate(a);\n for(var i=i0;i<i1;i++){', ' ctx.save();ctx.rotate(a);\n if(s<.035){ctx.fillStyle=ROOF[2][1];ctx.fillRect(gx0-B,gy0-B,gx1-gx0+2*B,gy1-gy0+2*B);i1=i0}\n for(var i=i0;i<i1;i++){')
rep(" if(s>.3){ctx.strokeStyle='rgba(245,205,120,.5)';", " if(s>.3&&i1>i0){ctx.strokeStyle='rgba(245,205,120,.5)';")
rep("[1,3,5,7].forEach(function(r){", "RINGS.forEach(function(r){")
rep("var tw=34/s;", "var tw=(String(r).length*7+28)/s;")
rep("/* ---------- pines DOM ---------- */", "/* Anillos de 1, 3, 5 y 7 km, y de 15 y 35 si hay zonas tan lejos. */\nvar RINGS=[1,3,5,7];(ECL.zones||[]).forEach(function(z){if(z.km>8&&RINGS.indexOf(15)<0)RINGS.push(15);if(z.km>18&&RINGS.indexOf(35)<0)RINGS.push(35)});\n/* ---------- pines DOM ---------- */")

# --- Pines: el precio que apuntaste o, si aún no, cuántos alojamientos hay.
cut('function tiers(){', 'function total(h){', r'''function priced(){return hotels.filter(function(h){return total(h)!=null})}
function tiers(){var tot=priced().map(total).sort(function(a,b){return a-b});return [tot[Math.floor((tot.length-1)/3)],tot[Math.floor((tot.length-1)*2/3)]]}
function bestOf(){var p=priced();return p.length>1?p.reduce(function(b,h){return total(h)<total(b)?h:b}):null}
function buildPins(){
 pinsEl.innerHTML='';pinEls=[];var t=tiers(),bestH=bestOf();
 hotels.forEach(function(h){var tt=total(h),c=tt==null?'n':tt<=t[0]?'g':tt<=t[1]?'a':'r',e=document.createElement('button');
  e.className='pin '+c+(h===bestH?' best':'')+(h===sel?' sel':'');e._h=h;h.cls=c;e.setAttribute('data-best',tx('best'));e.setAttribute('aria-label',h.name);
  e.innerHTML='<span class="pl"><i></i>'+esc(h.price!=null?eur(h.price):tx('pinCount').replace('{n}',h.n))+'</span>';
  e.addEventListener('pointerdown',function(ev){ev.stopPropagation()});e.addEventListener('click',function(){pick(h,true)});pinsEl.appendChild(e);pinEls.push(e)});
 monPin=document.createElement('div');monPin.className='mpin';
 monPin.innerHTML='<div class="b"><div class="nm">'+esc(cur.name)+'</div><div class="dot"><svg viewBox="0 0 24 24" fill="none" stroke="#06281a" stroke-width="2.4" stroke-linecap="round"><path d="M12 3v18M7 21l5-18 5 18M8.5 14h7"/></svg></div></div>';
 pinsEl.appendChild(monPin)}
''')
# Total = noches × precio + ida y vuelta cada día (como la maqueta). Sin
# precio (o sin billete en una zona de tren), no hay total.
rep('function total(h){return nights*h.price+nights*2*h.fare}',
    'function total(h){if(h.price==null||h.fare==null)return null;return nights*h.price+nights*2*h.fare}')

# --- Tarjeta del monumento y hoja de la zona.
cut('function renderMon(){', 'function refresh(){', r'''function renderMon(){
 var h=sel,tt=h?total(h):null;
 $('#mon').innerHTML='<div class="art"><svg viewBox="0 0 320 150" preserveAspectRatio="xMidYMid slice" role="img" aria-label="'+esc(cur.name)+'">'+(ILL[cur.id]||ILL.generic)((cur.id||'gen').slice(0,3))+'</svg>'+
 '<div class="ttl"><div><h1>'+esc(cur.name)+'</h1><p>'+esc(cur.city)+'</p></div>'+(cur.h||cur.yr?'<div class="facts"><b>'+esc(cur.h)+'</b>'+esc(cur.yr)+'</div>':'')+'</div></div>'+
 '<div class="strip"><div class="hn">'+(ECL.msg?esc(ECL.msg):loading?esc(tx('loading')):h?esc(tx('chosen'))+' <b>'+esc(h.name)+'</b>':esc(hotels.length?tx('tapZone'):tx('none')))+'</div>'+
 (ECL.retry?'<button class="cta" id="retry" style="padding:6px 12px">'+esc(tx('retry'))+'</button>':'')+
 (h&&!loading&&!ECL.msg?'<div class="nv"><span>'+esc(tx('perNight'))+'</span><strong>'+esc(h.price!=null?eur(h.price):tx('noData'))+'</strong></div>'+(tt!=null?'<div class="nv tot"><span>'+esc(tx('nightsTrain').replace('{n}',nights))+'</span><strong>'+esc(eur(tt,0))+'</strong></div>':''):'')+'</div>';
 var r=$('#retry');if(r)r.onclick=function(){post('retry')}}
function val(v){var n=parseFloat(String(v).replace(',','.'));return isFinite(n)&&n>=0&&n<100000?Math.round(n*100)/100:null}
function renderSheet(){
 var h=sel;if(!h)return;var near=hotels.reduce(function(b,x){return x.d<b.d?x:b}),rt=h.fare==null?null:2*h.fare,tt=total(h),tn=total(near);
 var none='<b style="color:var(--mut);font-size:13px">'+esc(tx('noData'))+'</b>';
 $('#sheet').innerHTML='<div class="ph">'+hotelArt(h,h.id+cur.seed)+'<button class="x" id="sx" aria-label="'+esc(tx('close'))+'">&times;</button></div><div class="bd">'+
 '<div><h2>'+esc(h.name)+'</h2><div class="sub"><span>'+esc(tx('lodgings').replace('{n}',h.n).replace('{budget}',h.budget))+'</span><span>'+esc(tx('away').replace('{km}',km(h.d)).replace('{place}',cur.short))+'</span></div></div>'+
 '<div class="stats"><div class="st"><span>'+esc(tx('nightCap'))+'</span><input id="inN" inputmode="decimal" value="'+(h.price!=null?h.price:'')+'" placeholder="'+esc(tx('enter'))+' €"></div>'+
 '<div class="st"><span>'+esc(tx('toMon'))+'</span><b>'+esc(tx('minutes').replace('{n}',h.min))+'</b></div>'+
 '<div class="st"><span>'+esc(tx('round'))+'</span>'+(h.by==='walk'?'<b>'+esc(eur(0))+'</b>':'<input id="inF" inputmode="decimal" value="'+(h.fare!=null?h.fare:'')+'" placeholder="'+esc(tx('enter'))+' €">')+'</div></div>'+
 '<div class="sub" style="margin:0">'+(h.by==='walk'?esc(tx('byWalk').replace('{place}',cur.short)):esc(tx('byTrain').replace('{name}',h.st)))+'</div>'+
 (h.ex.length?'<div class="sub" style="margin:0">'+esc(tx('examples').replace('{list}',h.ex.join(', ')))+'</div>':'')+
 '<div class="bk"><div>'+esc(tx('stay'))+'<span><span class="step"><button id="nm" aria-label="'+esc(tx('less'))+'">&minus;</button><b>'+esc(tx('nightsN').replace('{n}',nights))+'</b><button id="np" aria-label="'+esc(tx('more'))+'">+</button></span> &times; '+(h.price!=null?esc(eur(h.price))+' = <b>'+esc(eur(nights*h.price))+'</b>':none)+'</span></div>'+
 '<div>'+esc(tx('transport'))+'<span>'+esc(tx('daysN').replace('{n}',nights))+' &times; '+(rt!=null?esc(eur(rt,2))+' = <b>'+esc(eur(nights*rt,2))+'</b>':none)+'</span></div><div class="tt">'+esc(tx('total'))+(tt!=null?'<b>'+esc(eur(tt,2))+'</b>':none)+'</div></div>'+
 '<div class="sv"></div>'+
 '<button class="cta" id="bk">'+esc(tx('book'))+'</button><button class="cta2" id="go">'+esc(tx('route'))+'</button>'+(ECL.attr?'<div class="note">'+esc(ECL.attr)+'</div>':'')+'</div>';
 $('#sheet .sv').textContent=tt==null?tx('hint'):h===near?tx('nearest'):tn!=null&&tn-tt>1?tx('save').replace('{money}',eur(tn-tt,0)).replace('{n}',nights).replace('{place}',cur.short):'';
 $('#sx').onclick=function(){$('#sheet').classList.remove('open')};
 $('#nm').onclick=function(){nights=Math.max(1,nights-1);post('nights:'+nights);buildPins();refresh()};$('#np').onclick=function(){nights=Math.min(14,nights+1);post('nights:'+nights);buildPins();refresh()};
 $('#inN').onchange=function(){h.price=val(this.value);post('night:'+h.id+':'+(h.price==null?0:Math.round(h.price*100)));buildPins();refresh()};
 var f=$('#inF');if(f)f.onchange=function(){h.fare=val(this.value);post('fare:'+h.id+':'+(h.fare==null?0:Math.round(h.fare*100)));buildPins();refresh()};
 $('#bk').onclick=function(){post('book:'+h.id)};
 $('#go').onclick=function(){$('#sheet').classList.remove('open');fitRoute(h)}}
''')
rep("function pick(h,open){sel=h;", "function pick(h,open){if(!h)return;sel=h;")
cut('function fitAll(){', 'function load(i){', r'''function fitAll(){if(!hotels.length){goal={x:0,y:0,s:.45};return}var md=0;hotels.forEach(function(h){if(h.d<=7)md=Math.max(md,h.d)});/* de entrada, lo de hasta 7 km; lo más lejos, alejando */
 var sx=hotels.reduce(function(a,h){return a+h.x},0)/hotels.length,sy=hotels.reduce(function(a,h){return a+h.y},0)/hotels.length,s=Math.min(CW,CH)/K*.46/(Math.max(md,.6)*1000*1.05);goal={x:sx*.6,y:sy*.6,s:Math.min(MAXS,Math.max(MINS,s))}}
''')
# Cambiar de chip: "en el mapa" abre el selector de la app; otro sitio pide
# sus zonas a la app (que vuelve a abrir la página con ellas).
cut('function load(i){', "(function(){var ci=", r'''var loading=false;
function load(i){
 var m=MON[i];if(!m)return;
 if(m.kind==='map'){post('map');return}
 if(i!==(ECL.cur|0)){loading=true;ECL.msg='';ECL.retry=false;hotels=[];sel=null;cur=m;
  [].forEach.call(document.querySelectorAll('.chip'),function(c,k){c.setAttribute('aria-pressed',k===i)});
  buildPins();renderMon();$('#sheet').classList.remove('open');view.x=0;view.y=0;goal={x:0,y:0,s:.45};dirty=true;post('chip:'+i);return}
 cur=m;hotels=makeHotels(cur);sel=null;
 [].forEach.call(document.querySelectorAll('.chip'),function(c,k){c.setAttribute('aria-pressed',k===i)});
 buildPins();
 var best=bestOf()||hotels.reduce(function(b,h){return !b||h.d<b.d?h:b},null);
 if(best)pick(best,false);else renderMon();$('#sheet').classList.remove('open');
 view.x=0;view.y=0;view.s=.12;fitAll();dirty=true}
''')
rep("(function(){var ci={eiffel:", "(function(){var ci={here:'M12 2v4M12 18v4M2 12h4M18 12h4M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z',target:'M12 22s7-6.5 7-12a7 7 0 0 0-14 0c0 5.5 7 12 7 12zM12 12.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z',map:'M9 4L3 6v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14',eiffel:")
rep("<path d=\"'+ci[m.id]+'\"/></svg>'+m.short+'</button>'", "<path d=\"'+(ci[m.id]||ci[m.kind]||ci.target)+'\"/></svg>'+esc(m.short)+'</button>'")
rep("$('#t3').onclick=", "$('#t3').onclick=")
# --- Arranque: textos y el sitio elegido.
rep("resize();load(5);requestAnimationFrame(frame);",
    "$('#t_brand').textContent=tx('title');$('#t_leg').textContent=tx('legend');$('#t_cheap').textContent=tx('cheap');$('#t_mid').textContent=tx('mid');$('#t_dear').textContent=tx('dear');$('#t_credit').textContent=tx('credit');\n"
    "[['#zi','zoomIn'],['#zo','zoomOut'],['#t3','tilt'],['#rc','center']].forEach(function(p){$(p[0]).setAttribute('aria-label',tx(p[1]))});\n"
    "nights=ECL.nights||3;\n"
    "resize();load(ECL.cur|0);requestAnimationFrame(frame);\n"
    "/* El chip elegido, a la vista. */\nvar pc=document.querySelector('.chip[aria-pressed=true]');if(pc&&pc.scrollIntoView)pc.scrollIntoView({inline:'center',block:'nearest'});")

for bad in ('Datos de ejemplo', 'Torre Eiffel', 'Hôtel', 'Mapa ilustrativo', 'Ver trayecto'):
    assert bad not in s, bad
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
