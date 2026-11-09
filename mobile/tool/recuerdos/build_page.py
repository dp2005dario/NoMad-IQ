# Crea assets/memories/recuerdos.html a partir de la maqueta "Recuerdos".
# Uso:
#   python3 tool/recuerdos/build_page.py <Recuerdos.dc.html> <support.js> assets/memories/recuerdos.html
#
# Se queda TODO lo de la maqueta: la historia que pasa sola (portada con el
# globo y el avión que vuela tu ruta, las fotos con zoom lento y las cifras),
# las rayitas de arriba, pausa, los estilos Cine / Viñetas / Rápido, "Crear
# historia" con su degradado, "Guardar vídeo" y "Enviar al grupo".
#
# En vez de los dibujos de ejemplo (cerezos, Shibuya) salen TUS fotos, con
# "DÍA N · CIUDAD" de verdad. Debajo siguen tus recuerdos (lo que ya tenía la
# app): la cuadrícula de fotos y vídeos, la cámara de viaje y el día en que
# empezó el viaje, con el mismo estilo.
#
# El vídeo se monta DENTRO del móvil: la página dibuja la historia en un
# lienzo y lo graba (MediaRecorder, gratis y sin servidor). La app lo guarda
# o lo comparte (lib/features/memories/memories_screen.dart).
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
s = s[:i] + '<title>ECLIPTA · Recuerdos</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
# Con tus recuerdos debajo, la página se desliza.
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217; font-family: \'Manrope\', system-ui, sans-serif; color: #F2F5F3; position: relative; overflow: hidden;',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217; font-family: \'Manrope\', system-ui, sans-serif; color: #F2F5F3; position: relative; overflow-x: hidden; overflow-y: auto; scrollbar-width: none;')

# --- 2. Arriba: volver y los textos en tu idioma.
rep('<a href="Pasaporte.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="{{backTxt}}" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Tu viaje en 30 s</span>', 'letter-spacing: -0.02em">{{title}}</span>')
rep('<span style="font-size: 12px; color: #9FB0B8">Lo montamos solos con tus fotos, la ruta y los sellos</span>',
    '<span style="font-size: 12px; color: #9FB0B8">{{sub}}</span>')

# --- 3. La historia. Tocarla la abre a pantalla completa.
rep('<div role="img" aria-label="{{slideAria}}" style="height: 470px;',
    '<div role="img" aria-label="{{slideAria}}" onClick="{{full}}" style="cursor: pointer; height: 470px;')
# Portada: tu ruta (primera y última ciudad) y tus fechas. El avión y la
# línea vuelven a salir cada vez que se ve la portada.
rep('stroke-dasharray="520" style="animation: nq-draw 2.2s ease both"', 'stroke-dasharray="520" style="{{drawSt}}"')
rep('offset-rotate: auto; animation: nq-fly 2.2s ease both"', 'offset-rotate: auto; {{flySt}}"')
# Los nombres de las ciudades van encima del dibujo (en texto normal: el
# motor de la maqueta no sabe poner datos dentro de un <text> de SVG).
rep('<text x="70" y="258" fill="#F2F5F3" font-family="Manrope, sans-serif" font-size="14" font-weight="800">Madrid</text>\n', '')
rep('<text x="272" y="238" fill="#FFB86B" font-family="Manrope, sans-serif" font-size="14" font-weight="800">Tokio</text>\n', '')
rep('fill="#FFFFFF"></path></g>\n</svg>\n',
    'fill="#FFFFFF"></path></g>\n</svg>\n'
    '<span style="position: absolute; left: 70px; top: 245px; font-size: 14px; font-weight: 800; color: #F2F5F3; white-space: nowrap">{{from}}</span>\n'
    '<span style="position: absolute; right: 40px; top: 225px; font-size: 14px; font-weight: 800; color: #FFB86B; white-space: nowrap">{{to}}</span>\n')
rep('<div style="position: absolute; left: 20px; right: 20px; bottom: 26px; display: flex; flex-direction: column; gap: 2px; animation: nq-up 0.6s ease 0.4s both">',
    '<div style="position: absolute; left: 20px; right: 20px; bottom: 26px; display: flex; flex-direction: column; gap: 2px; {{upSt}}">')
rep('color: #FFB86B">3 — 12 MARZO 2027</span>', 'color: #FFB86B">{{dates}}</span>')
rep('line-height: 1">Madrid → Tokio</span>', 'line-height: 1; overflow-wrap: anywhere">{{route}}</span>')
# Las dos escenas dibujadas de ejemplo → tus fotos, una por escena.
cut_between('<div style="{{s1}}">', '<div style="{{s3}}">',
    '<sc-for list="{{shots}}" as="p" hint-placeholder-count="2">\n'
    '<div style="{{p.show}}">\n'
    '<div style="{{p.frame}}"><img src="{{p.src}}" alt="" style="{{p.img}}"></div>\n'
    '<div style="{{p.capBox}}">\n'
    '<span style="{{p.lblSt}}">{{p.lbl}}</span>\n'
    '<span style="{{p.subSt}}">{{p.sub}}</span>\n'
    '</div>\n'
    '</div>\n'
    '</sc-for>\n\n'
    '<div style="{{s3}}">')
