# Crea assets/trip/antes.html a partir de la maqueta "Antes de salir".
# Uso:
#   python3 tool/antes/build_page.py <Antes.dc.html> <support.js> assets/trip/antes.html
#
# Se queda TODO lo de la maqueta (el anillo de "% listo", el dibujo de
# arriba con pétalos, las tarjetas que se dan la vuelta, los consejos de
# Flyra, la maleta con su explosión de colores, datos móviles y seguro, y
# los reels con su hoja de abajo). Solo se quitan los datos de ejemplo
# (Japón, Tokio, los vídeos inventados) y las notas para DARIO. Los datos
# los pone la app en la marca /*ECLIPTA*/ (lib/features/trip/before_page.dart)
# y manda lo nuevo con window.ECLin.
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
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(')

# --- 2. Arriba: volver, y tu viaje (tocándolo, se cambia).
rep('<a href="Inicio.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')
rep('<span style="font-size: 12px; color: #9FB0B8">Japón · Tokio · sales en 9 días</span>',
    '<span onClick="{{options}}" style="font-size: 12px; color: #9FB0B8; cursor: pointer">{{subTitle}}</span>')

# --- 3. El dibujo: el arco japonés solo si vas a Japón.
rep('<path d="M300 150 V96 h40 V150 M292 96 h56 M296 104 h48" stroke="#C0392B"',
    '<path style="{{toriiSt}}" d="M300 150 V96 h40 V150 M292 96 h56 M296 104 h48" stroke="#C0392B"')
rep('>JAPÓN EN 30 SEGUNDOS</span>', '>{{heroK}}</span>')

# --- 4. Las tarjetas del país (solo las que tienen dato de verdad).
rep('>Lo importante de Japón</span>', '>{{factsH}}</span>')
rep('<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px">\n<sc-for list="{{facts}}"',
    '<sc-if value="{{noFacts}}" hint-placeholder-val="{{ false }}"><span onClick="{{options}}" style="font-size: 13px; line-height: 1.45; color: #9FB0B8; cursor: pointer">{{emptyTxt}}</span></sc-if>\n'
    '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px">\n<sc-for list="{{facts}}"')

# --- 5. Flyra: tocando el consejo, vas a la pantalla de donde sale.
rep('>Consejos de Flyra para Japón</span>', '>{{tipsH}}</span>')
rep('<div style="{{tipSt}}">', '<div onClick="{{openTip}}" style="{{tipSt}}">')

# --- 6. Datos móviles y seguro.
rep('>eSIM de un socio · se activa al aterrizar</span>', '>{{esimSub}}</span>')
rep('>Guardado en tu Bóveda</span>', '>{{insSub}}</span>')

# --- 7. Reels: búsquedas de verdad en cada red (sin vídeos inventados). En
# vez de la miniatura dibujada, un fondo con el color de la red.
rep('>Reels de Japón</span>', '>{{reelsH}}</span>')
rep('<img src="{{r.img}}" alt="" style="position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; animation: an-kb 9s ease-in-out infinite alternate">',
    '<span style="{{r.bg}}"></span>')
rep('<img src="{{sImg}}" alt="" style="width: 64px; height: 112px; border-radius: 12px; object-fit: cover; flex-shrink: 0">',
    '<span onClick="{{watch}}" style="{{sBg}}"><svg width="22" height="22" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z" fill="#FFFFFF"></path></svg></span>')
i = s.find('Miniaturas dibujadas de ejemplo.')
a = s.rfind('<span', 0, i)
b = s.find('</span>', i) + len('</span>')
s = s[:a] + s[b:]
rep('<button type="button" onClick="{{saveReel}}"',
    '<button type="button" onClick="{{watch}}" style="{{watchSt}}">{{watchTxt}}</button>\n<button type="button" onClick="{{saveReel}}"')

# --- 8. La lógica: la de la maqueta con tus datos (logic.js). Se quedan los
# dibujos de los iconos (D.IC) y la Flyra; se van las miniaturas de ejemplo.
a = s.find('const D = {')
b = s.find('</script>', a)
d = s[a:s.find('\n', a)]
d = re.sub(r', "RL": \[[^\]]*\]', '', d)
assert '"RL"' not in d
s = s[:a] + d + '\n' + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Tokio', 'Japón', '.dc.html', 'konbini'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
