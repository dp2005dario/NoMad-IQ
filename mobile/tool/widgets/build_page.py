# Crea assets/widgets/widgets.html a partir de la maqueta "Widgets".
# Uso:
#   python3 tool/widgets/build_page.py <Widgets.dc.html> <support.js> assets/widgets/widgets.html
#
# Se queda TODO lo de la maqueta: el fondo de atardecer con montañas, Móvil
# / Avisos / Reloj, el widget del vuelo con el avión que avanza, los dos
# widgets pequeños, el aviso "en directo" con sus pasos y el reloj con su
# anillo, y Antes / En vuelo / Aterrizado abajo. Los datos son los tuyos: tu
# próximo vuelo (el del Modo fácil), el chollo de hoy y tu presupuesto, lo
# mismo que pintan los widgets de Android. La app los pone en la marca
# /*ECLIPTA*/ (lib/features/widgets/widgets_page.dart).
#
# Fuera: el vuelo IB 6801 a Tokio, el chollo a Bali, los yenes, "Noelia ha
# pagado la cena", la batería de mentira y "Madrid 18°".
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


def cut_between(start, end, new):
    """Cambia todo desde [start] hasta [end] (incluido) por [new]."""
    global s
    a = s.find(start)
    assert a >= 0, start[:80]
    b = s.find(end, a)
    assert b >= 0, end[:80]
    s = s[:a] + new + s[b + len(end):]


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

rep('body{margin:0}', 'html,body{margin:0;background:#1B2D5A;overflow:hidden}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; font-family: \'Manrope\'', '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; font-family: \'Manrope\'')

# --- 2. Arriba: volver y la hora (en vez de la batería de mentira).
rep('<span>{{clock}}</span><span style="display: flex; gap: 6px; align-items: center"><svg width="16" height="12" viewBox="0 0 16 12" aria-hidden="true"><path d="M1 11h2V8H1zM5 11h2V6H5zM9 11h2V3H9zM13 11h2V1h-2z" fill="#FFFFFF"></path></svg>87 %</span>',
    '<button type="button" onClick="{{back}}" aria-label="{{backTxt}}" style="height: 24px; border-radius: 12px; border: none; background: rgba(11,18,23,0.55); color: #FFFFFF; font-family: inherit; font-size: 12px; font-weight: 800; padding: 0 10px 0 6px; display: flex; align-items: center; gap: 2px; cursor: pointer"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"></path></svg>{{title}}</button><span>{{clock}}</span>')
rep('aria-label="Qué ver"', 'aria-label="{{viewsAria}}"')

# --- 3. Móvil: tus widgets.
rep('margin-top: -6px">Jueves, 22 oct · Madrid 18°</div>', 'margin-top: -6px">{{dateLine}}</div>')
rep('<a href="Vuelos.dc.html" aria-label="{{widgetAria}}" style="border-radius: 28px;', '<sc-if value="{{noFlight}}" hint-placeholder-val="{{ false }}"><div style="border-radius: 28px; background: rgba(11,18,23,0.86); backdrop-filter: blur(12px); border: 1px solid rgba(255,255,255,0.12); padding: 16px; display: flex; flex-direction: column; gap: 10px; align-items: flex-start"><span style="font-size: 12px; font-weight: 800; letter-spacing: 0.06em; color: #3DDC97">{{flightName}}</span><span style="font-size: 14px; line-height: 1.45; color: #DCE5E9">{{noFlightTxt}}</span><button type="button" onClick="{{edit}}" style="height: 40px; border-radius: 20px; border: none; background: #3DDC97; color: #0B1217; font-family: inherit; font-size: 13px; font-weight: 800; padding: 0 16px; cursor: pointer">{{editTxt}}</button></div></sc-if>'
    '<sc-if value="{{hasFlight}}" hint-placeholder-val="{{ true }}"><div onClick="{{openFlight}}" role="button" aria-label="{{widgetAria}}" style="cursor: pointer; border-radius: 28px;')
