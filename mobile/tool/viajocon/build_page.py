# Crea assets/travel_with/viajocon.html a partir de la maqueta "ViajoCon".
# Uso:
#   python3 tool/viajocon/build_page.py <ViajoCon.dc.html> <support.js> assets/travel_with/viajocon.html
#
# Se queda TODO lo de la maqueta: la foto en el círculo que respira con su
# anillo, las huellas que saltan, los corazones, el nombre, el pasaporte con
# sellos, el mapa con sus marcas que laten, la maleta y "En el avión". Los
# datos son los tuyos: la foto y el nombre de tu perro (solo en el móvil),
# tus casillas, los veterinarios, parques y hoteles DE VERDAD cerca de ti
# (OpenStreetMap) y lo que pesa con el transportín. La app los pone en la
# marca /*ECLIPTA*/ (lib/features/travel_with/travel_with_page.dart).
#
# Fuera: "7 kg con transportín" y "Viaje a Madrid" de ejemplo y el enlace a
# la otra maqueta del mapa.
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

rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}\n'
    '.vc-kg{width:64px;height:38px;box-sizing:border-box;border-radius:12px;border:1px solid #33444E;background:#10181E;color:#F2F5F3;font-family:inherit;font-size:15px;font-weight:800;text-align:center;outline:none;padding:0 6px}\n'
    '.vc-kg::placeholder{color:#6F8490}')
rep('<div style="{{rootSt}}">', '<div id="q-root" style="{{rootSt}}">')

# --- 2. Arriba: volver.
rep('<a href="Inicio.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="{{backTxt}}" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Viajo con mi perro</span>', 'letter-spacing: -0.02em">{{title}}</span>')

# --- 3. La foto la elige la app (cámara o galería) y la guarda en el móvil.
rep('<input type="file" accept="image/*" onChange="{{pickPhoto}}" style="position: absolute; width: 1px; height: 1px; opacity: 0; pointer-events: none">', '', 2)
rep('<label style="{{photoSt}}" aria-label="Poner la foto de tu perro">', '<label onClick="{{pickPhoto}}" style="{{photoSt}}" aria-label="{{photoAria}}">')
rep('cursor: pointer; box-shadow: 0 6px 16px rgba(0,0,0,.4)" aria-label="Elegir foto">', 'cursor: pointer; box-shadow: 0 6px 16px rgba(0,0,0,.4)" onClick="{{pickPhoto}}" aria-label="{{photoAria}}">')
rep('placeholder="Nombre de tu perro" aria-label="Nombre de tu perro"', 'maxlength="30" placeholder="{{nameHint}}" aria-label="{{nameHint}}"')
rep('onChange="{{setName}}" maxlength="18" ', 'onChange="{{setName}}" ')
rep('padding: 0 12px; cursor: pointer">Quitar foto</button>', 'padding: 0 12px; cursor: pointer">{{removeTxt}}</button>')

# --- 4. El pasaporte para la UE: las casillas se guardan en el móvil.
rep('<span style="font-size: 10.5px; color: #7FE8B9">FUENTE · Normas de la UE para viajar con mascotas (web oficial Your Europe)</span>',
    '<span style="font-size: 10.5px; color: #7FE8B9">{{source}}</span><span style="font-size: 11px; line-height: 1.45; color: #9FB0B8">{{outsideEu}}</span>')

