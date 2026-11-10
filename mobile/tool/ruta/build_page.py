# Crea assets/route/ruta.html a partir de la maqueta "Ruta".
# Uso:
#   python3 tool/ruta/build_page.py <Ruta.dc.html> <support.js> assets/route/ruta.html
#
# Se queda TODO lo de la maqueta: el mapamundi con la cámara que se acerca,
# los puntos que laten, el avión que sigue la ruta, "Simulación del
# recorrido" y las fichas de origen y destino. Los datos son los de verdad:
# el camino más corto entre los dos aeropuertos, por dónde pasa el avión
# (el aeropuerto más cercano a cada tramo), y las fichas de Wikipedia y
# Wikidata con fotos de licencia libre (en vez de los dibujos de ejemplo).
# La app los pone en la marca /*ECLIPTA*/
# (lib/features/route/route_page.dart).
#
# OJO (11-11-2026): por la lista de errores de DARIO se cambió el HTML de la
# página directamente en assets/ (no en este script). Si se vuelve a crear
# desde la maqueta, hay que repetir esos cambios: ver `git log` del asset.
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
s = s[:i] + '<title>ECLIPTA · Ruta del vuelo</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;', '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;')

# --- 2. Arriba: volver, la ruta y el botón del mundo.
rep('<a href="Vuelos.dc.html" aria-label="Volver al cazador de vuelos" style="', '<a onClick="{{back}}" aria-label="{{backTxt}}" style="cursor: pointer; ')
rep('letter-spacing: -0.01em">Madrid → Tokio</span>', 'letter-spacing: -0.01em; overflow-wrap: anywhere">{{title}}</span>')
rep('<span style="font-size: 12px; color: #9FB0B8">389 € · ida y vuelta · ≈ 10.800 km</span>', '<span style="font-size: 12px; color: #9FB0B8">{{sub}}</span>')
rep('aria-label="Ver el mundo entero"', 'aria-label="{{worldTxt}}"')

# --- 3. El mapa: el camino de verdad (círculo máximo) y los dos aeropuertos.
rep('<path d="M176.3 49.6 Q250 4 319.8 54.6" fill="none" stroke="#3A5584" stroke-width="2" stroke-dasharray="4 5" vector-effect="non-scaling-stroke"></path>',
    '<polyline points="{{path}}" fill="none" stroke="#3A5584" stroke-width="2" stroke-dasharray="4 5" vector-effect="non-scaling-stroke"></polyline>')
rep('<path d="M176.3 49.6 Q250 4 319.8 54.6" fill="none" stroke="#6CA8FF" stroke-width="3" pathLength="1" stroke-dasharray="{{trail}}" vector-effect="non-scaling-stroke" stroke-linecap="round"></path>',
    '<polyline points="{{path}}" fill="none" stroke="#6CA8FF" stroke-width="3" pathLength="1" stroke-dasharray="{{trail}}" vector-effect="non-scaling-stroke" stroke-linecap="round" stroke-linejoin="round"></polyline>')
rep('<circle cx="176.3" cy="49.6" r="{{dotR}}" fill="#6CA8FF"></circle>', '<circle cx="{{ox}}" cy="{{oy}}" r="{{dotR}}" fill="#6CA8FF"></circle>')
rep('<circle cx="319.8" cy="54.6" r="{{dotR}}" fill="#FF8A65"></circle>', '<sc-if value="{{hasDest}}" hint-placeholder-val="{{ true }}"><circle cx="{{dx}}" cy="{{dy}}" r="{{dotR}}" fill="#FF8A65"></circle></sc-if>')
rep('aria-label="Acercar a Madrid, origen"', 'aria-label="{{oAria}}"')
rep('aria-label="Acercar a Tokio, destino" style="{{tokyoBtn}}"', 'aria-label="{{dAria}}" style="{{tokyoBtn}}"')
rep('white-space: nowrap">MAD · origen</span>', 'white-space: nowrap">{{oLbl}}</span>')
rep('white-space: nowrap">HND · destino</span>', 'white-space: nowrap">{{dLbl}}</span>')

