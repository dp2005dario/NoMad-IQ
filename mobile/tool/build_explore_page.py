# Crea assets/explore/explorar.html a partir de la maqueta "Explorar".
# Uso: python3 tool/build_explore_page.py <maqueta.html> assets/explore/explorar.html
# Quita los datos de ejemplo y las notas; los textos y el clima real los pone
# la app (lib/features/flights/explore_screen.dart) en la marca /*ECLIPTA*/.
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
# Solo la página (sin el envoltorio del visor de artefactos).
a = s.find('<title>')
head = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
s = head + s[a:]
def rep(old, new, count=1):
    global s
    assert s.count(old) >= 1, old[:80]
    s = s.replace(old, new, count)
rep('<span class="tag">Datos de ejemplo</span>', '')
rep('<div><div class="brand">ECLIPTA</div><h1>Explorar</h1></div>', '<div><div class="brand">ECLIPTA</div><h1 id="t_title"></h1></div>')
rep('<p class="sub">Elige un mes y mira cuándo conviene viajar a cada país del mundo.</p>', '<p class="sub" id="t_sub"></p>')
rep('<button id="vmap" aria-pressed="false">Mapa</button><button id="vglobe" aria-pressed="true">Globo</button><button id="vcl" aria-pressed="true" aria-label="Nubes">Nubes</button>',
    '<button id="vmap" aria-pressed="false"></button><button id="vglobe" aria-pressed="true"></button><button id="vcl" aria-pressed="true"></button>')
rep('<div class="load" id="load">Generando relieve&hellip;</div>', '<div class="load" id="load"></div>')
rep('<span class="hint" id="hint">Arrastra en cualquier dirección · pellizca para zoom</span>', '<span class="hint" id="hint"></span>')
rep('<button id="zi" aria-label="Acercar">+</button><button id="zo" aria-label="Alejar">&minus;</button><button id="zr" aria-label="Ver todo el mundo" style="font-size:13px">&#8634;</button>',
    '<button id="zi">+</button><button id="zo">&minus;</button><button id="zr" style="font-size:13px">&#8634;</button>')
