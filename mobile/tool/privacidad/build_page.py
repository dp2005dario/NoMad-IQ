# Crea assets/settings/privacidad.html a partir de la maqueta "Privacidad".
# Uso:
#   python3 tool/privacidad/build_page.py <Privacidad.dc.html> <support.js> assets/settings/privacidad.html
#
# Se queda TODO lo de la maqueta (el escudo verde, los interruptores, las
# ciudades sin conexión, "Qué sabemos de ti" y "Olvidar este teléfono").
# Los interruptores y los números son los tuyos de verdad: la app los pone en
# la marca /*ECLIPTA*/ (lib/features/settings/privacy_page.dart).
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
s = s[:i] + '<title>ECLIPTA · Privacidad</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
# Si el móvil tiene la letra grande, la página se desliza.
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217; font-family: \'Manrope\', system-ui, sans-serif; color: #F2F5F3; display: flex;',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217; font-family: \'Manrope\', system-ui, sans-serif; color: #F2F5F3; overflow-y: auto; scrollbar-width: none; display: flex;')

# --- 2. Arriba: volver y el título en tu idioma.
rep('<a href="Boveda.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; flex-shrink: 0; ')
rep('letter-spacing: -0.02em">Privacidad</div>', 'letter-spacing: -0.02em">{{title}}</div>')
rep('<span style="font-size: 16px; font-weight: 800">Este teléfono está protegido</span>', '<span style="font-size: 16px; font-weight: 800">{{prot}}</span>')
rep('color: #CFE9DE">Llave de avisos renovada hoy · bóveda cifrada</span>', 'color: #CFE9DE">{{protSub}}</span>')

# --- 3. Ciudades sin conexión (cuántas tienes) y, con cuenta, tu contraseña.
ROW = '<a href="SinConexion.dc.html" style="border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 12px 14px; display: flex; align-items: center; gap: 12px; text-decoration: none; color: #F2F5F3">'
rep(ROW, ROW.replace('href="SinConexion.dc.html" style="', 'onClick="{{openOffline}}" style="cursor: pointer; flex-shrink: 0; '))
rep('<span style="flex-grow: 1; font-size: 15px; font-weight: 800">Ciudades sin conexión</span><span style="font-size: 12px; color: #9FB0B8">1 descargada</span></a>',
    '<span style="flex-grow: 1; font-size: 15px; font-weight: 800">{{offTxt}}</span><span style="font-size: 12px; color: #9FB0B8">{{offCount}}</span></a>\n'
    '<sc-if value="{{hasPwd}}" hint-placeholder-val="{{ false }}"><a onClick="{{openPwd}}" style="cursor: pointer; flex-shrink: 0; border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 12px 14px; display: flex; align-items: center; gap: 12px; text-decoration: none; color: #F2F5F3"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#6CA8FF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="8" cy="15" r="4"></circle><path d="M11 12l9-9M17 6l3 3M15 8l2 2"></path></svg><span style="flex-grow: 1; font-size: 15px; font-weight: 800">{{pwdTxt}}</span><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#9FB0B8" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6"></path></svg></a></sc-if>')

# --- 4. Qué sabemos de ti (en tu idioma).
rep('padding: 4px 4px 0 4px">Qué sabemos de ti</div>', 'padding: 4px 4px 0 4px">{{knowH}}</div>')
rep('<span>Tu posición, solo al momento, para saber en qué zona estás.</span>', '<span>{{k1}}</span>')
rep('<span>Para los avisos eres un seudónimo, nunca tu nombre.</span>', '<span>{{k2}}</span>')
rep('<span>Ningún historial de los sitios por los que pasas.</span>', '<span>{{k3}}</span>')
rep('<span>Ni Google puede leer tus avisos: van cifrados para este teléfono.</span>', '<span>{{k4}}</span>')

# --- 5. Olvidar este teléfono (solo si este móvil recibe avisos). Ya
# olvidado, el botón vuelve a activarlos.
rep('<button type="button" style="height: 52px; border-radius: 18px; border: 1px solid #7A4433; background: #24140F; color: #FFB199; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer">Olvidar este teléfono</button>\n'
    '<div style="font-size: 12px; line-height: 1.5; color: #9FB0B8; text-align: center; padding: 0 8px">Borra su registro y su llave al momento. Puedes volver a activarlo cuando quieras.</div>',
    '<sc-if value="{{hasPush}}" hint-placeholder-val="{{ true }}">\n'
    '<button type="button" onClick="{{forget}}" style="{{forgetSt}}; height: 52px; flex-shrink: 0; border-radius: 18px; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer">{{forgetTxt}}</button>\n'
    '<div style="font-size: 12px; line-height: 1.5; color: #9FB0B8; text-align: center; padding: 0 8px">{{forgetSub}}</div>\n'
    '</sc-if>')

# --- 6. La lógica: la de la maqueta con tus ajustes (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('class Component'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', '1 descargada', '.dc.html', 'renovada hoy'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