# --- 4. Mundo: empezar (o, sin destino, elegirlo).
rep('<span style="font-family: \'Bricolage Grotesque\', sans-serif; font-size: 20px; font-weight: 800">Toca el origen para empezar</span>\n'
    '<span style="font-size: 14px; line-height: 1.5; color: #B7C5CC">Te acercamos a Madrid, te contamos qué ver y desde ahí despegas hacia Tokio siguiendo la ruta.</span>\n'
    '<button type="button" onClick="{{goOrigin}}" style="height: 50px; border-radius: 16px; border: none; background: #6CA8FF; color: #0B1217; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer">Empezar en Madrid</button>',
    '<span style="font-family: \'Bricolage Grotesque\', sans-serif; font-size: 20px; font-weight: 800">{{worldH}}</span>\n'
    '<span style="font-size: 14px; line-height: 1.5; color: #B7C5CC">{{worldP}}</span>\n'
    '<sc-if value="{{hasDest}}" hint-placeholder-val="{{ true }}"><button type="button" onClick="{{goOrigin}}" style="width: 100%; height: 50px; border-radius: 16px; border: none; background: #6CA8FF; color: #0B1217; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer">{{startTxt}}</button></sc-if>\n'
    '<button type="button" onClick="{{pick}}" style="{{pickSt}}">{{pickTxt}}</button>')

# --- 5. El vuelo: por dónde va (de verdad), cuánto lleva y cuánto queda.
rep('color: #9CC4FF">SIMULACIÓN DEL RECORRIDO</span>', 'color: #9CC4FF">{{simTxt}}</span>')
rep('font-weight: 700">Recorrido</span>', 'font-weight: 700">{{doneTxt}}</span>')
rep('font-weight: 700">Quedan</span><span style="font-size: 18px; font-weight: 800">{{leftLabel}}</span></div>\n</div>\n',
    'font-weight: 700">{{leftTxt}}</span><span style="font-size: 18px; font-weight: 800">{{leftLabel}}</span></div>\n</div>\n'
    '<button type="button" onClick="{{land}}" style="height: 46px; border-radius: 16px; border: 1px solid #2A3E63; background: transparent; color: #F2F5F3; font-family: inherit; font-size: 14px; font-weight: 700; cursor: pointer">{{landTxt}}</button>\n')

