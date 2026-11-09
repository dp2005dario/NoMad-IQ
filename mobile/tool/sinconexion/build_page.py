# Crea assets/offline/sinconexion.html a partir de la maqueta "SinConexion".
# Uso:
#   python3 tool/sinconexion/build_page.py <SinConexion.dc.html> <support.js> assets/offline/sinconexion.html
#
# Se queda TODO lo de la maqueta: la nube que suelta cuadritos al móvil, el
# modo avión del botón de arriba, "Elige la zona" con su recuadro de
# hormigas, Centro / Ciudad / Con alrededores, "Qué guardar", las tarjetas
# con su anillo de progreso, el estallido al terminar, borrar con
# confirmación, los interruptores, la barra de espacio y el bocadillo de
# Flyra. Los datos son los tuyos: las ciudades (por su aeropuerto), lo que
# ocupa de verdad cada una y la descarga real (city_downloader.dart). La app
# los pone en la marca /*ECLIPTA*/ (lib/features/offline/offline_page.dart).
#
# Fuera: las ciudades, tamaños y velocidades de ejemplo, "PROBAR AVISO" y
# "Probar: me quedo sin wifi" (el bocadillo sale solo cuando falta el wifi).
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
i = s.find('<title>')
s = s[:i] + '<title>ECLIPTA · Zonas sin conexión</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}\n'
    '#q-search{flex:none;width:150px;height:34px;box-sizing:border-box;border-radius:17px;border:1px solid #33444E;background:#10181E;color:#F2F5F3;font-family:inherit;font-size:13px;font-weight:700;padding:0 12px;outline:none}\n'
    '#q-search::placeholder{color:#6F8490}')
rep('<div style="{{rootSt}}">', '<div id="q-root" style="{{rootSt}}">')

# --- 2. Arriba: volver, el título y el modo avión (cómo se ve sin internet).
rep('<a href="Privacidad.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="{{backTxt}}" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Zonas sin conexión</span>', 'letter-spacing: -0.02em">{{title}}</span>')
rep('aria-label="Probar modo avión"', 'aria-label="{{planeAria}}"')
rep('<span style="font-size: 13px; font-weight: 800">Modo avión · sin internet</span>', '<span style="font-size: 13px; font-weight: 800">{{planeH}}</span>')
rep('line-height: 1.15">Tu ciudad en el móvil, aunque no haya internet</span>', 'line-height: 1.15">{{heroH}}</span>')
rep('line-height: 1.4">Mapa, calles, buscador, rutas a pie y audioguías funcionan en modo avión.</span>', 'line-height: 1.4">{{heroP}}</span>')

# --- 3. Elige la zona: buscas la ciudad (por su nombre o su aeropuerto).
rep('<span style="font-size: 15px; font-weight: 800">Elige la zona</span>', '<span style="font-size: 15px; font-weight: 800">{{areaH}}</span>')
rep('<div style="display: flex; gap: 6px; overflow-x: auto; scrollbar-width: none; margin: 0 -4px; padding: 0 4px"><sc-for list="{{cityChips}}"',
    '<div style="display: flex; gap: 6px; overflow-x: auto; scrollbar-width: none; margin: 0 -4px; padding: 0 4px"><input id="q-search" type="search" autocomplete="off" onInput="{{search}}" placeholder="{{searchHint}}" aria-label="{{searchHint}}"><sc-for list="{{cityChips}}"')
# El mapa de la zona: el de OpenStreetMap alrededor de tu ciudad (en vez del
# dibujo de la maqueta).
a = s.find('<img src="data:image/webp')
b = s.find('alt="Mapa de la zona elegida" style="{{mapImg}}">', a)
assert a > 0 and b > a
s = s[:a] + '<div style="{{mapImg}}"><sc-for list="{{tiles}}" as="m" hint-placeholder-count="0"><span style="{{m}}"></span></sc-for></div>' + s[b + len('alt="Mapa de la zona elegida" style="{{mapImg}}">'):]
rep('<span style="position: absolute; right: 10px; bottom: 10px; height: 30px; padding: 0 12px; border-radius: 15px; background: #3DDC97; color: #0B1217; font-size: 13px; font-weight: 800; display: flex; align-items: center">~{{estMB}} MB</span>',
    '<sc-if value="{{hasEst}}" hint-placeholder-val="{{ true }}"><span style="position: absolute; right: 10px; bottom: 10px; height: 30px; padding: 0 12px; border-radius: 15px; background: #3DDC97; color: #0B1217; font-size: 13px; font-weight: 800; display: flex; align-items: center">{{estTxt}}</span></sc-if>')
rep('margin-top: 2px">QUÉ GUARDAR</span>', 'margin-top: 2px">{{whatH}}</span>')
rep('<span style="font-size: 10.5px; color: #6F8490">Tamaños aproximados de la maqueta. En la app se calculan con la zona real antes de descargar.</span>',
    '<span style="font-size: 10.5px; line-height: 1.45; color: #6F8490">{{note}}</span>')

