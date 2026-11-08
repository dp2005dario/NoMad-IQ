# Crea assets/plans/planes.html a partir de la maqueta "Elegid planes".
# Uso:
#   python3 tool/planes/build_page.py <Planes.dc.html> <support.js> assets/plans/planes.html
#
# Se queda TODO lo de la maqueta (las caras del grupo, las tarjetas que se
# deslizan con ME APETECE / PASO, el "¡MATCH VIAJERO!" a pantalla entera con
# confeti, "Añadir al plan" y la lista de vuestros match) y solo se quitan
# los planes y nombres de ejemplo y las notas para DARIO. Los planes y los
# votos son los del servidor: la app los pone en la marca /*ECLIPTA*/
# (lib/features/plans/plans_page.dart) y manda lo nuevo con window.ECLin.
import json
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


def element_end(text, start):
    """Dónde acaba el elemento que empieza en [start] (contando etiquetas)."""
    depth = 0
    for m in re.finditer(r'<(/?)([a-zA-Z][\w-]*)[^>]*?(/?)>', text[start:]):
        if m.group(3) == '/' or m.group(2) in ('input', 'br', 'img', 'meta', 'link', 'stop', 'path', 'circle', 'rect', 'ellipse', 'line'):
            continue
        depth += 1 if m.group(1) == '' else -1
        if depth == 0:
            return start + m.end()
    raise AssertionError('sin cierre')


# --- 1. El motor de la maqueta va dentro (sin Internet).
rt_safe = rt.replace('<!--', '\\x3c!--').replace('<script', '\\x3cscript').replace('</script', '\\x3c/script')
rep('<script src="./support.js"></script>',
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
    '<script>window.ECL=/*ECLIPTA*/{};</script>\n'
    '<script>\n'
    'window.toApp=function(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}};\n'
    '// Datos para la app: JSON en base64url (solo letras, números, - y _).\n'
    'window.pack=function(o){var b=btoa(unescape(encodeURIComponent(JSON.stringify(o))));return b.replace(/\\+/g,"-").replace(/\\//g,"_").replace(/=+$/,"")};\n'
    '// La maqueta mide 390 de ancho: se amplía para llenar el ancho del móvil\n'
    '// y se estira a lo alto que tenga la pantalla.\n'
    'function fit(){if(!document.body){document.addEventListener("DOMContentLoaded",fit);return}var z=window.innerWidth/390;document.body.style.zoom=z;var st=document.getElementById("q-fit");if(!st){st=document.createElement("style");st.id="q-fit";document.head.appendChild(st)}st.textContent="#q-root{height:"+Math.round(window.innerHeight/z)+"px!important}"}\n'
    'fit();window.addEventListener("resize",fit);\n'
    '</script>\n'
    '<script>' + rt_safe + '</script>')
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="width: 390px; height: 844px;', '<div id="q-root" style="width: 390px; height: 844px;')

def cut_element(start_text, back_to='<'):
    """Quita el elemento que contiene [start_text] (desde su etiqueta)."""
    global s
    i = s.find(start_text)
    assert i >= 0, start_text
    a = s.rfind(back_to, 0, i)
    s = s[:a] + s[element_end(s, a):]


DATA = re.compile(r"url\('(data:[^']*)'\)")

# --- 2. Volver y vuestro destino.
rep('<a href="Grupo.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')
rep('>Lisboa · derecha: me apetece · izquierda: paso<', '>{{subTitle}}<')

# --- 3. Las tarjetas: foto de verdad (o el dibujo) y sin notas para DARIO.
cut_element('>DIBUJO TEMPORAL · EN LA APP, FOTO REAL</span>', '<span')
rep('Votos en secreto: nadie ve qué has marcado hasta que coincidís. Sitios y nombres son ejemplos.',
    'Votos en secreto: nadie ve qué has marcado hasta que coincidís.')
rep('>Volver a empezar la demo<', '>Volver a empezar<')

# --- 4. La lógica: la de la maqueta con vuestros planes (logic.js). Se
# quedan los dibujos (para los planes sin foto) y los colores del confeti.
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
pre = s[s.rfind('>', 0, s.find('const IMGS')) + 1:a]
keep = []
for line in pre.split('\n'):
    if line.startswith(('const IMGS', 'const CONF', 'const R =', 'const names')):
        keep.append(line)
assert len(keep) == 4, len(keep)
start = s.rfind('>', 0, s.find('const IMGS')) + 1
s = s[:start] + '\n' + '\n'.join(keep) + '\n' + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('</head>'):]
for bad in ('ejemplo', 'demo', 'Lisboa', 'Alfama', 'Marta', 'Álex', 'Noelia', 'DIBUJO TEMPORAL', '.dc.html'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