rep('<span style="font-size: 12px; color: #9FB0B8; font-weight: 700">IB 6801 · NomadIQ</span>', '<span style="font-size: 12px; color: #9FB0B8; font-weight: 700">{{flightRight}}</span>')
rep('line-height: 1">MAD</span>', 'line-height: 1">{{fromCode}}</span>')
rep('line-height: 1">HND</span>', 'line-height: 1">{{toCode}}</span>')
rep('</sc-for>\n</div>\n</a>\n', '</sc-for>\n</div>\n</div></sc-if>\n')
a = s.find('<a href="Vuelos.dc.html" style="border-radius: 26px; background: rgba(19,33,58,0.9)')
b = s.find('</a>\n</div>\n</div>', a)
assert a > 0 and b > a
small = ''.join(
    '<div onClick="{{%s.open}}" role="button" style="position: relative; cursor: pointer; border-radius: 26px; background: %s; border: 1px solid %s; padding: 14px; color: #F2F5F3; display: flex; flex-direction: column; gap: 4px; height: 128px; box-sizing: border-box; overflow: hidden">'
    '<span style="font-size: 11px; font-weight: 800; letter-spacing: 0.06em; color: %s">{{%s.tag}}</span>'
    '<sc-if value="{{%s.has}}" hint-placeholder-val="{{ true }}"><span style="font-size: 14px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{%s.title}}</span>'
    '<span style="font-family: \'Bricolage Grotesque\', sans-serif; font-size: 28px; font-weight: 800; letter-spacing: -0.02em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{%s.big}}</span>'
    '<span style="font-size: 11px; color: %s; line-height: 1.3">{{%s.small}}</span></sc-if>'
    '<sc-if value="{{%s.none}}" hint-placeholder-val="{{ false }}"><span style="font-size: 12.5px; line-height: 1.4; color: %s">{{%s.empty}}</span></sc-if>'
    '<sc-if value="{{canPin}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{%s.pin}}" aria-label="{{pinTxt}}" style="position: absolute; right: 10px; top: 10px; width: 26px; height: 26px; border-radius: 13px; border: none; background: rgba(255,255,255,0.14); color: #FFFFFF; font-family: inherit; font-size: 16px; font-weight: 800; line-height: 1; cursor: pointer">+</button></sc-if></div>'
    % (k, bg, bd, c, k, k, k, k, sc, k, k, sc, k, k)
    for k, bg, bd, c, sc in (('deal', 'rgba(19,33,58,0.9)', 'rgba(108,168,255,0.35)', '#6CA8FF', '#A9BEDF'),
                             ('budget', 'rgba(43,32,14,0.9)', 'rgba(255,184,107,0.35)', '#FFB86B', '#F3D3AE')))
s = s[:a] + small + s[b + len('</a>'):]
rep('</div>\n</div>\n\n<div style="position: absolute; left: 24px; right: 24px; bottom: 86px;',
    '</div>\n<div style="display: flex; gap: 8px; flex-wrap: wrap; align-items: center"><sc-if value="{{hasFlight}}" hint-placeholder-val="{{ true }}"><button type="button" onClick="{{edit}}" style="height: 34px; border-radius: 17px; border: none; background: rgba(11,18,23,0.6); color: #FFFFFF; font-family: inherit; font-size: 12.5px; font-weight: 800; padding: 0 14px; cursor: pointer">{{editTxt}}</button></sc-if><sc-if value="{{canPin}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{pinFlight}}" style="height: 34px; border-radius: 17px; border: none; background: rgba(11,18,23,0.6); color: #FFFFFF; font-family: inherit; font-size: 12.5px; font-weight: 800; padding: 0 14px; cursor: pointer">+ {{pinTxt}}</button></sc-if></div>\n'
    '<span style="font-size: 12px; line-height: 1.45; color: rgba(255,255,255,0.85); padding: 0 4px">{{howTo}}</span>\n'
    '</div>\n\n<div style="position: absolute; left: 24px; right: 24px; bottom: 86px;')
rep('<a href="Inicio.dc.html" aria-label="Abrir NomadIQ" style="', '<a onClick="{{back}}" aria-label="{{openApp}}" style="cursor: pointer; ')

