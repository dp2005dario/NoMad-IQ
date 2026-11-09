# Crea assets/money/dinero.html a partir de la maqueta "Tu dinero fuera".
# Uso:
#   python3 tool/dinero/build_page.py <Dinero.dc.html> <support.js> assets/money/dinero.html
#
# Se queda TODO lo de la maqueta (el mapa con los cajeros, la lista, el
# aviso de «cobrar en euros», tu viaje con el anillo de lo que llevas, las
# barras por día, Flyra, tus últimos gastos, «Añadir a mano», los tipos de
# gasto y «¿Y si a partir de hoy…?») y solo se quitan los datos de ejemplo,
# la etiqueta EJEMPLO, el botón de probar el aviso y la nota para DARIO. Lo
# de verdad lo pone la app (lib/features/money/abroad_page.dart) en la marca
# /*ECLIPTA*/ y lo que llega después entra con window.ECLin({...}).
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

# --- 2. Volver y las pestañas.
rep('<a href="Gastos.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')

# --- 3. Cajeros: el mapa con los de verdad (en su sitio respecto a ti).
rep('<a href="https://claude.ai/artifact/Pbk9pXDbPMyV6r54LY2zkt" target="_blank" rel="noopener" style="',
    '<a onClick="{{map3d}}" style="cursor: pointer; ')
a = s.find('<span style="position: absolute; left: 35px; top: 41px;')
b = s.find('<span style="position: absolute; left: 10px; top: 10px; height: 26px;')
assert 0 < a < b
s = (s[:a] + '<sc-for list="{{pins}}" as="p" hint-placeholder-count="6"><span style="{{p.wrap}}">'
     '<span style="{{p.dot}}">{{p.short}}</span><span style="{{p.chip}}">{{p.fee}}</span></span></sc-for>' + s[b:])
rep('<b style="color: #3DDC97">6</b> cajeros a menos de 1 km', '<b style="color: #3DDC97">{{atmCount}}</b> cajeros a menos de 1 km')
# Sin ubicación o sin datos: se dice (y se puede volver a buscar).
rep('<div style="display: flex; flex-direction: column; gap: 8px"><sc-for list="{{atms}}"',
    '<sc-if value="{{hasAtmNote}}" hint-placeholder-val="{{ false }}"><div style="display: flex; flex-direction: column; gap: 10px; border-radius: 20px; background: #141E25; border: 1px solid #26363F; padding: 14px; font-size: 13px; line-height: 1.45; color: #DCE5E9">{{atmNote}}'
    '<sc-if value="{{hasAtmBtn}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{locate}}" style="align-self: flex-start; height: 40px; border-radius: 14px; border: none; padding: 0 16px; background: linear-gradient(135deg, #FFD08A, #FFB86B); color: #1A1206; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer">{{atmBtn}}</button></sc-if></div></sc-if>'
    '<div style="display: flex; flex-direction: column; gap: 8px"><sc-for list="{{atms}}"')

# --- 4. Gastos: tu viaje (o por qué no hay).
rep('>TUS VIAJES · EJEMPLO<', '>TUS VIAJES<')
a = s.find('<button type="button" onClick="{{tripJp}}" style="{{tripJpStyle}}">')
s = (s[:a] + '<sc-for list="{{trips}}" as="v" hint-placeholder-count="1"><button type="button" onClick="{{v.pick}}" style="{{v.style}}">'
     '<span style="font-size: 13px; font-weight: 800">{{v.title}}</span><span style="font-size: 11px; color: #9FB0B8">{{v.sub}}</span></button></sc-for>'
     + s[element_end(s, a):])