rep('<div class="lab"><span>Evitar</span><b id="legm">Octubre</b><span>Mejor época</span></div>', '<div class="lab"><span id="t_avoid"></span><b id="legm"></b><span id="t_best"></span></div>')
rep('<p class="src">Relieve: NASA Blue Marble (imagen real, vía three-globe, MIT). El tinte de color y las estadísticas son datos de ejemplo.</p>', '<p class="src" id="t_src"></p>')
rep('<h2>Mejor ahora mismo</h2>', '<h2 id="t_top"></h2>')
rep('<h2>Todos los países</h2>', '<h2 id="t_all"></h2>')
rep('<input type="search" id="q" placeholder="Buscar país" autocomplete="off" aria-label="Buscar país">', '<input type="search" id="q" autocomplete="off">')
rep('<p class="note">Todas las puntuaciones, temperaturas, precios y niveles son datos de ejemplo generados para la maqueta. No son cifras reales.</p>\n', '')
# Datos reales: los pone la app en lugar de la marca.
rep('(function(){\n"use strict";', '(function(){\n"use strict";\nvar ECL=/*ECLIPTA*/{"lang":"es","t":{},"climate":{}};\nvar T=ECL.t,REAL=ECL.climate||{},LANG=ECL.lang||"es";\nfunction tx(k){return T[k]||k}')
rep('var MES=["Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"];', 'var MES=[],MESL=[];(function(){for(var m=0;m<12;m++){var d=new Date(2026,m,15);var sh=d.toLocaleString(LANG,{month:"short"}).replace(".","");if(LANG.slice(0,2)==="es")sh=sh.slice(0,3);MES.push(sh.charAt(0).toUpperCase()+sh.slice(1));var lg=d.toLocaleString(LANG,{month:"long"});MESL.push(lg.charAt(0).toUpperCase()+lg.slice(1))}})();')
rep('var MESL=["Enero","Febrero","Marzo","Abril","May","Junio","Julio","Agosto","Septiembre","Octubre","Noviembre","Diciembre"];', '') if 'var MESL=["Enero","Febrero","Marzo","Abril","May"' in s else None
import re
s = re.sub(r'var MESL=\["Enero"[^\]]*\];', '', s, count=1)
rep('var cur=9, sel=-1;', 'var cur=new Date().getMonth(), sel=-1;')
# Nombres de países en el idioma del móvil (si el sistema los sabe).
rep('var FU={};', 'var DN=null;try{DN=new Intl.DisplayNames([LANG],{type:"region"})}catch(e){}\nfunction cname(iso,fb){if(LANG!=="es"&&DN){try{var n=DN.of(iso);if(n&&n!==iso)return n}catch(e){}}return NAMES[iso]||fb}\nvar FU={};')
# El bloque de datos de ejemplo -> clima real (NASA POWER) y el resto "sin datos".
a = s.find('/* Datos de ejemplo coherentes')
b = s.find('function lvTour')
b2 = s.find('var LVT=')
s = s[:a] + '''/* Clima real (NASA POWER, medias de 30 años) de cada país: temperatura y
   lluvia de cada mes. La puntuación sale de ahí (22 °C y poca lluvia = 100). */
var C=GEO.map(function(g,i){
  var iso=g[0],d=REAL[iso],t=[],r=[],s=[];
  for(var m=0;m<12;m++){
    if(d&&d[m]){var T0=d[m][0],R0=d[m][1];t.push(T0);r.push(R0);
      var raw=0.62*Math.exp(-Math.pow((T0-22)/9,2))+0.38*Math.exp(-R0/120);
      s.push(clamp(Math.round((raw-0.12)/0.78*100),2,99))}
    else{t.push(null);r.push(null);s.push(null)}}
  return {i:i,iso:iso,name:cname(iso,g[1]),lat:g[2],lon:g[3],d:g[4],t:t,r:r,s:s,has:!!d};
});
''' + s[b2:]
# Sin dato: gris; al ordenar, al final.
rep('function col(sc){', 'function col(sc){if(sc===null||sc===undefined)return "rgb(84,99,108)";')
rep('var order=C.slice().sort(function(a,b){return b.s[cur]-a.s[cur]||a.name.localeCompare(b.name,"es")});',
    'var order=C.slice().sort(function(a,b){var x=a.s[cur],y=b.s[cur];if(x===null&&y!==null)return 1;if(y===null&&x!==null)return -1;return (y||0)-(x||0)||a.name.localeCompare(b.name,LANG)});')
rep('topIdx=order.slice(0,8).map(function(c){return c.i});', 'var withData=order.filter(function(c){return c.has});topIdx=withData.slice(0,8).map(function(c){return c.i});')
rep('b.querySelector(".tp").textContent=Math.round(c.t[cur])+"°";var e=b.querySelector(".sc");e.textContent=s;',
    'b.querySelector(".tp").textContent=c.has?Math.round(c.t[cur])+"°":"";var e=b.querySelector(".sc");e.textContent=c.has?s:"—";')
