# Crea assets/settings/idioma.html a partir de la maqueta "Idioma".
# Uso:
#   python3 tool/idioma/build_page.py <Idioma.dc.html> <support.js> assets/settings/idioma.html
#
# Se queda TODO lo de la maqueta (el buscador, la tarjeta que enseña cómo
# se ve la app en el idioma elegido, la lista con banderas y el interruptor
# de Flyra y las audioguías). Solo se quitan los textos de ejemplo (Tokio,
# la lluvia inventada): la app pone sus idiomas de verdad en la marca
# /*ECLIPTA*/ (lib/features/settings/language_page.dart).
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
s = s[:i] + '<title>ECLIPTA · Idioma</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}\n'
    '#q-search{flex-grow:1;min-width:0;height:100%;border:none;outline:none;background:transparent;color:#F2F5F3;font-family:inherit;font-size:14px;padding:0}\n'
    '#q-search::placeholder{color:#6F8490}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: #0B1217;')

# --- 2. Arriba: volver y el título en tu idioma.
rep('<a href="Inicio.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')
rep('letter-spacing: -0.02em">Idioma</span>', 'letter-spacing: -0.02em">{{title}}</span>')
rep('<span style="font-size: 12px; color: #9FB0B8">La app, Flyra y las audioguías en tu idioma</span>',
    '<span style="font-size: 12px; color: #9FB0B8">{{sub}}</span>')

# --- 3. El buscador ya escribe de verdad.
rep('<span style="font-size: 14px; color: #6F8490">Buscar entre más de 100 idiomas</span>',
    '<input id="q-search" type="search" onInput="{{search}}" placeholder="{{hint}}" aria-label="{{hint}}">')

# --- 4. La lista: todos los idiomas que trae la app (y "el del móvil").
rep('letter-spacing: 0.06em; color: #9FB0B8; padding: 0 4px">TODOS LOS IDIOMAS</span>',
    'letter-spacing: 0.06em; color: #9FB0B8; padding: 0 4px">{{allH}}</span>')
rep('</button>\n</sc-for>\n</div>',
    '</button>\n</sc-for>\n<sc-if value="{{none}}" hint-placeholder-val="{{ false }}"><div style="padding: 24px 16px; font-size: 14px; color: #9FB0B8; text-align: center">{{noneTxt}}</div></sc-if>\n</div>')

# --- 5. El interruptor de Flyra y las audioguías.
rep('flex-grow: 1">Flyra y las audioguías también en este idioma</span>', 'flex-grow: 1">{{aiTxt}}</span>')

# --- 6. La lógica: la de la maqueta con tus idiomas (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('class Component'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Tokio', 'Tokyo', '1.234,50', '.dc.html', 'Llueve'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