rep('>Para ver qué pasa si no tienes ninguno<', '>Dejar de contar gastos de un viaje<')
rep('>Para contar tus gastos necesito saber adónde vas y cuándo. Los saco de tu vuelo o tu reserva, o los pones tú.<', '>{{noTripTxt}}<')
rep('<button type="button" onClick="{{tripJp}}" style="height: 44px;', '<button type="button" onClick="{{tripNew}}" style="height: 44px;')
rep('>JAPÓN · DÍA 4 DE 9 · YENES (JPY) EN EUROS</span>', '>{{ringHead}}</span>')
cut_element('>EJEMPLO</span>', '<span')
rep('>de 1.400 €<', '>{{limitTxt}}<')
rep('color: #3DDC97">122 €</span>', 'color: #3DDC97">{{perDayTxt}}</span>')

# --- 5. Últimos gastos: los tuyos. Las 4 fotos de ejemplo se quedan como
# foto de su tipo (comida, transporte, regalo y compras).
rows = []
for name in ('Ramen en Shibuya', 'Shinkansen a Kioto', 'Amuleto en Senso-ji', 'Compras en Shibuya'):
    i = s.find('>' + name + '<')
    a = s.rfind('<div style="position: relative; display: flex; align-items: center; gap: 12px; padding: 8px 12px 8px 8px;', 0, i)
    rows.append((a, element_end(s, a)))
rowf = {}
for cat, (a, b) in zip((0, 2, 7, 4), rows):
    seg = s[a:b]
    u = DATA.search(seg).group(1)
    c1, c2 = re.search(r'linear-gradient\(150deg, (#[0-9A-Fa-f]{6}), (#[0-9A-Fa-f]{6})\); animation: dn-kb', seg).groups()
    rowf[cat] = {'u': u, 'c1': c1, 'c2': c2}
for (a, b), (a2, _) in zip(rows, rows[1:]):
    assert b == a2
s = (s[:rows[0][0]] +
     '<sc-for list="{{recent}}" as="r" hint-placeholder-count="4"><div style="{{r.card}}"><span style="{{r.box}}"><span aria-hidden="true" style="{{r.photo}}"></span></span>'
     '<span style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1; min-width: 0"><span style="font-size: 13.5px; font-weight: 800">{{r.name}}</span><span style="font-size: 11px; color: #9FB0B8">{{r.meta}}</span></span>'
     '<span style="{{r.amtStyle}}">{{r.amt}}</span>'
     '<sc-if value="{{r.isNew}}" hint-placeholder-val="{{ false }}"><span style="position: absolute; left: 6px; top: 4px; height: 14px; border-radius: 7px; padding: 0 5px; background: #FF8A65; color: #0B1217; font-size: 7.5px; font-weight: 800; display: flex; align-items: center; animation: nq-pop 0.4s ease 1.4s both">NUEVO</span></sc-if></div></sc-for>'
     + s[rows[-1][1]:])

# --- 6. Fuera el botón de probar y la nota de ejemplo; el aviso, de verdad.
cut_element('>Probar aviso de Flyra<', '<button')
cut_element('>Gastos de ejemplo. En la app', '<span')
rep('>Hoy llevas 230 € y tu ritmo para no pasarte es 122 € al día. ¿Te enseño planes gratis cerca?<', '>{{flyTxt}}<')
rep('<button type="button" onClick="{{flyHide}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FFB86B;',
    '<button type="button" onClick="{{flyFree}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FFB86B;')

# --- 7. La lógica: la de la maqueta, con tus datos (logic.js). Las fotos
# de los planes y de los tipos de gasto, las mismas de la maqueta.
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
old = s[a:b]
pf = re.search(r'const PF = (\[.*?\]);\n', old).group(1)
catf = re.search(r'const CATF = (\{.*?\});\n', old).group(1)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
for k, v in (('/*PF*/[]', pf), ('/*CATF*/{}', catf), ('/*ROWF*/{}', json.dumps(rowf))):
    assert logic.count(k) == 1, k
    logic = logic.replace(k, v)
s = s[:a] + logic + s[b:]

low = s[s.find('</head>'):]
for bad in ('ejemplo', 'EJEMPLO', '.dc.html', 'claude.ai', 'Japón', 'JAPÓN', 'Shibuya', 'Kioto', 'Hakone', 'konbini', 'Probar aviso', 'BBVA</span>', '1.400', '122 €', '230 €'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
