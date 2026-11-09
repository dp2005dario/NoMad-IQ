# Crea assets/radar/radar.html a partir de la maqueta "Radar".
# Uso:
#   python3 tool/radar/build_page.py <Radar.dc.html> <support.js> assets/radar/radar.html
#
# Se queda TODO lo de la maqueta (el radar que gira con la nube, la tarjeta
# naranja de "Ojo en esta zona", el "¿Me están cobrando de más?" con su
# barra de colores y la aguja, y el bocadillo de Flyra). Los datos son los de
# verdad: la lluvia de MET Norway, los timos que avisan los viajeros y lo que
# pagaron ellos. La app los pone en la marca /*ECLIPTA*/
# (lib/features/radar/radar_page.dart).
#
# Fuera: la nota "Precios de ejemplo" y el botón "PROBAR AVISO" (eran para
# probar la maqueta). El bocadillo sale solo si no hay previsión de lluvia.
import os
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


def cut(start, end):
    """Quita desde [start] hasta [end] (incluido)."""
    global s
    a = s.find(start)
    assert a >= 0, start[:80]
    b = s.find(end, a)
    assert b >= 0, end[:80]
    s = s[:a] + s[b + len(end):]


# --- 1. El motor de la maqueta va dentro (sin Internet).
rt_safe = rt.replace('<!--', '\\x3c!--').replace('<script', '\\x3cscript').replace('</script', '\\x3c/script')
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
i = s.find('<title>')
s = s[:i] + '<title>ECLIPTA · Radar local</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}',
    'html,body{margin:0;background:#0B1217;overflow:hidden}\n'
    '.q-row{overflow-x:auto;scrollbar-width:none}.q-row::-webkit-scrollbar{display:none}\n'
    '#q-asked{min-width:0;text-align:center;outline:none}#q-asked::placeholder{color:#6F8490}')
# Con varios timos (o la letra grande) la página se desliza.
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217; font-family: \'Manrope\', system-ui, sans-serif; color: #F2F5F3; position: relative; overflow: hidden;',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217; font-family: \'Manrope\', system-ui, sans-serif; color: #F2F5F3; position: relative; overflow-x: hidden; overflow-y: auto; scrollbar-width: none;')
# Las tarjetas no se aplastan cuando no caben: se desliza.
rep('<div style="border-radius: 24px; background: linear-gradient(150deg, #13213A 0%, #0F1A2C 100%);',
    '<div style="flex-shrink: 0; border-radius: 24px; background: linear-gradient(150deg, #13213A 0%, #0F1A2C 100%);')

# --- 2. Arriba: volver, el título y dónde estás.
rep('<a href="Mapa.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="{{backTxt}}" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Radar local</span>', 'letter-spacing: -0.02em">{{title}}</span>')
rep('<span style="font-size: 12px; color: #9FB0B8">Ahora en Shinjuku, Tokio</span>', '<span style="font-size: 12px; color: #9FB0B8">{{sub}}</span>')

# --- 3. La lluvia: la nube del radar solo si va a llover.
CLOUD = '<span style="position: absolute; left: 10px; top: 20px;'
a = s.find(CLOUD)
b = s.find('</span>', a) + len('</span>')
s = s[:a] + '<sc-if value="{{rainy}}" hint-placeholder-val="{{ true }}">' + s[a:b] + '</sc-if>' + s[b:]
rep('<span style="font-size: 11px; font-weight: 800; letter-spacing: 0.06em; color: #9CC4FF">LLUEVE EN 15 MIN</span>'
    '<span style="font-size: 16px; font-weight: 800; line-height: 1.3">Chaparrón de unos 25 min. Entra en el café de la esquina, a 60 m.</span>'
    '<a href="Mapa.dc.html" style="font-size: 13px; font-weight: 800; color: #9CC4FF">Llévame</a></span>',
    '<span style="font-size: 11px; font-weight: 800; letter-spacing: 0.06em; color: #9CC4FF">{{rainLbl}}</span>'
    '<span style="font-size: 16px; font-weight: 800; line-height: 1.3">{{rainTxt}}</span>'
    '<sc-if value="{{rainy}}" hint-placeholder-val="{{ true }}"><a onClick="{{go}}" style="cursor: pointer; text-decoration: underline; font-size: 13px; font-weight: 800; color: #9CC4FF">{{goTxt}}</a></sc-if>'
    '<sc-if value="{{hasAttr}}" hint-placeholder-val="{{ true }}"><span style="font-size: 10px; color: #6F8FB8">{{attr}}</span></sc-if></span>')

# --- 4. "Ojo en esta zona": una tarjeta por cada timo avisado (o lo que
# pasa si aún no hay), y los botones para avisar tú.
CARD = '<div style="border-radius: 24px; background: #2A2114; border: 1px solid #5A4527; padding: 14px; display: flex; flex-direction: column; gap: 8px">'
rep(CARD, '<sc-for list="{{scams}}" as="z" hint-placeholder-count="1">' + CARD.replace('<div style="', '<div style="flex-shrink: 0; '))
rep('color: #FFD9A8">OJO EN ESTA ZONA · KABUKICHO</span><span style="font-size: 15px; font-weight: 800">Captadores en la calle</span>',
    'color: #FFD9A8">{{z.lbl}}</span><span style="font-size: 15px; font-weight: 800">{{z.title}}</span>')
