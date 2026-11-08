# Crea assets/cards/cromos.html a partir de la maqueta "Cromos con amigos".
# Uso:
#   python3 tool/cromos/build_page.py <Cromos.dc.html> <support.js> assets/cards/cromos.html
#
# Se queda TODO lo de la maqueta (las 3 pestañas, los dos móviles que se
# acercan al cambiar, la clasificación y el mapa de amigos) y solo se quitan
# los datos de ejemplo. Lo de verdad lo pone la app (lib/features/cards/
# cards_page.dart) en la marca /*ECLIPTA*/ y lo que llega después entra con
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


# --- 1. El motor de la maqueta va dentro (sin Internet).
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
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;')

# --- 2. Volver: a la pantalla de antes.
rep('<a href="Pasaporte.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')

# --- 3. Cambiar: tus cromos y los de tus amigos (tocar un móvil = otro).
card = ('<div style="{{%(c)s.box}}"><svg width="40" height="40" viewBox="0 0 40 40" aria-hidden="true">%(svg)s</svg>'
        '<span style="{{%(c)s.txt}}">{{%(c)s.name}}</span></div><span style="{{%(c)s.lab}}">{{%(c)s.label}}</span>')
m = re.search(r'<div style="\{\{phoneL\}\}">.*?</div><span style="font-size: 10px; font-weight: 800; color: #FFD36B">RARA · x2</span></div>', s)
assert m
svgL = re.search(r'<svg width="40" height="40" viewBox="0 0 40 40" aria-hidden="true">(.*?)</svg>', m.group(0)).group(1)
svgL = svgL.replace('fill="#7A3E10"', 'fill="{{cL.ink}}"').replace('stroke="#FFD36B"', 'stroke="#FFFFFF66"')
s = s[:m.start()] + ('<div onClick="{{nextSw}}" style="{{phoneL}}"><span style="font-size: 10px; font-weight: 800; color: #9FB0B8">{{whoL}}</span>'
                     + card % {'c': 'cL', 'svg': svgL} + '</div>') + s[m.end():]
m = re.search(r'<div style="\{\{phoneR\}\}">.*?</div><span style="font-size: 10px; font-weight: 800; color: #E3D8FF">LEGENDARIA</span></div>', s)
assert m
svgR = re.search(r'<svg width="40" height="40" viewBox="0 0 40 40" aria-hidden="true">(.*?)</svg>', m.group(0)).group(1)
svgR = svgR.replace('stroke="#2A1870"', 'stroke="{{cR.ink}}"')
s = s[:m.start()] + ('<div onClick="{{nextSw}}" style="{{phoneR}}"><span style="font-size: 10px; font-weight: 800; color: #9FB0B8">{{whoR}}</span>'
                     + card % {'c': 'cR', 'svg': svgR} + '</div>') + s[m.end():]
rep('>Junta los móviles (NFC) o acércalos por Bluetooth. Solo se cambian repetidas, nunca pierdes una única.<', '>{{swapText}}<')
rep('<button type="button" onClick="{{doSwap}}" style="{{swapBtn}}">{{swapLabel}}</button>',
    '<button type="button" onClick="{{doSwap}}" style="{{swapBtn}}">{{swapLabel}}</button>'
    '<sc-if value="{{hasAlt}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{doAlt}}" style="height: 36px; border-radius: 12px; border: none; background: transparent; color: #9FB0B8; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer">{{altLabel}}</button></sc-if>')

# --- 4. Liga: tu clasificación de verdad (tocar el cartel = opciones).
rep('<div style="border-radius: 24px; background: linear-gradient(160deg, #2A2140, #141E25); border: 1px solid #3A3156; padding: 14px; display: flex; align-items: center; gap: 12px">',
    '<div onClick="{{openLeague}}" style="cursor: pointer; border-radius: 24px; background: linear-gradient(160deg, #2A2140, #141E25); border: 1px solid #3A3156; padding: 14px; display: flex; align-items: center; gap: 12px">')
rep('>LIGA EXPLORADORES · OCTUBRE<', '>{{headK}}<')
rep('>Vas 2.º de 6<', '>{{headPos}}<')
rep('>Te faltan 140 puntos para Noelia<', '>{{headSub}}<')
rep('>Puntos: cromo común 10, rara 40, legendaria 150. Pasos andados y barrios nuevos suman.<', '>{{pointsNote}}<')

# --- 5. Amigos: solo quien comparte su ciudad contigo.
a = s.find('<div style="position: relative; height: 380px; border-radius: 24px;')
b = s.find('<span style="font-size: 12px; color: #9FB0B8; padding: 0 4px">Solo ves a quien comparte contigo')
s = (s[:a] + '<sc-if value="{{hasFriends}}" hint-placeholder-val="{{ true }}">' + s[a:b] + '</sc-if>'
     '<sc-if value="{{noFriends}}" hint-placeholder-val="{{ false }}"><div style="border-radius: 20px; background: #141E25; border: 1px solid #26363F; padding: 12px 14px; font-size: 13px; color: #DCE5E9">{{friendsNote}}</div></sc-if>' + s[b:])
rep('<span style="font-size: 12px; color: #9FB0B8; padding: 0 4px">Solo ves a quien comparte contigo, y la ubicación es aproximada (barrio) salvo que te den permiso exacto.</span>',
    '<span onClick="{{share}}" style="cursor: pointer; font-size: 12px; color: #9FB0B8; padding: 0 4px">{{shareNote}}</span>')

# --- 6. La lógica: la de la maqueta, con tus datos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
s = s[:a] + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('</head>'):].lower()
for bad in ('ejemplo', '.dc.html', 'noelia', 'fushimi', 'tokio'):
    assert bad not in low, (bad, low[max(0, low.find(bad) - 200):low.find(bad) + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