# --- 6. Origen y destino: la ficha de la ciudad (Wikipedia y Wikidata) con
# fotos de licencia libre en vez de los dibujos de ejemplo.
cut_between('<sc-if value="{{isOrigin}}" hint-placeholder-val="{{ false }}">', '</sc-if>\n<span style="font-size: 11px; color: #6F8490; text-align: center">Imágenes ilustrativas. En la app saldrán fotos reales con licencia libre.</span>',
    '<sc-if value="{{isPlace}}" hint-placeholder-val="{{ false }}">\n'
    '<div style="display: flex; flex-direction: column; gap: 12px">\n'
    '<div style="display: flex; align-items: center; gap: 12px">\n'
    '<span role="img" aria-label="{{P.country}}" style="width: 48px; height: 32px; border-radius: 6px; box-shadow: 0 3px 10px rgba(0,0,0,0.35); flex-shrink: 0; background: #141E25; display: flex; align-items: center; justify-content: center; font-size: 30px; line-height: 1; overflow: hidden">{{P.flag}}</span>\n'
    '<span style="display: flex; flex-direction: column; flex-grow: 1; min-width: 0"><span style="font-family: \'Bricolage Grotesque\', sans-serif; font-size: 24px; font-weight: 800; line-height: 1">{{P.city}}</span><span style="font-size: 13px; color: #9FB0B8">{{P.sub}}</span></span>\n'
    '<span style="{{P.tagSt}}">{{P.tag}}</span>\n'
    '</div>\n'
    '<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px">\n'
    '<sc-for list="{{P.facts}}" as="f" hint-placeholder-count="4"><div style="border-radius: 14px; background: #141E25; border: 1px solid #26363F; padding: 10px; display: flex; flex-direction: column; gap: 2px"><span style="font-size: 11px; color: #9FB0B8; font-weight: 700">{{f.k}}</span><span style="font-size: 14px; font-weight: 800">{{f.v}}</span></div></sc-for>\n'
    '</div>\n'
    '<div style="border-radius: 20px; background: #141E25; border: 1px solid #26363F; padding: 14px; display: flex; flex-direction: column; gap: 6px">\n'
    '<span style="font-size: 15px; font-weight: 800">{{whyH}}</span>\n'
    '<span style="font-size: 14px; line-height: 1.55; color: #DCE5E9">{{P.why}}</span>\n'
    '<sc-if value="{{P.hasMore}}" hint-placeholder-val="{{ true }}"><a onClick="{{P.more}}" style="cursor: pointer; font-size: 13px; font-weight: 800">{{moreTxt}}</a></sc-if>\n'
    '</div>\n'
    '<sc-if value="{{P.hasSights}}" hint-placeholder-val="{{ true }}">\n'
    '<span style="font-size: 15px; font-weight: 800; padding: 0 2px">{{sightsH}}</span>\n'
    '<div style="display: flex; gap: 8px; overflow-x: auto; padding-bottom: 4px">\n'
    '<sc-for list="{{P.sights}}" as="g" hint-placeholder-count="4"><figure onClick="{{g.open}}" style="margin: 0; flex-shrink: 0; width: 128px; display: flex; flex-direction: column; gap: 4px; cursor: pointer">\n'
    '<span role="img" aria-label="{{g.name}}" style="{{g.pic}}"></span>\n'
    '<figcaption style="font-size: 12px; font-weight: 700">{{g.name}}</figcaption>\n'
    '</figure></sc-for>\n'
    '</div>\n'
    '</sc-if>\n'
    '<sc-if value="{{isOrigin}}" hint-placeholder-val="{{ false }}">\n'
    '<button type="button" onClick="{{fly}}" style="width: 100%; height: 54px; border-radius: 18px; border: none; background: #6CA8FF; color: #0B1217; font-family: inherit; font-size: 16px; font-weight: 800; cursor: pointer; display: flex; align-items: center; justify-content: center; gap: 10px">\n'
    '<svg width="20" height="20" viewBox="0 0 24 24" fill="#0B1217" aria-hidden="true"><path d="M2 16l20-6-2-3-7 2-5-5-2 1 3 5-5 1.5-2-1.5-1.5.5z"></path></svg>\n'
    '{{flyTxt}}</button>\n'
    '<sc-if value="{{has3d}}" hint-placeholder-val="{{ true }}"><a onClick="{{fly3d}}" style="cursor: pointer; display: block; text-align: center; font-size: 13px; font-weight: 800; padding-top: 10px">{{fly3dTxt}}</a></sc-if>\n'
    '</sc-if>\n'
    '<sc-if value="{{isDest}}" hint-placeholder-val="{{ false }}">\n'
    '<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px">\n'
    '<button type="button" onClick="{{replayFlight}}" style="height: 50px; border-radius: 16px; border: none; background: #FF8A65; color: #0B1217; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer">{{replayTxt}}</button>\n'
    '<button type="button" onClick="{{goOrigin}}" style="height: 50px; border-radius: 16px; border: 1px solid #33444E; background: transparent; color: #F2F5F3; font-family: inherit; font-size: 14px; font-weight: 700; cursor: pointer">{{backOriginTxt}}</button>\n'
    '</div>\n'
    '</sc-if>\n'
    '</div>\n'
    '</sc-if>\n'
    '<span style="font-size: 11px; line-height: 1.5; color: #6F8490; text-align: center">{{credits}}</span>')

# --- 7. La lógica: la de la maqueta con tu ruta (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('class Component'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Madrid', 'Tokio', 'Japón', 'HND', '389 €', 'Prado', 'Shibuya', '.dc.html', 'ilustrativas'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
