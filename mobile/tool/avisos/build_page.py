# Crea assets/push/avisos.html a partir de la maqueta "Avisos".
# Uso:
#   python3 tool/avisos/build_page.py <Avisos.dc.html> <support.js> assets/push/avisos.html
#
# Se queda TODO lo de la maqueta (las pestañas, las tarjetas con su icono
# animado y su brillo, la nota de abajo). Solo se quitan los avisos de
# ejemplo: la app pone tu historial de verdad en la marca /*ECLIPTA*/
# (lib/features/push/notices_page.dart) y manda lo nuevo con window.ECLin.
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
rep('<title>NomadIQ · Avisos</title>', '<title>ECLIPTA · Avisos</title>')
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;')

# --- 2. Arriba: volver y el título en tu idioma.
rep('<a href="Inicio.dc.html" aria-label="Volver al inicio" style="', '<a onClick="{{back}}" aria-label="Volver al inicio" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Avisos</div>', 'letter-spacing: -0.02em">{{title}}</div>')

# --- 3. La lista: puede tener hasta 100 avisos, así que se desliza (con un
# poco de margen para que no se corte el brillo de los iconos). Sin avisos,
# lo dice.
rep('<div style="display: flex; flex-direction: column; gap: 10px">\n<sc-for list="{{items}}"',
    '<sc-if value="{{empty}}" hint-placeholder-val="{{ false }}"><div style="font-size: 13px; line-height: 1.45; color: #9FB0B8; padding: 8px 2px">{{emptyTxt}}</div></sc-if>\n'
    '<div style="display: flex; flex-direction: column; gap: 10px; flex: 0 1 auto; min-height: 0; overflow-y: auto; scrollbar-width: none; margin: -8px -16px; padding: 8px 16px">\n<sc-for list="{{items}}"')
rep('<a href="{{it.href}}" style="{{it.cardStyle}}">', '<a onClick="{{it.open}}" style="{{it.cardStyle}}">')

# --- 4. La nota de abajo, en tu idioma.
rep('<div style="font-size: 13px; line-height: 1.5; color: #CFE9DE">Como mucho un aviso de zona cada 45 minutos y nunca la misma zona dos veces en un día. Los de seguridad llegan siempre. Este historial solo existe en tu teléfono.</div>',
    '<div style="font-size: 13px; line-height: 1.5; color: #CFE9DE">{{footer}}</div>')

# --- 5. La lógica: la de la maqueta con tus avisos (logic.js). Se quedan
# los dibujos animados de cada tipo de aviso.
a = s.find('const kinds = {')
kinds = s[a:s.find('\n', a)]
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
logic = logic[logic.find('class Component'):].replace('/*KINDS*/', kinds)
s = s[:a] + logic + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Marta', 'Lisboa', 'Puerta del Sol', '.dc.html', 'Tokio', 'Álex'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