rep('order.slice(0,8).forEach(function(c){', 'withData.slice(0,8).forEach(function(c){')
rep('$("cnt").textContent=n+" de "+C.length}', '$("cnt").textContent=tx("count").replace("{n}",n).replace("{total}",C.length)}')
# Hoja de un país.
a = s.find('function renderSheet(){')
b = s.find('/* ---- Tierra realista')
s = s[:a] + r'''function renderSheet(){var c=C[sel],s=c.s[cur],k=col(s);
  var circ=2*Math.PI*30,cols="",cl="",best=-1;
  c.s.forEach(function(v,m){if(v!==null&&(best<0||v>c.s[best]))best=m});
  c.s.forEach(function(v,m){cols+='<div class="'+(m===cur?"cur":"")+'" style="height:'+Math.max(6,(v||0)*0.64)+'px;background:'+col(v)+'"></div>';cl+="<span>"+MES[m].charAt(0)+"</span>"});
  var none='<div class="v" style="font-size:18px;color:var(--muted)">'+tx("noData")+'</div>';
  var verdict=!c.has?tx("noData"):s>=70?tx("vGreat"):s>=50?tx("vGood"):s>=30?tx("vFair"):tx("vAvoid");
  sh.innerHTML='<div class="grab"></div><div class="sh-top"><div><div style="display:flex;align-items:center;gap:12px"><span id="shf" style="flex:none"></span><h3 id="shn"></h3></div></div><button class="x" id="sx" aria-label="'+tx("close")+'">&#10005;</button></div>'+
  '<div class="verdict"><div class="ring"><svg viewBox="0 0 72 72"><circle cx="36" cy="36" r="30" fill="none" stroke="#22343f" stroke-width="7"/><circle cx="36" cy="36" r="30" fill="none" stroke="'+k+'" stroke-width="7" stroke-linecap="round" stroke-dasharray="'+(circ*(s||0)/100)+' '+circ+'"/></svg><b>'+(c.has?s:"—")+'</b></div>'+
  '<div><strong>'+verdict+'</strong><p>'+(c.has?tx("bestMonth").replace("{month}",MESL[cur]).replace("{best}",MESL[best].toLowerCase()):MESL[cur])+'</p></div></div>'+
  '<div class="grid">'+
  '<div class="st"><div class="k">'+tx("temp")+'</div>'+(c.has?'<div class="v">'+Math.round(c.t[cur])+'°C</div>':none)+'</div>'+
  '<div class="st"><div class="k">'+tx("rain")+'</div>'+(c.has?'<div class="v">'+Math.round(c.r[cur])+'<small>mm</small></div>':none)+'</div>'+
  '<div class="st"><div class="k">'+tx("tourists")+'</div>'+none+'</div>'+
  '<div class="st"><div class="k">'+tx("cost")+'</div>'+none+'</div>'+
  '<div class="st" style="grid-column:1/-1"><div class="k">'+tx("safety")+'</div>'+none+'</div></div>'+
  '<div class="yr"><div class="k">'+tx("year")+'</div><div class="cols">'+cols+'</div><div class="cl">'+cl+'</div></div>';
  $("shn").textContent=c.name;$("shf").appendChild(flag(c.iso,"big"));glabel.innerHTML="";glabel.appendChild(flag(c.iso));var gs=document.createElement("span");gs.textContent=c.name;glabel.appendChild(gs);$("sx").onclick=closeSheet}
''' + s[b:]
rep('$("hint").textContent=g?"Arrastra en cualquier dirección · pellizca para zoom":"Arrastra y pellizca para acercar";', '$("hint").textContent=g?tx("hintGlobe"):tx("hintMap");')
rep('catch(err){$("load").textContent="No se pudo generar el relieve"}', 'catch(err){$("load").textContent=tx("loadFail")}')
rep('.catch(function(){$("load").textContent="No se pudo cargar la textura"});', '.catch(function(){$("load").textContent=tx("loadFail")});')
rep('$("hidet").textContent=folded?"Mostrar":"Ocultar";', '$("hidet").textContent=folded?tx("show"):tx("hide");')
# Textos fijos al arrancar.
rep('\npaint();\ninitEarth();', '''
$("t_title").textContent=tx("title");$("t_sub").textContent=tx("sub");$("vmap").textContent=tx("map");$("vglobe").textContent=tx("globe");
$("vcl").textContent=tx("clouds");$("load").textContent=tx("loading");$("hint").textContent=tx("hintGlobe");$("t_avoid").textContent=tx("avoid");
$("t_best").textContent=tx("bestTime");$("t_src").textContent=tx("source");$("t_top").textContent=tx("topNow");$("t_all").textContent=tx("allCountries");
$("q").placeholder=tx("search");$("q").setAttribute("aria-label",tx("search"));$("zi").setAttribute("aria-label",tx("zoomIn"));$("zo").setAttribute("aria-label",tx("zoomOut"));$("zr").setAttribute("aria-label",tx("zoomAll"));
paint();
initEarth();''')
# Las fuentes de Google necesitan Internet: si no hay, las del sistema.
open(dst, 'w', encoding='utf-8').write(s)
print(len(s))
