# Crea assets/settings/ajustes.html a partir de la maqueta "Ajustes".
# Uso:
#   python3 tool/ajustes/build_page.py <Ajustes.dc.html> <support.js> assets/settings/ajustes.html
#
# Se queda TODO lo de la maqueta (tu foto o avatar, los 4 interruptores,
# "Tu app", ECLIPTA Premium "Próximamente", la cuenta y la hoja de "¿Borrar
# tu cuenta?") y solo se quitan el nombre, el correo y el ID de ejemplo. Tus
# datos de verdad los pone la app en la marca /*ECLIPTA*/
# (lib/features/settings/settings_page.dart) y manda lo nuevo con
# window.ECLin.
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
    'function fit(){if(!document.body){document.addEventListener("DOMContentLoaded",fit);return}var z=window.innerWidth/390;document.body.style.zoom=z;var st=document.getElementById("q-fit");if(!st){st=document.createElement("style");st.id="q-fit";document.head.appendChild(st)}st.textContent="#q-root{height:auto!important;min-height:"+Math.round(window.innerHeight/z)+"px}"}\n'
    'fit();window.addEventListener("resize",fit);\n'
    '</script>\n'
    '<script>' + rt_safe + '</script>')
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow-x:hidden}')
rep('<div style="width: 390px; height: 1400px;', '<div id="q-root" style="width: 390px; height: 1400px;')

def cut_element(start_text, back_to='<'):
    """Quita el elemento que contiene [start_text] (desde su etiqueta)."""
    global s
    i = s.find(start_text)
    assert i >= 0, start_text
    a = s.rfind(back_to, 0, i)
    s = s[:a] + s[element_end(s, a):]



# --- 2. Volver, y tu nombre, tu correo y tu ID de verdad.
rep('<a href="Inicio.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')
rep('font-size: 22px; font-weight: 800">Dario</span>', 'font-size: 22px; font-weight: 800; overflow: hidden; text-overflow: ellipsis; white-space: nowrap">{{name}}</span>')
rep('<span style="font-size: 12px; color: #B7C5CC">dario@gmail.com</span>', '<span style="font-size: 12px; color: #B7C5CC; overflow: hidden; text-overflow: ellipsis; white-space: nowrap">{{email}}</span>')
rep('style="align-self: flex-start; height: 28px;', 'style="{{idHide}}align-self: flex-start; height: 28px;')

# --- 3. "Tu app": cada fila abre su pantalla y enseña tu valor.
for page, fn in (('Idioma', 'goLang'), ('Divisas', 'goCur'), ('Facil', 'goEasy'), ('Privacidad', 'goPriv'), ('Avisos', 'goNotices'), ('Ayuda', 'goHelp'), ('Main', 'signOut')):
    rep('<a href="%s.dc.html" style="' % page, '<a onClick="{{%s}}" style="cursor: pointer; ' % fn)
rep('white-space: nowrap">Español</span>', 'white-space: nowrap">{{lang}}</span>')
rep('white-space: nowrap">EUR · €</span>', 'white-space: nowrap">{{cur}}</span>')
rep('white-space: nowrap">Normal</span>', 'white-space: nowrap">{{easy}}</span>')

# --- 4. La cuenta: sin cuenta (invitado) se ve "Entrar con tu cuenta" y no
# se puede borrar nada.
rep('font-weight: 700">Cerrar sesión</span>', 'font-weight: 700">{{outTxt}}</span>')
rep('<div style="height: 1px; background: #22313A; margin: 0 12px 0 60px"></div>\n<button type="button" onClick="{{askDelete}}" style="',
    '<div style="{{delHide}}height: 1px; background: #22313A; margin: 0 12px 0 60px"></div>\n<button type="button" onClick="{{askDelete}}" style="{{delHide}}')
rep('>ECLIPTA 1.0 · Hecho con cariño', '>ECLIPTA {{ver}} · Hecho con cariño')

# --- 5. "¿Borrar tu cuenta?": la hoja se queda abajo de la pantalla (no de
# la página entera) y sus botones hacen lo que dicen.
rep('<div style="position: absolute; inset: 0; background: rgba(5,9,12,0.72);', '<div style="position: fixed; inset: 0; background: rgba(5,9,12,0.72);')
rep('<button type="button" style="height: 48px; border-radius: 16px; border: 1px solid #4A5D68;', '<button type="button" onClick="{{download}}" style="height: 48px; border-radius: 16px; border: 1px solid #4A5D68;')
rep('<button type="button" onClick="{{closeDelete}}" style="height: 48px; border-radius: 16px; border: none; background: #FF6B6B;', '<button type="button" onClick="{{erase}}" style="height: 48px; border-radius: 16px; border: none; background: #FF6B6B;')

# --- 6. La lógica: la de la maqueta con tus datos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
s = s[:a] + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('<div id="q-root"'):]
for bad in ('Dario', 'dario@', 'DARIO', '.dc.html', 'href="'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
