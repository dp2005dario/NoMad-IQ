# Crea assets/group/grupo.html a partir de la maqueta "Grupo" (Viaje en grupo).
# Uso:
#   python3 tool/grupo/build_page.py <Grupo.dc.html> <support.js> assets/group/grupo.html
#
# Se queda TODO lo de la maqueta (cabecera con las caras, los 4 atajos, el
# aviso de Flyra, "Gustos de cada uno", "Así lo busca Flyra" con sus 5 pasos
# animados, "Votad dónde dormir", de dónde saca Flyra los datos, cómo elige
# sitios cerca, "¿Qué os apetece?", el plan y los gastos) y solo se quitan los
# datos de ejemplo, la nota "son ejemplos" y la barra de abajo (la app ya
# tiene la suya). Lo de verdad lo pone la app (lib/features/group/
# group_page.dart) en la marca /*ECLIPTA*/ y lo que llega después entra con
# window.ECLin({...}) sin recargar.
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


def rep_re(pattern, new, count=1, flags=0):
    global s
    s, n = re.subn(pattern, new, s, flags=flags)
    assert n == count, (n, pattern[:120])


def element_end(text, start):
    """Dónde acaba el elemento que empieza en [start] (contando etiquetas)."""
    depth = 0
    for m in re.finditer(r'<(/?)([a-zA-Z][\w-]*)[^>]*?(/?)>', text[start:]):
        if m.group(3) == '/' or m.group(2) in ('input', 'br', 'img', 'meta', 'link'):
            continue
        depth += 1 if m.group(1) == '' else -1
        if depth == 0:
            return start + m.end()
    raise AssertionError('sin cierre')


# --- 1. El motor de la maqueta va dentro (sin Internet). "<!--", "<script"
# y "</script" dentro del código se escriben con \x3c.
rt_safe = rt.replace('<!--', '\\x3c!--').replace('<script', '\\x3cscript').replace('</script', '\\x3c/script')
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
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(120% 70% at 50% 0%',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(120% 70% at 50% 0%')

# --- 2. Cabecera: tu viaje y las caras de verdad (tocar = Ajustes).
rep('>12 – 15 de mayo · 4 viajeros<', '>{{sub}}<')
rep('letter-spacing: -0.02em">Lisboa</span>', 'letter-spacing: -0.02em">{{title}}</span>')
a = s.find('<a href="Ajustes.dc.html"')
b = element_end(s, a)
head = re.match(r'<a href="Ajustes.dc.html" (aria-label="[^"]*" style="[^"]*")>', s[a:b]).group(1)
s = s[:a] + ('<a onClick="{{openSettings}}" ' + head + '><sc-for list="{{avatars}}" as="av" hint-placeholder-count="4">'
             '<span style="{{av.style}}">{{av.i}}<span style="{{av.dot}}"></span></span></sc-for></a>') + s[b:]

# --- 3. Los 4 atajos abren su pantalla de la app.
for i, page in enumerate(['ChatGrupo', 'Bote', 'Planes', 'Cromos']):
    rep(f'<a href="{page}.dc.html"', f'<a onClick="{{{{tile{i}}}}}"')

# --- 4. El aviso de Flyra: lo que pasa de verdad en tu viaje.
rep('>¡Tengo un acuerdo para los 4!<', '>{{flyraTitle}}<')
rep('>He cruzado lo que quiere cada uno. Mira abajo cómo lo he buscado y vota.<', '>{{flyraText}}<')

# --- 5. "Así lo busca Flyra": notas con tus datos.
rep('>Barrios y distancias con OpenStreetMap. Gana Alfama: fado cerca y tren a Cascais.<', '>{{zoneNote}}<')
rep('<div style="{{h.style}}">', '<div onClick="{{h.open}}" style="{{h.style}}">')
rep('<a href="Eventos.dc.html" style="', '<a onClick="{{openEvents}}" style="cursor: pointer; ')
rep('>Eventos reales de Ticketmaster (ya conectado en la app). Aquí son ejemplos.<', '>{{eventsNote}}<')
rep('>Te propongo 2 opciones<', '>{{proposal}}<')

