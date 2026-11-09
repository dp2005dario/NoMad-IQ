# Crea assets/visa/visado.html a partir de la maqueta "Visado".
# Uso:
#   python3 tool/visado/build_page.py <Visado.dc.html> <support.js> assets/visa/visado.html
#
# Se queda TODO lo de la maqueta: las tres rayitas de los pasos, el
# pasaporte con sus ondas, la lista de datos con de dónde sale cada uno, la
# tarjeta de "lista para enviar" y el bocadillo de Flyra. Los datos son los
# tuyos: tu pasaporte y tu destino (los eliges arriba), lo que te piden de
# verdad (tabla de passportindex.org dentro de la app) y los datos leídos de
# la foto de tu pasaporte en la Bóveda. La app los pone en la marca
# /*ECLIPTA*/ (lib/features/visa/visa_page.dart).
#
# Fuera: "Nueva York", los datos de ejemplo ("Dario", "Mamá"...), el texto
# de las 2 preguntas y "PROBAR AVISO" (Flyra sale cuando no se puede leer
# tu pasaporte).
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
    '.vz-scroll{scrollbar-width:none}.vz-scroll::-webkit-scrollbar{display:none}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;', '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;')

# --- 2. Arriba.
rep('<a href="Inicio.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="{{backTxt}}" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Pedir el ESTA</span>', 'letter-spacing: -0.02em">{{title}}</span>')
rep('<span style="font-size: 12px; color: #9FB0B8">Nueva York · lo rellenamos con tu Bóveda</span>', '<span style="font-size: 12px; color: #9FB0B8">{{sub}}</span>')

# --- 3. Tu pasaporte → destino (los eliges tú) y lo que te piden.
chips = ('<div style="display: flex; align-items: center; gap: 8px; flex-shrink: 0">'
         '<button type="button" onClick="{{pickFrom}}" aria-label="{{fromAria}}" style="{{pillSt}}"><span style="font-size: 10px; font-weight: 800; letter-spacing: 0.06em; color: #9FB0B8">{{fromH}}</span><span style="font-size: 14px; font-weight: 800; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{fromTxt}}</span></button>'
         '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#6CA8FF" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex-shrink: 0"><path d="M5 12h14M13 6l6 6-6 6"></path></svg>'
         '<button type="button" onClick="{{pickTo}}" aria-label="{{toAria}}" style="{{pillSt}}"><span style="font-size: 10px; font-weight: 800; letter-spacing: 0.06em; color: #9FB0B8">{{toH}}</span><span style="font-size: 14px; font-weight: 800; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{toTxt}}</span></button></div>'
         '<sc-if value="{{hasVerdict}}" hint-placeholder-val="{{ true }}"><div style="{{verdictSt}}"><span style="display: flex; justify-content: space-between; align-items: baseline; gap: 8px"><span style="font-size: 15px; font-weight: 800">{{verdictH}}</span><span style="font-size: 12px; font-weight: 800; white-space: nowrap">{{verdictDays}}</span></span><span style="font-size: 12px; line-height: 1.45; color: #CFDAE0">{{verdictP}}</span><span style="font-size: 10px; line-height: 1.4; color: #7F939D">{{source}}</span></div></sc-if>'
         '<sc-if value="{{hasNote}}" hint-placeholder-val="{{ false }}"><span style="font-size: 13px; line-height: 1.5; color: #9FB0B8; flex-shrink: 0">{{note}}</span></sc-if>\n')
rep('<div style="display: flex; gap: 6px">\n<sc-for list="{{steps}}"', chips + '<sc-if value="{{apply}}" hint-placeholder-val="{{ true }}"><div style="display: flex; gap: 6px; flex-shrink: 0">\n<sc-for list="{{steps}}"')
rep('<span style="{{s.label}}">{{s.text}}</span></span></sc-for>\n</div>', '<span style="{{s.label}}">{{s.text}}</span></span></sc-for>\n</div></sc-if>')

# --- 4. Paso 1: el pasaporte (se lee la foto que ya tienes en la Bóveda).
rep('<div style="flex-grow: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 18px; text-align: center">\n<div style="width: 220px; height: 220px;',
    '<div style="flex-grow: 1; min-height: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; text-align: center">\n<div style="width: 180px; height: 180px; flex-shrink: 0;')
rep('font-size: 22px; font-weight: 800">Acerca el pasaporte a la parte de atrás del móvil</span>', 'font-size: 20px; font-weight: 800">{{readH}}</span>')
rep('max-width: 300px">Leemos el chip del pasaporte en tu teléfono. Tus datos no salen de aquí hasta que tú los envíes.</span>', 'max-width: 320px">{{readP}}</span>')
rep('padding: 0 22px; cursor: pointer">{{scanLabel}}</button>\n</div>',
    'padding: 0 22px; cursor: pointer">{{scanLabel}}</button>\n<button type="button" onClick="{{manual}}" style="height: 36px; border: none; background: transparent; color: #9FB0B8; font-family: inherit; font-size: 13px; font-weight: 800; text-decoration: underline; cursor: pointer">{{manualTxt}}</button>\n</div>')