# --- 5. Veterinarios, parques y hoteles DE VERDAD cerca de ti (OpenStreetMap).
a = s.find('<a href="https://claude.ai/artifact/')
b = s.find('>', a) + 1
assert a > 0
s = s[:a] + '<div style="display: block; position: relative; border-radius: 24px; overflow: hidden; border: 1px solid #26363F; color: inherit; background: #141E25; flex-shrink: 0; animation: vc-in .5s ease .15s both">' + s[b:]
a = s.find('<img src="data:image/', s.find('<div style="position: relative; height: 200px; overflow: hidden">'))
b = s.find('alt="Mapa 3D de la zona" style="position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; animation: vc-pan 14s ease-in-out infinite alternate">', a)
assert a > 0 and b > a
s = s[:a] + '<div style="{{mapSt}}"><sc-for list="{{tiles}}" as="m" hint-placeholder-count="0"><span style="{{m}}"></span></sc-for></div><sc-if value="{{hasMe}}" hint-placeholder-val="{{ false }}"><span style="{{meSt}}"></span></sc-if>' + s[b + len('alt="Mapa 3D de la zona" style="position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; animation: vc-pan 14s ease-in-out infinite alternate">'):]
rep('animation: vc-walk 1.2s ease-in-out infinite"></span>Mapa 3D · cerca de tu hotel</span>', 'animation: vc-walk 1.2s ease-in-out infinite"></span>{{mapLabel}}</span>')
rep('font-size: 19px; font-weight: 800">Veterinarios, parques y hoteles</span>', 'font-size: 19px; font-weight: 800">{{nearH}}</span>')
rep('<sc-for list="{{mcats}}" as="c" hint-placeholder-count="3"><span style="{{c.st}}"><img src="{{c.img}}" alt="" style="width: 20px; height: 20px">{{c.t}}</span></sc-for>',
    '<sc-for list="{{mcats}}" as="c" hint-placeholder-count="3"><button type="button" onClick="{{c.pick}}" aria-pressed="{{c.on}}" style="{{c.st}}"><img src="{{c.img}}" alt="" style="width: 20px; height: 20px">{{c.t}}</button></sc-for>')
old = '<span style="height: 48px; border-radius: 15px; background: linear-gradient(90deg, #FFB86B, #FF8A65); color: #1A1206; font-size: 14px; font-weight: 800; display: flex; align-items: center; justify-content: center; gap: 8px; box-shadow: 0 10px 24px rgba(255,138,101,.35)">Abrir el mapa y llevarme andando<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"></path></svg></span>\n</div>\n</a>'
new = ('<sc-if value="{{hasMsg}}" hint-placeholder-val="{{ false }}"><span style="font-size: 12.5px; line-height: 1.45; color: #B9C6CC">{{nearMsg}}</span></sc-if>'
       '<sc-if value="{{canRetry}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{retry}}" style="height: 38px; border-radius: 12px; border: 1px solid #33444E; background: transparent; color: #DCE5E9; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer">{{retryTxt}}</button></sc-if>'
       '<sc-for list="{{spots}}" as="p" hint-placeholder-count="0"><div style="display: flex; align-items: center; gap: 10px; min-height: 52px; border-radius: 14px; padding: 6px 8px 6px 12px; background: #10181E; border: 1px solid #26363F; animation: vc-in .4s ease both"><span style="display: flex; flex-direction: column; gap: 2px; flex: 1; min-width: 0"><span style="font-size: 13.5px; font-weight: 800; overflow: hidden; text-overflow: ellipsis; white-space: nowrap">{{p.name}}</span><span style="font-size: 11px; color: #9FB0B8">{{p.sub}}</span></span>'
       '<sc-if value="{{p.hasPhone}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{p.call}}" aria-label="{{p.callTxt}}" style="width: 36px; height: 36px; border-radius: 12px; border: 1px solid #33444E; background: transparent; color: #DCE5E9; cursor: pointer; display: flex; align-items: center; justify-content: center; flex-shrink: 0"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"></path></svg></button></sc-if>'
       '<sc-if value="{{p.hasWeb}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{p.web}}" aria-label="{{p.webTxt}}" style="width: 36px; height: 36px; border-radius: 12px; border: 1px solid #33444E; background: transparent; color: #DCE5E9; cursor: pointer; display: flex; align-items: center; justify-content: center; flex-shrink: 0"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"></circle><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"></path></svg></button></sc-if>'
       '<button type="button" onClick="{{p.go}}" aria-label="{{p.goTxt}}" style="height: 36px; border-radius: 12px; border: none; background: #FFB86B; color: #1A1206; font-family: inherit; font-size: 12.5px; font-weight: 800; padding: 0 12px; cursor: pointer; flex-shrink: 0">{{p.goTxt}}</button></div></sc-for>'
       '<sc-if value="{{canGo}}" hint-placeholder-val="{{ true }}"><button type="button" onClick="{{goNear}}" style="height: 48px; border-radius: 15px; border: none; background: linear-gradient(90deg, #FFB86B, #FF8A65); color: #1A1206; font-family: inherit; font-size: 14px; font-weight: 800; display: flex; align-items: center; justify-content: center; gap: 8px; cursor: pointer; box-shadow: 0 10px 24px rgba(255,138,101,.35)">{{goNearTxt}}<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"></path></svg></button></sc-if>'
       '<sc-if value="{{hasAttr}}" hint-placeholder-val="{{ false }}"><span style="font-size: 10.5px; color: #6F828C">{{attr}}</span></sc-if>'
       '\n</div>\n</div>')
