# Crea assets/group_chat/chat.html a partir de la maqueta "Chat del grupo".
# Uso:
#   python3 tool/chat_grupo/build_page.py <ChatGrupo.dc.html> <support.js> assets/group_chat/chat.html
#
# Se queda TODO lo de la maqueta (elegir con quién vas, el chat con Flyra
# dentro, los atajos, el micro, el perfil de Flyra, "Añadir al chat" y el
# final del viaje con estrellas) y solo se quitan los mensajes, nombres y
# sitios de ejemplo y las notas para DARIO. Los mensajes son los del
# servidor: la app los pone en la marca /*ECLIPTA*/
# (lib/features/group_chat/chat_page.dart) y manda lo nuevo con window.ECLin.
import json
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


def element_end(text, start):
    """Dónde acaba el elemento que empieza en [start] (contando etiquetas)."""
    depth = 0
    for m in re.finditer(r'<(/?)([a-zA-Z][\w-]*)[^>]*?(/?)>', text[start:]):
        if m.group(3) == '/' or m.group(2) in ('input', 'br', 'img', 'meta', 'link', 'stop', 'path', 'circle', 'rect', 'ellipse', 'line'):
            continue
        depth += 1 if m.group(1) == '' else -1
        if depth == 0:
            return start + m.end()
    raise AssertionError('sin cierre')


# --- 1. El motor de la maqueta va dentro (sin Internet).
rt_safe = rt.replace('<!--', '\\x3c!--').replace('<script', '\\x3cscript').replace('</script', '\\x3c/script')
rep('<script src="./support.js"></script>',
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
    '<script>window.ECL=/*ECLIPTA*/{};</script>\n'
    '<script>\n'
    'window.toApp=function(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}};\n'
    '// Datos para la app: JSON en base64url (solo letras, números, - y _).\n'
    'window.pack=function(o){var b=btoa(unescape(encodeURIComponent(JSON.stringify(o))));return b.replace(/\\+/g,"-").replace(/\\//g,"_").replace(/=+$/,"")};\n'
    '// La maqueta mide 390 de ancho: se amplía para llenar el ancho del móvil\n'
    '// y se estira a lo alto que tenga la pantalla.\n'
    'function fit(){if(!document.body){document.addEventListener("DOMContentLoaded",fit);return}var z=window.innerWidth/390;document.body.style.zoom=z;var st=document.getElementById("q-fit");if(!st){st=document.createElement("style");st.id="q-fit";document.head.appendChild(st)}st.textContent="#q-root{height:"+Math.round(window.innerHeight/z)+"px!important}"}\n'
    'fit();window.addEventListener("resize",fit);\n'
    '</script>\n'
    '<script>' + rt_safe + '</script>')
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="width: 390px; height: 844px;', '<div id="q-root" style="width: 390px; height: 844px;')

def cut_element(start_text, back_to='<'):
    """Quita el elemento que contiene [start_text] (desde su etiqueta)."""
    global s
    i = s.find(start_text)
    assert i >= 0, start_text
    a = s.rfind(back_to, 0, i)
    s = s[:a] + s[element_end(s, a):]



# --- 2. Volver, Flyra y vuestro destino.
rep('<a href="Grupo.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="')
rep('</b> Lisboa, 12-16 de mayo. Dime con quién vas y ajusto planes y cómo os repartís los gastos.</span>',
    '</b> {{flyraIntro}}</span>')
rep('>Lisboa · {{typeLabel}}<', '>{{city}} · {{typeLabel}}<')
rep('>Día 3 · jueves</span>', '>{{day}}</span>')

# --- 3. Las tarjetas de Flyra: el match del grupo (de Elegid planes) y los
# gastos. Las de restaurantes, votación y lluvia eran de ejemplo: fuera.
rep('>MAÑANA</span>', '>MATCH DEL GRUPO</span>')
rep('>Tranvía 28 + mirador de Santa Luzia</span>', '>{{m.planTitle}}</span>')
rep('>Sin cuestas a pie · bancos para descansar</span>', '>{{m.planNote}}</span>')
for k in ('{{m.isFood}}', '{{m.isPoll}}', '{{m.isRain}}'):
    cut_element('value="' + k + '"', '<sc-if')
rep('<a href="Gastos.dc.html" style="', '<a onClick="{{m.openMoney}}" style="cursor: pointer; ')
cut_element('>En la maqueta Flyra responde por palabras clave.', '<span')

# --- 4. Añadir al chat: el código del viaje de verdad (y su QR).
rep('>TU ID DE ECLIPTA</span>', '>CÓDIGO DEL VIAJE</span>')
rep('>EC-D4R1-07</span>', '>{{code}}</span>')
rep('>Que lo escanee o lo escriba en su móvil</span>', '>{{codeHint}}</span>')
i = s.find('<path d="M0 0h7v7H0z M14 0h7v7h-7z M0 14h7v7H0z"')
j = s.find('</svg>', i)
s = s[:i] + '<path d="{{qr}}" fill="#0B1217"></path>' + s[j:]
cut_element('style="{{guestSt}}">', '<div')

# --- 5. Fin del viaje: vuestras cifras y el vídeo de Recuerdos.
rep('>Lisboa, ¡qué viaje!</span>', '>{{endTitle}}</span>')
cut_element('>Cifras de ejemplo · en la app salen de tu viaje<', '<span')
rep('<a href="Recuerdos.dc.html" style="', '<a onClick="{{memories}}" style="cursor: pointer; ')
rep('<span style="font-size: 13px; color: #9FB0B8; text-align: center">{{starText}}',
    '<span onClick="{{starTap}}" style="font-size: 13px; color: #9FB0B8; text-align: center">{{starText}}')

# --- 6. La lógica: la de la maqueta con vuestro chat (logic.js). Se quedan
# los dibujos, los tipos de viaje, los atajos y lo que "piensa" Flyra.
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
start = s.rfind('>', 0, s.find('const ICO')) + 1
pre = s[start:a]
keep = []
for line in pre.split('\n'):
    if line.startswith(('const ICO', 'const T =', 'const QUICK', 'const THINK', 'const R =')):
        keep.append(line)
    elif line.startswith('const TIP'):
        # Para entrar al chat hace falta el código del viaje.
        assert 'pueden entrar sin cuenta con su ID' in line
        keep.append(line.replace('pueden entrar sin cuenta con su ID', 'entran con el código del viaje'))
assert len(keep) == 6, len(keep)
s = s[:start] + '\n' + '\n'.join(keep) + '\n' + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Lisboa', 'Mamá', 'Dario', 'Tasca', 'Belém', 'EC-D4R1', '.dc.html', 'Santa Luzia'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
