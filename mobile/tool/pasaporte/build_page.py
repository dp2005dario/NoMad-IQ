# Crea assets/passport/pasaporte.html a partir de la maqueta "Pasaporte".
# Uso:
#   python3 tool/pasaporte/build_page.py <Pasaporte.dc.html> <support.js> assets/passport/pasaporte.html
#
# Se queda TODO lo de la maqueta (la tapa que flota y se abre girando, las
# páginas de papel que pasan como un libro, los cromos con su brillo
# holográfico y la ficha grande de cada cromo). Solo se quitan los cromos de
# ejemplo (Madrid, Tokio, Lisboa, Roma): la app pone tus sellos de verdad en
# la marca /*ECLIPTA*/ (lib/features/passport/passport_page.dart).
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
i = s.find('<title>')
s = s[:i] + '<title>ECLIPTA · Mi pasaporte</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(circle at 50% 30%',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(circle at 50% 30%')

# --- 2. Arriba: volver, el título, cuántos cromos y "Recuerdos".
rep('<a href="Inicio.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Mi pasaporte</span>', 'letter-spacing: -0.02em">{{title}}</span>')
rep('<span style="font-size: 12px; color: #9FB0B8">Nivel 4 · {{totalLabel}}</span>', '<span style="font-size: 12px; color: #9FB0B8">{{totalLabel}}</span>')
rep('<a href="Recuerdos.dc.html" aria-label="Ver recuerdos del viaje" style="', '<a onClick="{{memories}}" aria-label="Ver recuerdos del viaje" style="cursor: pointer; ')
rep('font-size: 12px; font-weight: 800">Recuerdos</a>', 'font-size: 12px; font-weight: 800">{{memTxt}}</a>')

# --- 3. La tapa: con tu nombre.
rep('color: #E6C478">NOMADIQ</span>', 'color: #E6C478">ECLIPTA</span>')
rep('letter-spacing: 0.12em; color: #E6C478">PASAPORTE</span>', 'letter-spacing: 0.12em; color: #E6C478">{{cov1}}</span>')
rep('letter-spacing: 0.25em; color: #CDB27A">DE VIAJE · DARIO</span>', 'letter-spacing: 0.25em; color: #CDB27A">{{cov2}}</span>')
rep('white-space: nowrap">Toca para abrir</span>', 'white-space: nowrap">{{tapOpen}}</span>')

# --- 4. Las banderas: la de cada país de verdad (la del móvil, sirve para
# todos los países del mundo).
rep('<svg width="62" height="42" viewBox="0 0 62 42" aria-hidden="true"><path d="{{p.flagA}}" fill="{{p.colA}}"></path><path d="{{p.flagB}}" fill="{{p.colB}}"></path><path d="{{p.flagC}}" fill="{{p.colC}}"></path></svg>',
    '<span aria-hidden="true" style="display: flex; width: 62px; height: 42px; align-items: center; justify-content: center; font-size: 46px; line-height: 1; background: #E9DCC0">{{p.flag}}</span>')
rep('<svg width="30" height="20" viewBox="0 0 62 42" aria-hidden="true" style="border-radius: 3px"><path d="{{t.flagA}}" fill="{{t.colA}}"></path><path d="{{t.flagB}}" fill="{{t.colB}}"></path><path d="{{t.flagC}}" fill="{{t.colC}}"></path></svg>',
    '<span aria-hidden="true" style="font-size: 20px; line-height: 20px; height: 20px">{{t.flag}}</span>')

# Con muchos países, las pestañas se deslizan.
rep('<div role="tablist" aria-label="Países" style="display: flex; gap: 6px; justify-content: center">',
    '<div role="tablist" aria-label="Países" style="display: flex; gap: 6px; justify-content: safe center; overflow-x: auto; scrollbar-width: none">')

# --- 5. Sin sellos todavía: lo dice y lleva a la cámara.
rep('</sc-for>\n</div>\n<div style="position: relative; margin-top: auto;',
    '</sc-for>\n</div>\n<sc-if value="{{p.empty}}" hint-placeholder-val="{{ false }}"><div style="position: relative; display: flex; flex-direction: column; gap: 14px; align-items: center; text-align: center; padding: 30px 6px 0 6px"><span style="font-size: 15px; line-height: 1.5; color: #4A3B2A">{{p.emptyTxt}}</span><button type="button" onClick="{{p.camera}}" style="height: 48px; padding: 0 22px; border-radius: 16px; border: none; background: #2F8F6B; color: #FFFFFF; font-family: inherit; font-size: 14px; font-weight: 800; cursor: pointer">{{p.cameraTxt}}</button></div></sc-if>\n'
    '<div style="position: relative; margin-top: auto;')

# --- 6. La ficha del cromo: escucharlo (la voz del móvil) y verlo en el mapa.
rep('<a href="Audioguia.dc.html" style="height: 48px;', '<a onClick="{{cListen}}" style="cursor: pointer; height: 48px;')
rep('<a href="Mapa.dc.html" style="height: 48px;', '<a onClick="{{cMap}}" style="{{cMapSt}}cursor: pointer; height: 48px;')
rep('justify-content: center">Ver en el mapa</a>', 'justify-content: center">{{mapTxt}}</a>')

# --- 7. La lógica: la de la maqueta con tus sellos (logic.js). Se quedan
# los dibujos de los monumentos (IC y DET).
a = s.find('const IC = {')
b = s.find('};', s.find('const DET = {')) + 2
icons = s[a:b]
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('class Component'):].replace('/*ICONS*/', icons) + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Puerta del Sol', 'Tokio', 'Lisboa', 'DARIO', '.dc.html', 'Nivel 4', 'NOMADIQ'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