rep(old, new)

# --- 6. La maleta (se guarda en el móvil).
rep('<span style="font-size: 15px; font-weight: 800">Maleta de {{who}}</span>', '<span style="font-size: 15px; font-weight: 800">{{bagH}}</span>')
rep('animation: vc-pop .5s cubic-bezier(.2,.9,.3,1.3) both">¡{{Who}} lo tiene todo! 🐾</span>', 'animation: vc-pop .5s cubic-bezier(.2,.9,.3,1.3) both">{{bagFullTxt}}</span>')
rep('<span style="font-size: 15px; font-weight: 800">Pasaporte de {{who}} para la UE</span>', '<span style="font-size: 15px; font-weight: 800">{{petH}}</span>')

# --- 7. En el avión: con lo que pesa, si va en cabina o en bodega.
old = '<span style="display: flex; flex-direction: column; gap: 2px"><span style="font-size: 11px; font-weight: 800; letter-spacing: .05em; color: #6CA8FF">EN EL AVIÓN</span><span style="font-size: 13px; font-weight: 700; line-height: 1.35">En cabina suelen dejar hasta unos 8 kg con transportín. Cada aerolínea tiene su norma: Flyra te enlaza la tuya.</span></span></div>'
new = ('<span style="display: flex; flex-direction: column; gap: 2px"><span style="font-size: 11px; font-weight: 800; letter-spacing: .05em; color: #6CA8FF">{{planeH}}</span><span style="font-size: 13px; font-weight: 700; line-height: 1.35">{{planeP}}</span></span></div>\n'
       '<div style="border-radius: 20px; background: #141E25; border: 1px solid #26363F; padding: 12px; display: flex; flex-direction: column; gap: 10px; flex-shrink: 0; animation: vc-in .5s ease .3s both">'
       '<div style="display: flex; align-items: center; gap: 8px"><span style="flex: 1; font-size: 12.5px; font-weight: 800; color: #B7C5CC">{{petKgTxt}}</span><input class="vc-kg" type="text" inputmode="decimal" value="{{petKg}}" onInput="{{setPetKg}}" aria-label="{{petKgTxt}}" placeholder="0"></div>'
       '<div style="display: flex; align-items: center; gap: 8px"><span style="flex: 1; font-size: 12.5px; font-weight: 800; color: #B7C5CC">{{carrierKgTxt}}</span><input class="vc-kg" type="text" inputmode="decimal" value="{{carrierKg}}" onInput="{{setCarrierKg}}" aria-label="{{carrierKgTxt}}" placeholder="0"></div>'
       '<sc-if value="{{hasVerdict}}" hint-placeholder-val="{{ false }}"><div style="{{verdictSt}}"><span style="font-size: 14px; font-weight: 800">{{verdictH}}</span><span style="font-size: 12px; line-height: 1.4; color: #DCE5E9">{{verdictP}}</span></div></sc-if>'
       '<span style="font-size: 10.5px; line-height: 1.45; color: #6F828C">{{disclaimer}}</span></div>')
rep(old, new)

# --- 8. La lógica: la de la maqueta con tus datos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('// ----'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Madrid', '7 kg', 'claude.ai', '.dc.html', 'Mapa 3D', 'type="file"'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