# --- 5. Paso 2: revisar. Tocar un dato lo copia (se borra del portapapeles al minuto).
rep('<div style="display: flex; flex-direction: column; gap: 8px">\n<sc-for list="{{fields}}" as="f" hint-placeholder-count="7">\n<div style="{{f.style}}">',
    '<div class="vz-scroll" style="flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 8px">\n<sc-for list="{{fields}}" as="f" hint-placeholder-count="7">\n<div onClick="{{f.copy}}" role="button" aria-label="{{f.aria}}" style="{{f.style}}">')
rep('<span style="{{f.src}}">{{f.from}}</span></div>', '<span style="{{f.src}}">{{f.from}}</span><sc-if value="{{f.canCopy}}" hint-placeholder-val="{{ false }}"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#9FB0B8" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex-shrink: 0"><rect x="9" y="9" width="11" height="11" rx="2"></rect><path d="M5 15V5a2 2 0 0 1 2-2h10"></path></svg></sc-if></div>')
rep('line-height: 1.45">Faltan 2 preguntas que solo puedes contestar tú (antecedentes y viajes anteriores). Te las explicamos en español.</div>', 'line-height: 1.45; flex-shrink: 0">{{youAnswer}}</div>')
rep('font-size: 15px; font-weight: 800; cursor: pointer; margin-top: auto">Todo correcto, seguir</button>', 'font-size: 15px; font-weight: 800; cursor: pointer; flex-shrink: 0">{{allGood}}</button>')

# --- 6. Paso 3: lista para enviar en la web OFICIAL.
rep('font-size: 22px; font-weight: 800">Solicitud lista para enviar</span>', 'font-size: 22px; font-weight: 800">{{readyH}}</span>')
rep('line-height: 1.5">Abrimos la web oficial del Gobierno de EE. UU. con tus datos ya puestos. Allí pagas la tasa y la envías.</span>', 'line-height: 1.5">{{readyP}}</span>')
rep('background: {{accent}}"></span>Te avisamos cuando te la aprueben (suele ser en menos de 72 h)</div>', 'background: {{accent}}"></span>{{tipWait}}</div>')
rep('background: {{accent}}"></span>La aprobación se guarda sola en tu Bóveda</div>', 'background: {{accent}}"></span>{{tipSave}}</div>')
rep('background: #FF8A65"></span>Nunca uses webs que cobran de más: solo la oficial</div>', 'background: #FF8A65"></span>{{tipOfficial}}</div>')
rep('<button type="button" style="height: 52px; border-radius: 16px; border: none; background: #6CA8FF; color: #0B1217; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer">Abrir la web oficial</button>',
    '<sc-if value="{{hasOfficial}}" hint-placeholder-val="{{ true }}"><button type="button" onClick="{{official}}" style="height: 52px; border-radius: 16px; border: none; background: #6CA8FF; color: #0B1217; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer">{{officialTxt}}</button></sc-if>'
    '<button type="button" onClick="{{saveApproval}}" style="height: 44px; border-radius: 14px; border: 1px solid #33444E; background: transparent; color: #DCE5E9; font-family: inherit; font-size: 13.5px; font-weight: 800; cursor: pointer">{{saveTxt}}</button>')

# --- 7. Flyra: cuando no se puede leer tu pasaporte.
a = s.find('<button type="button" onClick="{{flyShow}}" aria-label="Probar el aviso de Flyra"')
b = s.find('PROBAR AVISO</button>', a) + len('PROBAR AVISO</button>')
assert a > 0 and b > a
s = s[:a] + s[b:]
rep('color: #F2F5F3">No consigo leer el chip</span><span style="font-size: 12.5px; line-height: 1.4; color: #B9C6CC">Mueve el pasaporte despacio por la parte de atrás del móvil, sin funda. Si no funciona, escanea la página de la foto.</span>',
    'color: #F2F5F3">{{flyTitle}}</span><span style="font-size: 12.5px; line-height: 1.4; color: #B9C6CC">{{flyText}}</span>')
rep('<button type="button" onClick="{{flyHide}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FF6B6B; color: #1A0B0B">Reintentar</button>',
    '<button type="button" onClick="{{flyRetry}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FF6B6B; color: #1A0B0B">{{flyRetryTxt}}</button>')
rep('border: 1px solid #33444E; background: transparent; color: #DCE5E9">Escanear la página</button>', 'border: 1px solid #33444E; background: transparent; color: #DCE5E9">{{flyAltTxt}}</button>')
rep('<button type="button" onClick="{{flyHide}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: 1px solid #33444E;', '<button type="button" onClick="{{flyAlt}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: 1px solid #33444E;')

# --- 8. La lógica (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('// ----'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Nueva York', 'Dario', 'Mamá', 'Manhattan', 'PROBAR', '.dc.html', 'chip del'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
