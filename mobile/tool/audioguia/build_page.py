# Crea assets/audioguide/audioguia.html a partir de la maqueta "Audioguía".
# Uso:
#   python3 tool/audioguia/build_page.py <Audioguia.dc.html> <support.js> assets/audioguide/audioguia.html
#
# Se queda TODO lo de la maqueta (Flyra "HABLANDO", la foto que se mueve,
# las ondas que se arrastran para rebobinar, el círculo verde que se
# desliza, los subtítulos que se iluminan, "¿Sabías que…?", tu recorrido
# con Flyra andando y las partes). Se quitan los dibujos y textos de
# ejemplo (Puerta del Sol) y las notas para DARIO. El audio lo pone la app
# (guide_player.dart): la página le dice qué tocar y la app le manda por
# dónde va (lib/features/audioguide/audioguide_page.dart).
import os
import re
import sys

src, runtime, dst = sys.argv[1], sys.argv[2], sys.argv[3]
here = os.path.dirname(os.path.abspath(__file__))
s = open(src, encoding='utf-8').read()
rt = open(runtime, encoding='utf-8').read()


def rep(old, new, count=1):
    """Cambia [old] por [new] y comprueba que estaba (si no, la maqueta cambió)."""
    global s
    assert s.count(old) == count, (s.count(old), old[:120])
    s = s.replace(old, new)


# --- 1. El motor de la maqueta va dentro (sin Internet).
rt_safe = rt.replace('<!--', '\\x3c!--').replace('<script', '\\x3cscript').replace('</script', '\\x3c/script')
# El motor busca la primera "<x-dc>" del texto de la página: la de su propio
# mensaje de error no puede contar.
assert rt_safe.count('has no <x-dc> block') == 1
rt_safe = rt_safe.replace('has no <x-dc> block', 'has no \\x3cx-dc> block')
rep('<script src="./support.js"></script>',
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
    '<script>window.ECL=/*ECLIPTA*/{};</script>\n'
    '<script>\n'
    'window.toApp=function(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}};\n'
    '// La maqueta mide 390 de ancho: se amplía para llenar el ancho del móvil\n'
    '// y se estira a lo alto que tenga la pantalla.\n'
    'function fit(){if(!document.body){document.addEventListener("DOMContentLoaded",fit);return}var z=window.innerWidth/390;document.body.style.zoom=z;var st=document.getElementById("q-fit");if(!st){st=document.createElement("style");st.id="q-fit";document.head.appendChild(st)}st.textContent="#q-root{height:"+Math.round(window.innerHeight/z)+"px!important}"}\n'
    'fit();window.addEventListener("resize",fit);\n'
    '</script>\n'
    '<script>' + rt_safe + '</script>')
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div class="{{rootCls}}" style="position: relative; overflow: hidden; width: 390px; height: 844px;',
    '<div id="q-root" class="{{rootCls}}" style="position: relative; overflow: hidden; width: 390px; height: 844px;')

# --- 2. Arriba: volver, el idioma, la velocidad y descargar.
rep('<a href="Mapa.dc.html" aria-label="Volver al mapa" style="', '<a onClick="{{back}}" aria-label="Volver al mapa" style="cursor: pointer; ')
rep('padding: 0 12px">ES</span>', 'padding: 0 12px">{{langLbl}}</span>')

# --- 3. La foto: la de verdad del sitio más conocido (Wikimedia Commons),
# en vez de los 4 dibujos de ejemplo. Sin foto, un fondo oscuro.
a = s.find('<div style="{{s0}}">')
b = s.find('<div style="position: absolute; left: 0; right: 0; bottom: 0; height: 80px;', a)
assert a > 0 and b > a
s = s[:a] + ('<sc-if value="{{hasPhoto}}" hint-placeholder-val="{{ true }}"><img src="{{photo}}" alt="" onClick="{{openPhoto}}" style="position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; cursor: pointer; animation: nq-kb 7s ease-in-out infinite alternate"></sc-if>'
             '<sc-if value="{{noPhoto}}" hint-placeholder-val="{{ false }}"><div style="position: absolute; inset: 0; background: radial-gradient(120% 90% at 30% 20%, #1F5A43 0%, #13342A 45%, #0F1A20 100%); animation: nq-kb 7s ease-in-out infinite alternate"></div></sc-if>\n') + s[b:]
i = s.find('Dibujo temporal · foto real en la app</span>')
a = s.rfind('<span style="position: absolute; right: 12px; top: 60px;', 0, i)
s = s[:a] + s[i + len('Dibujo temporal · foto real en la app</span>'):]
rep('>Foto: autor · licencia · Wikimedia</span>', ' onClick="{{openPhoto}}">{{credit}}</span>')
rep('<span style="font-size: 9.5px; color: #9FB0B8" onClick', '<span style="font-size: 9.5px; color: #9FB0B8; cursor: pointer" onClick')

# --- 4. El nombre de la zona y la parte que suena.
rep('line-height: 1">Puerta del Sol</div>', 'line-height: 1">{{zone}}</div>')
rep('>Parte {{currentN}} de 4 · {{currentTitle}}</div>', '>Parte {{currentN}} de {{nParts}} · {{currentTitle}}</div>')

# --- 5. "Ver el texto": el guion entero (lo enseña la app).
rep('<button type="button" aria-label="Ver el texto" style="', '<button type="button" onClick="{{text}}" aria-label="Ver el texto" style="')

# --- 6. Tu recorrido y las partes: tantas como tenga la audioguía.
rep('>4 paradas · {{routeLeft}}</span>', '>{{routeHead}}</span>')
rep('<div style="display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 6px">', '<div style="{{partsGrid}}">')

rep('<span style="font-size: 11px; color: #6F8490; line-height: 1.4">Ilustraciones de respaldo. Curiosidades y textos de ejemplo.</span>', '')

# --- 7. El aviso de Flyra de abajo: lo que diga la app.
rep('>Audioguía descargada</span>', '>{{alertT}}</span>')
rep('>Las 4 partes, los subtítulos y el recorrido funcionan sin conexión.</span>', '>{{alertS}}</span>')

# --- 8. La lógica: la de la maqueta con tu audioguía (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
s = s[:a] + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Puerta del Sol', 'Kilómetro', 'Madroño', 'Dibujo temporal', '.dc.html'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
