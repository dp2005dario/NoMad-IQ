# Crea assets/events/eventos.html a partir de la maqueta "Qué pasa en tus
# fechas".
# Uso:
#   python3 tool/eventos/build_page.py <Eventos.dc.html> <support.js> assets/events/eventos.html
#
# Se queda TODO lo de la maqueta (los días, las categorías, las tarjetas con
# cuenta atrás, el corazón, "+ Planes", el mapa con los pines y el consejo de
# Flyra) y solo se quitan los eventos de ejemplo y las notas para DARIO. Los
# eventos son los del servidor: la app los pone en la marca /*ECLIPTA*/
# (lib/features/events/events_page.dart) y manda lo nuevo con window.ECLin.
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
rep('<div class="ev-root" style="width: 390px; height: 844px;', '<div id="q-root" class="ev-root" style="width: 390px; height: 844px;')

def cut_element(start_text, back_to='<'):
    """Quita el elemento que contiene [start_text] (desde su etiqueta)."""
    global s
    i = s.find(start_text)
    assert i >= 0, start_text
    a = s.rfind(back_to, 0, i)
    s = s[:a] + s[element_end(s, a):]



# --- 2. Arriba: volver y vuestra ciudad y fechas (tocándolas, se cambian).
rep('<a href="Explorar.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')
rep('<span style="font-size: 12px; color: #9FB0B8">Lisboa · 10-13 de junio · cerca de tu hotel</span>',
    '<span onClick="{{options}}" style="font-size: 12px; color: #9FB0B8; cursor: pointer">{{subTitle}}</span>')
i = s.find('TICKETMASTER</span>')
a = s.rfind('<span style="height: 24px;', 0, i)
s = s[:a] + '<span style="height: 24px;' + s[a + len('<span style="height: 24px;'):i].replace('padding: 0 9px"', 'padding: 0 9px; {{srcSt}}"', 1) + '{{srcTxt}}</span>' + s[i + len('TICKETMASTER</span>'):]

# --- 3. Las tarjetas: "Entradas" abre Ticketmaster (o "Ver plan").
rep('<a href="{{e.href}}" style="{{e.btn}}">', '<a onClick="{{e.go}}" style="{{e.btn}}">')
rep('>Ese día no hay nada de este tipo. Prueba con otro día o con «Todo».</div>', '>{{emptyTxt}}</div>')

# --- 4. El mapa: los pines en su sitio (según Ticketmaster) y tu hotel en
# el centro. Tocando el mapa, marcas tu hotel.
rep('alt="Mapa de la zona" style="', 'alt="Mapa de la zona" onClick="{{setHotel}}" style="cursor: pointer; ')
rep('<span style="position: absolute; left: 50%; top: 55%; width: 16px; height: 16px; margin: -8px; border-radius: 8px; background: #6CA8FF;',
    '<span style="{{hotelSt}}; position: absolute; left: 50%; top: 55%; width: 16px; height: 16px; margin: -8px; border-radius: 8px; background: #6CA8FF;')
rep('<span style="position: absolute; left: 50%; top: 55%; width: 16px; height: 16px; margin: -8px; border-radius: 8px; border: 2px solid #6CA8FF;',
    '<span style="{{hotelSt}}; position: absolute; left: 50%; top: 55%; width: 16px; height: 16px; margin: -8px; border-radius: 8px; border: 2px solid #6CA8FF;')
rep('>Toca un pin para ver su evento. Mapa de ejemplo con el mismo estilo que Cajeros y Cerca de ti.</span>', '>{{mapNote}}</span>')
rep('<a href="Planes.dc.html" style="', '<a onClick="{{vote}}" style="cursor: pointer; ')
cut_element('>Eventos, horas y precios de esta maqueta son ejemplos.', '<span')

# --- 5. La lógica: la de la maqueta con vuestros eventos (logic.js). Se
# quedan los dibujos, las categorías y la cuenta atrás.
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
start = s.rfind('>', 0, s.find('const ICO')) + 1
pre = s[start:a]
keep = []
for line in pre.split('\n'):
    if line.startswith(('const ICO', 'const CATS', 'const R =', 'const pad', 'const cdTxt')):
        keep.append(line)
assert len(keep) == 5, len(keep)
s = s[:start] + '\n' + '\n'.join(keep) + '\n' + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Lisboa', 'Alfama', 'Santo António', 'LX Factory', '.dc.html', 'TICKETMASTER<'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