# --- 4. Avisos: el aviso "en directo" de tu vuelo.
rep('<span style="font-size: 13px; color: #B7C5CC; font-weight: 600">jue, 22 oct</span>', '<span style="font-size: 13px; color: #B7C5CC; font-weight: 600">{{dateShort}}</span>')
rep('flex-grow: 1">NomadIQ · en directo</span>', 'flex-grow: 1">{{liveTag}}</span>')
rep('<div style="display: flex; justify-content: space-between; font-size: 11px; font-weight: 700; color: #9FB0B8"><span>Casa</span><span>Aeropuerto</span><span>En vuelo</span><span>Hotel</span></div>',
    '<div style="display: flex; justify-content: space-between; font-size: 11px; font-weight: 700; color: #9FB0B8"><sc-for list="{{stops}}" as="x" hint-placeholder-count="4"><span>{{x}}</span></sc-for></div>')
rep('<a href="Vuelos.dc.html" style="height: 40px; border-radius: 20px; background: #26363F; color: #F2F5F3; text-decoration: none; font-size: 13px; font-weight: 800; display: flex; align-items: center; justify-content: center">Ver el vuelo en 3D</a>',
    '<button type="button" onClick="{{fly3d}}" style="height: 40px; border-radius: 20px; border: none; background: #26363F; color: #F2F5F3; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer">{{fly3dTxt}}</button>')
rep('<a href="Boveda.dc.html" style="height: 40px; border-radius: 20px; background: #26363F; color: #F2F5F3; text-decoration: none; font-size: 13px; font-weight: 800; display: flex; align-items: center; justify-content: center">Tarjeta de embarque</a>',
    '<button type="button" onClick="{{boarding}}" style="height: 40px; border-radius: 20px; border: none; background: #26363F; color: #F2F5F3; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer">{{boardingTxt}}</button>')
a = s.find('<div style="border-radius: 24px; background: #1A262E; padding: 14px 16px; display: flex; gap: 12px; align-items: center; opacity: 0.85">')
b = s.find('te tocan unos 14 €</span></span>\n</div>', a) + len('te tocan unos 14 €</span></span>\n</div>')
assert a > 0 and b > a
s = s[:a] + ('<div style="border-radius: 24px; background: #1A262E; padding: 14px 16px; display: flex; gap: 12px; align-items: center">'
             '<span style="display: flex; flex-direction: column; gap: 2px; flex: 1"><span style="font-size: 14px; font-weight: 800">{{liveH}}</span><span style="font-size: 12px; line-height: 1.4; color: #9FB0B8">{{liveP}}</span></span>'
             '<button type="button" role="switch" aria-checked="{{liveOn}}" aria-label="{{liveH}}" onClick="{{toggleLive}}" style="{{liveTrack}}"><span style="{{liveKnob}}"></span></button></div>') + s[b:]

# --- 5. Reloj.
rep('line-height: 1.5">En el reloj ves la puerta y el embarque, y vibra cuando cambia algo. La tarjeta de embarque se abre con un toque.</div>', 'line-height: 1.5">{{watchHint}}</div>')
rep('<path d="M14 14h3v3h-3zM20 14v7h-6"></path></svg>Tarjeta QR</span>', '<path d="M14 14h3v3h-3zM20 14v7h-6"></path></svg>{{qrTxt}}</span>')

# --- 6. Antes / En vuelo / Aterrizado: solo con un vuelo.
rep('<div style="position: absolute; left: 16px; right: 16px; bottom: 18px; display: flex; gap: 8px">\n<sc-for list="{{phases}}" as="p" hint-placeholder-count="3">',
    '<div style="position: absolute; left: 16px; right: 16px; bottom: 18px; display: flex; gap: 8px">\n<sc-for list="{{phases}}" as="p" hint-placeholder-count="0">')

# --- 7. La lógica (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('// ----'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Noelia', 'Bali', '¥', 'IB 6801', 'NomadIQ', '87 %', 'Madrid', 'Tokio', 'K42', '.dc.html'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