# --- 6. Votad dónde dormir: si aún no hay zonas, se dice por qué.
rep('<div style="{{statusStyle}}">{{status}}</div>',
    '<sc-if value="{{noOptions}}" hint-placeholder-val="{{ false }}"><span style="font-size: 12px; color: #B9AEDB">{{optionsNote}}</span></sc-if>'
    '<sc-if value="{{hasOptions}}" hint-placeholder-val="{{ true }}"><div style="{{statusStyle}}">{{status}}</div></sc-if>')

# --- 7. ¿Qué os apetece?: sin "ejemplo", con la hora dorada de hoy.
rep('<sc-for list="{{spots}}" as="sp" hint-placeholder-count="3">',
    '<sc-if value="{{spotsNote}}" hint-placeholder-val="{{ false }}"><span style="font-size: 12px; color: #B7C5CC">{{spotsNote}}</span></sc-if>'
    '<sc-for list="{{spots}}" as="sp" hint-placeholder-count="3">')
m = re.search(r'<div style="display: flex; align-items: center; gap: 8px; border-radius: 12px; background: linear-gradient\(90deg, #FF8A6522, #FFD27A22\)', s)
a = m.start()
b = element_end(s, a)
seg = s[a:b]
seg = re.sub(r'>Hora dorada hoy sobre las [^<]*<', '>{{golden}}<', seg)
assert '{{golden}}' in seg
s = s[:a] + '<sc-if value="{{hasGolden}}" hint-placeholder-val="{{ false }}">' + seg + '</sc-if>' + s[b:]
rep('Sitios de OpenStreetMap; los de aquí son ejemplos. La app no muestra precios de sitios.',
    'Sitios de OpenStreetMap. La app no muestra precios de sitios.')

# --- 8. El plan del grupo (lo que metisteis en «Elegir planes»).
rep('<sc-for list="{{days}}" as="d" hint-placeholder-count="3">',
    '<sc-for list="{{days}}" as="d" hint-placeholder-count="3">')
a = s.find('<div style="position: relative; flex-shrink: 0">\n<span style="position: absolute; left: 20px; right: 20px; top: 27px')
b = element_end(s, a)
s = (s[:a] + '<sc-if value="{{hasDays}}" hint-placeholder-val="{{ true }}">' + s[a:b] + '</sc-if>'
     '<sc-if value="{{noDays}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{openPlans}}" style="border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 12px; font-family: inherit; font-size: 13px; font-weight: 700; color: #DCE5E9; text-align: left; cursor: pointer; flex-shrink: 0">'
     'Aún no hay planes. Elegidlos juntos en «Elegir planes» y Flyra os los ordena por días.</button></sc-if>' + s[b:])

# --- 9. Gastos del grupo: abre Gastos (lo que debes, si lo hay).
rep('<a href="Gastos.dc.html" class="g7-shine" style="', '<a onClick="{{openMoney}}" class="g7-shine" style="cursor: pointer; ')
rep('>Debes 21,50 €<', '>{{debt}}<')
rep_re(r'<span style="font-size: 11px; color: #6F828C; text-align: center; flex-shrink: 0">Nombres, alojamientos y eventos de esta maqueta son ejemplos.</span>\n?', '')

# --- 10. Fuera la barra de abajo de la maqueta (la app tiene la suya).
a = s.find('<nav aria-label="Principal"')
s = s[:a] + s[element_end(s, a):]

# --- 11. La lógica: la de la maqueta, con tus datos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
s = s[:a] + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

# (El motor de la maqueta sí nombra .dc.html: se mira solo lo de después.)
low = s[s.find('</head>'):].lower()
assert 'ejemplo' not in low and '.dc.html' not in low, low[max(0, low.find('ejemplo') - 200):low.find('ejemplo') + 60]
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
