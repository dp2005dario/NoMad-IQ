# Crea assets/drive/coche.html a partir de la maqueta "Coche" (Modo coche).
# Uso:
#   python3 tool/coche/build_page.py <Coche.dc.html> <support.js> assets/drive/coche.html
#
# Se queda TODO lo de la maqueta (la pantalla del coche inclinada con su
# reloj, el mapa, la flecha del giro y la tarjeta de abajo; los cuatro
# botones y la barra de voz con su micro que late). Solo se quitan los datos
# de ejemplo (Amalfi, Positano, precios inventados): la app pone lo que hay
# cerca de verdad en la marca /*ECLIPTA*/ (lib/features/drive/drive_page.dart)
# y manda lo nuevo con window.ECLin.
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
s = s[:i] + '<title>ECLIPTA · Modo coche</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;')

# --- 2. Arriba: volver, el título y dónde estás.
rep('<a href="Inicio.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')
rep('font-size: 24px; font-weight: 800">Modo coche</span>', 'font-size: 24px; font-weight: 800">{{title}}</span>')
rep('<span style="font-size: 12px; color: #9FB0B8">Android Auto · ruta por la costa de Amalfi</span>',
    '<span style="font-size: 12px; color: #9FB0B8">{{sub}}</span>')

# --- 3. La tarjeta: sin botón cuando no hay nada que hacer.
rep('<button type="button" onClick="{{cardGo}}" style="height: 30px;', '<button type="button" onClick="{{cardGo}}" style="{{btnSt}}height: 30px;')

# --- 4. La barra de voz: tocándola se enciende o se apaga la voz.
rep('<div style="border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 12px 14px; display: flex; gap: 10px; align-items: center">',
    '<div onClick="{{voiceTap}}" style="cursor: pointer; border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 12px 14px; display: flex; gap: 10px; align-items: center">')

# --- 5. La lógica: la de la maqueta con tus datos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('const ARROWS'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Amalfi', 'Positano', 'Mandara', '17:42', '.dc.html', '1,82'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