# --- 4. Tus zonas.
rep('<span style="font-size: 15px; font-weight: 800">Tus zonas</span>', '<span style="font-size: 15px; font-weight: 800">{{zonesH}}</span>')
rep('↻ Hay cambios en el mapa · actualizar {{c.updMB}} MB</button>', '{{c.updTxt}}</button>')
rep('<span style="font-size: 12.5px; flex: 1; color: #FFD3D6">¿Borrar {{c.name}}? Liberas {{c.mbNow}} MB</span>', '<span style="font-size: 12.5px; flex: 1; color: #FFD3D6">{{c.askTxt}}</span>')
rep('padding: 0 12px; cursor: pointer">Borrar</button><button type="button" onClick="{{c.noDel}}"', 'padding: 0 12px; cursor: pointer">{{c.delTxt}}</button><button type="button" onClick="{{c.noDel}}"')
rep('padding: 0 10px; cursor: pointer">No</button>', 'padding: 0 10px; cursor: pointer">{{c.noTxt}}</button>')
rep('aria-label="Borrar {{c.name}}"', 'aria-label="{{c.delAria}}"')
rep('<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"></path></svg>Borrar</button>', '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"></path></svg>{{c.delTxt}}</button>')
rep('flex-shrink: 0">No tienes zonas guardadas. Elige una arriba.</div>', 'flex-shrink: 0">{{noneTxt}}</div>')

# --- 5. Los interruptores (de verdad) y el espacio.
rep('<span style="font-size: 15px; font-weight: 800">Descargar solo con wifi</span><span style="font-size: 12px; color: #9FB0B8">Para no gastar tus datos en el extranjero</span>',
    '<span style="font-size: 15px; font-weight: 800">{{wifiH}}</span><span style="font-size: 12px; color: #9FB0B8">{{wifiP}}</span>')
rep('aria-label="Descargar solo con wifi"', 'aria-label="{{wifiH}}"')
rep('<span style="font-size: 15px; font-weight: 800">Actualizar solas</span><span style="font-size: 12px; color: #9FB0B8">Cuando haya wifi y el móvil esté cargando</span>',
    '<span style="font-size: 15px; font-weight: 800">{{autoH}}</span><span style="font-size: 12px; line-height: 1.4; color: #9FB0B8">{{autoP}}</span>')
rep('aria-label="Actualizar solas"', 'aria-label="{{autoH}}"')
rep('<button type="button" onClick="{{loseWifi}}" style="height: 38px; border-radius: 12px; border: 1px solid #5A4A2A; background: #1E1A12; color: #FFD9A8; font-family: inherit; font-size: 12.5px; font-weight: 800; cursor: pointer">Probar: me quedo sin wifi</button>\n', '')
rep('<span>Espacio en tu móvil</span>', '<span>{{spaceH}}</span>')
rep('text-align: center; flex-shrink: 0">Mapas de OpenStreetMap (© colaboradores de OSM). Ciudades, tamaños y velocidades son de ejemplo.</span>',
    'text-align: center; flex-shrink: 0">{{credits}}</span>')

# --- 6. Fuera el botón de probar; Flyra avisa cuando de verdad hace falta.
a = s.find('<button type="button" onClick="{{flyShow}}" aria-label="Probar el aviso de Flyra"')
b = s.find('PROBAR AVISO</button>', a) + len('PROBAR AVISO</button>')
assert a > 0 and b > a
s = s[:a] + s[b:]
rep('<div class="fly-alert fly-live" role="alert" style="position: absolute;', '<div class="fly-alert fly-live" role="alert" style="position: fixed;')
rep('color: #F2F5F3">Descarga en pausa</span><span style="font-size: 12.5px; line-height: 1.4; color: #B9C6CC">Te has quedado sin wifi. Seguirá sola cuando vuelvas a tener wifi, o puedes usar tus datos.</span>',
    'color: #F2F5F3">{{flyTitle}}</span><span style="font-size: 12.5px; line-height: 1.4; color: #B9C6CC">{{flyText}}</span>')
rep('<button type="button" onClick="{{flyHide}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FFB86B; color: #1A0B0B">Usar datos</button>'
    '<button type="button" onClick="{{flyHide}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: 1px solid #33444E; background: transparent; color: #DCE5E9">Esperar wifi</button>',
    '<button type="button" onClick="{{flyMain}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FFB86B; color: #1A0B0B">{{flyMainTxt}}</button>'
    '<sc-if value="{{flyTwo}}" hint-placeholder-val="{{ true }}"><button type="button" onClick="{{flyHide}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: 1px solid #33444E; background: transparent; color: #DCE5E9">{{flyAltTxt}}</button></sc-if>')

# --- 7. La lógica: la de la maqueta con tus ciudades (logic.js). Los datos
# de ejemplo (CITY, AREA, PART) se quedan fuera.
a = s.find('const CITY = {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('// ----'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Lisboa', 'Tokio', 'Nueva York', 'PROBAR', 'Probar', '.dc.html', '4096'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