rep('<span style="font-size: 13px; line-height: 1.5; color: #FFE7C7">Te invitan a un bar «barato» y luego la cuenta es enorme. No entres con quien te para por la calle; mejor sitios que hayas elegido tú.</span>\n'
    '<span style="font-size: 11px; color: #C9A97A">Avisado por 312 viajeros · actualizado esta semana</span>\n'
    '</div>',
    '<span style="font-size: 13px; line-height: 1.5; color: #FFE7C7">{{z.why}}</span>\n'
    '<sc-if value="{{z.hasBy}}" hint-placeholder-val="{{ true }}"><span style="font-size: 11px; color: #C9A97A">{{z.by}}</span></sc-if>\n'
    '</div></sc-for>\n'
    '<sc-if value="{{canReport}}" hint-placeholder-val="{{ true }}">'
    + CARD.replace('<div style="', '<div style="flex-shrink: 0; ') +
    '<span style="font-size: 12px; line-height: 1.5; color: #FFE7C7">{{reportHint}}</span>'
    '<div style="display: flex; flex-wrap: wrap; gap: 6px"><sc-for list="{{report}}" as="r" hint-placeholder-count="3">'
    '<button type="button" onClick="{{r.tap}}" aria-pressed="{{r.on}}" style="{{r.style}}">{{r.label}}</button></sc-for></div></div></sc-if>')

# --- 5. ¿Me están cobrando de más? Con los precios que pagaron viajeros.
BOX = '<div style="border-radius: 24px; background: #141E25; border: 1px solid #26363F; padding: 14px; display: flex; flex-direction: column; gap: 10px">'
rep(BOX, '<sc-if value="{{showPrice}}" hint-placeholder-val="{{ true }}">' + BOX.replace('<div style="', '<div style="flex-shrink: 0; '))
rep('<span style="font-size: 15px; font-weight: 800">¿Me están cobrando de más?</span>\n<div style="display: flex; gap: 6px">',
    '<span style="font-size: 15px; font-weight: 800">{{priceH}}</span>\n<div class="q-row" style="display: flex; gap: 6px">')
rep('<span style="font-size: 12px; color: #9FB0B8">Te piden:</span>', '<span style="font-size: 12px; color: #9FB0B8">{{askH}}</span>')
rep('<sc-for list="{{prices}}" as="p" hint-placeholder-count="3"><button type="button" onClick="{{p.pick}}" aria-pressed="{{p.on}}" style="{{p.style}}">{{p.label}}</button></sc-for>',
    '<input id="q-asked" type="text" inputmode="decimal" autocomplete="off" onInput="{{type}}" placeholder="0" aria-label="{{askH}}" style="{{askStyle}}">'
    '<button type="button" onClick="{{pickCur}}" aria-label="{{curTxt}}" style="{{curStyle}}">{{cur}}</button>')
rep('<div style="position: relative; height: 14px;', '<sc-if value="{{hasRange}}" hint-placeholder-val="{{ true }}"><div style="position: relative; height: 14px;')
rep('<span>{{lo}}</span><span>normal aquí: {{range}}</span><span>{{hi}}</span></div>',
    '<span>{{lo}}</span><span>{{rangeTxt}}</span><span>{{hi}}</span></div></sc-if>')
rep('<span style="{{verdictStyle}}">{{verdict}}</span>\n</div>',
    '<sc-if value="{{hasVerdict}}" hint-placeholder-val="{{ true }}"><span style="{{verdictStyle}}">{{verdict}}</span></sc-if>\n'
    '<sc-if value="{{canPay}}" hint-placeholder-val="{{ true }}"><a onClick="{{pay}}" style="{{payStyle}}">{{payTxt}}</a></sc-if>\n'
    '</div></sc-if>')
rep('<span style="font-size: 11px; color: #6F8490; text-align: center; margin-top: auto">Precios de ejemplo; en la app salen de lo que pagan otros viajeros.</span>',
    '<sc-if value="{{showPrice}}" hint-placeholder-val="{{ true }}"><span style="font-size: 11px; line-height: 1.5; color: #6F8490; text-align: center; margin-top: auto">{{note}}</span></sc-if>')

# --- 6. Fuera el botón de probar; el bocadillo sale solo si hace falta.
cut('<button type="button" onClick="{{flyShow}}" aria-label="Probar el aviso de Flyra"', '</svg>PROBAR AVISO</button>')
rep('<div class="fly-alert fly-live" role="alert" style="position: absolute;', '<div class="fly-alert fly-live" role="alert" style="position: fixed;')
rep('color: #F2F5F3">Sin radar de lluvia aquí</span><span style="font-size: 12.5px; line-height: 1.4; color: #B9C6CC">No hay una fuente fiable de radar para esta zona. Te doy la previsión por horas de este punto.</span>',
    'color: #F2F5F3">{{flyTitle}}</span><span style="font-size: 12.5px; line-height: 1.4; color: #B9C6CC">{{flyText}}</span>')
rep('color: #1A0B0B">Vale</button>', 'color: #1A0B0B">{{flyOk}}</button>')

# --- 7. La lógica: la de la maqueta con los datos de verdad (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('class Component'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Shinjuku', 'Kabukicho', 'KABUKICHO', '.dc.html', 'PROBAR', 'Ramen', '312 viajeros', '¥'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