rep('<button type="button" onClick="{{toggle}}" aria-label="{{playLabel}}"', '<button type="button" onClick="{{toggle}}" aria-label="{{playLabel}}"')

# --- 4. Estilos y botones.
rep('<div role="group" aria-label="Estilo del vídeo" style="display: flex; gap: 6px">', '<div role="group" aria-label="{{stylesTxt}}" style="display: flex; gap: 6px; flex-shrink: 0">')
rep('<button type="button" style="height: 60px; border-radius: 20px; border: none; background: linear-gradient(100deg,',
    '<button type="button" onClick="{{story}}" style="flex-shrink: 0; height: 60px; border-radius: 20px; border: none; background: linear-gradient(100deg,')
rep('<span style="font-size: 16px; font-weight: 800">Crear historia</span><span style="font-size: 12px; font-weight: 600; opacity: 0.9">Allí le pones la música que quieras</span>',
    '<span style="font-size: 16px; font-weight: 800">{{storyTxt}}</span><span style="font-size: 12px; font-weight: 600; opacity: 0.9">{{storySub}}</span>')
rep('<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px">\n'
    '<button type="button" style="height: 46px;',
    '<div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; flex-shrink: 0">\n'
    '<button type="button" onClick="{{save}}" style="height: 46px;')
rep('cursor: pointer">Guardar vídeo</button>', 'cursor: pointer">{{saveTxt}}</button>')
rep('<a href="Grupo.dc.html" style="height: 46px;', '<a onClick="{{group}}" style="cursor: pointer; height: 46px;')
rep('align-items: center; justify-content: center">Enviar al grupo</a>\n</div>\n</div>\n</x-dc>',
    'align-items: center; justify-content: center">{{groupTxt}}</a>\n</div>\n'
    # Tus recuerdos (lo que ya tenía la app), con el estilo de la maqueta.
    '<div style="display: flex; align-items: center; gap: 10px; padding-top: 8px; flex-shrink: 0">\n'
    '<span style="display: flex; flex-direction: column; flex-grow: 1; min-width: 0"><span style="font-size: 15px; font-weight: 800">{{listH}}</span>'
    '<span style="font-size: 11px; line-height: 1.4; color: #9FB0B8">{{onlyHere}}</span></span>\n'
    '<button type="button" onClick="{{camera}}" aria-label="{{cameraTxt}}" style="width: 44px; height: 44px; flex-shrink: 0; border-radius: 22px; border: none; background: {{accent}}; display: flex; align-items: center; justify-content: center; cursor: pointer">'
    '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#0B1217" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 8h3l2-3h6l2 3h3v11H4z"></path><circle cx="12" cy="13" r="3.5"></circle></svg></button>\n'
    '</div>\n'
    '<button type="button" onClick="{{start}}" style="align-self: flex-start; flex-shrink: 0; height: 34px; border-radius: 12px; border: 1px solid #26363F; background: #141E25; color: #F2F5F3; font-family: inherit; font-size: 12px; font-weight: 700; padding: 0 12px; display: flex; align-items: center; gap: 6px; cursor: pointer">'
    '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#9FB0B8" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="5" width="16" height="15" rx="3"></rect><path d="M4 10h16M9 3v4M15 3v4"></path></svg>{{startTxt}}</button>\n'
    '<sc-if value="{{empty}}" hint-placeholder-val="{{ false }}"><span style="font-size: 13px; line-height: 1.5; color: #9FB0B8; text-align: center; padding: 12px 8px; flex-shrink: 0">{{emptyTxt}}</span></sc-if>\n'
    '<div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 6px; flex-shrink: 0">\n'
    '<sc-for list="{{grid}}" as="m" hint-placeholder-count="3"><button type="button" onClick="{{m.open}}" aria-label="{{m.label}}" style="{{m.style}}">'
    '<sc-if value="{{m.video}}" hint-placeholder-val="{{ false }}"><svg width="30" height="30" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="11" fill="rgba(11,18,23,0.6)"></circle><path d="M10 8v8l6-4z" fill="#F2F5F3"></path></svg></sc-if></button></sc-for>\n'
    '</div>\n'
    '</div>\n</x-dc>')

# --- 5. La lógica: la de la maqueta con tus recuerdos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('class Component'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Madrid', 'Tokio', 'MARZO', 'Meiji', 'SHIBUYA', 'cerezos', '21.500', '.dc.html'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
