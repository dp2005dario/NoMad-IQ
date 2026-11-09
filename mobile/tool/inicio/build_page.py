# Crea assets/inicio/inicio.html a partir de la maqueta "ECLIPTA Inicio".
# Uso:
#   python3 tool/inicio/build_page.py <inicio.html> assets/inicio/inicio.html
#
# Se queda TODO lo de la maqueta (Flyra con su entrada y su bola, el
# carrusel de 19 cuadrados, Mi pasaporte, el álbum de cromos que se abre y
# pasa página, el cuarto del SOS con su cuenta atrás y tus contactos de
# emergencia) y solo se quitan los datos de ejemplo y las notas para DARIO.
# Tus datos de verdad los pone la app en la marca /*ECLIPTA*/
# (lib/features/home/home_page.dart) y manda lo nuevo con window.ECLin.
#
# Lo que la maqueta "hacía como que hacía" (escanear con la cámara, abrir
# WhatsApp, llamar al 112...) lo hace la app de verdad: la página le pide
# cada cosa con toApp("...") (ver logic.js).
import os
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
s = open(src, encoding='utf-8').read()


def rep(old, new, count=1):
    """Cambia [old] por [new] y comprueba que estaba (si no, la maqueta cambió)."""
    global s
    assert s.count(old) == count, (s.count(old), old[:120])
    s = s.replace(old, new)


def cut(start, end):
    """Quita desde [start] hasta [end] (incluido)."""
    global s
    a = s.find(start)
    assert a >= 0, start[:80]
    b = s.find(end, a)
    assert b >= 0, end[:80]
    s = s[:a] + s[b + len(end):]


# --- 1. Los datos de la app y el "buzón" para hablar con ella.
rep('<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">',
    '<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">'
    '<script>window.ECL=/*ECLIPTA*/{};</script>\n'
    '<script>window.toApp=function(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}};\n'
    '// Datos para la app: JSON en base64url (solo letras, números, - y _).\n'
    'window.pack=function(o){var b=btoa(unescape(encodeURIComponent(JSON.stringify(o))));return b.replace(/\\+/g,"-").replace(/\\//g,"_").replace(/=+$/,"")};\n'
    '</script>')

# --- 2. Arriba: dónde estás (de verdad; sin GPS no se ve).
rep('<path d="M12 21s7-6.2 7-12a7 7 0 10-14 0c0 5.800 7 12 7 12z"/><circle cx="12" cy="9" r="2.5"/></svg>Lisboa, Portugal</span>',
    '<path d="M12 21s7-6.2 7-12a7 7 0 10-14 0c0 5.800 7 12 7 12z"/><circle cx="12" cy="9" r="2.5"/></svg><span id="q-place-t"></span></span>')
rep('<span class="chip"><svg', '<span class="chip" id="q-place" style="display:none"><svg')

# --- 3. Mi pasaporte: tus documentos y tu foto (sin los de ejemplo).
rep('<div class="eyebrow">Documento de ejemplo</div><h2>Mi pasaporte</h2>', '<div class="eyebrow">Tus documentos</div><h2>Mi pasaporte</h2>')
rep('<span class="demo">DEMO</span>', '')
s, n = re.subn(r'<img class="photo" src="data:[^"]*" alt="Foto de ejemplo">',
               '<img class="photo" id="q-photo" src="" alt="Tu foto" style="display:none">'
               '<button type="button" class="photo q-addph" id="q-addph" aria-label="Añadir tu foto">'
               '<svg class="i" viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="15" rx="3"/><circle cx="12" cy="12.500" r="3.500"/><path d="M8 5l1.500-2h5L16 5"/></svg>Añadir foto</button>', s)
assert n == 1
rep('<dd id="f-ape">EJEMPLO DEMO</dd>', '<dd class="em" id="f-ape">Sin añadir</dd>')
rep('<dd id="f-nom">LUNA</dd>', '<dd class="em" id="f-nom">Sin añadir</dd>')
rep('<dd id="f-nac">Ficticia</dd>', '<dd class="em" id="f-nac">Sin añadir</dd>')
rep('<div><dt>Perfil</dt><dd>Mochilera</dd></div>', '')
rep('<div><dt>Grupo sanguíneo</dt><dd>0+</dd></div>', '<div><dt>Grupo sanguíneo</dt><dd class="em" id="f-blood">Sin añadir</dd></div>')
rep('<div class="mrz em2" id="f-mrz">P&lt;XXXEJEMPLO&lt;&lt;LUNA&lt;&lt;&lt;&lt;&lt;&lt;&lt;&lt;&lt;&lt;&lt;&lt;<br>Sin añadir · escanea tu pasaporte</div>',
    '<div class="mrz em2" id="f-mrz">Sin añadir · escanea tu pasaporte</div>')
# El escáner de la maqueta era un dibujo: la app abre la cámara de verdad
# (y la mini Flyra de la esquina, que va justo después, ya la pone la app en
# todas las pantallas: lib/features/flyra/flyra_mini.dart).
cut('<div class="scan" id="scan"', '<img alt=""></button></div>\n')
cut('// Escaneo de pasaporte y DNI:', '})();\n')

# --- 4. El álbum: tus cromos (los sellos de los monumentos) y tus amigos.
cut('(function(){var P2=[', 'draw()})();\n')
s, n = re.subn(r'<button class="friends" onclick="toast\(\'Abriría el intercambio de cromos con amigos\'\)"><span class="faces">(<img src="data:[^"]*" alt="">){3}</span><div><b>Cromos con amigos</b><span>3 amigos tienen cromos que te faltan</span>',
               '<button class="friends" onclick="toApp(\'cards\')"><span class="faces" id="q-faces"></span><div><b>Cromos con amigos</b><span id="q-fsub"></span>', s)
assert n == 1
rep('<div class="tap" id="tap">Toca el libro para abrirlo · 12 de 48 cromos</div>', '<div class="tap" id="tap"></div>')
rep('<span id="pgn">Página 2 de 6</span>', '<span id="pgn"></span>')

# --- 5. Contactos de emergencia: los tuyos (sin los de ejemplo).
# (Primero se quita su lógica de ejemplo: también decía "de ejemplo".)
cut('// Contactos de emergencia: 3 sugeridos', 'render()})();\n')
rep('<span class="ecx">Contactos de ejemplo</span>', '')
rep('<p class="ecn">Elegidos desde tu agenda y tu actividad en ECLIPTA. No leemos tus chats de WhatsApp.</p>',
    '<p class="ecn">Los eliges tú y se guardan solo en este móvil. Reciben tu mensaje y tu ubicación si pulsas el SOS.</p>')
rep('<p class="ecn" style="font-size:11.5px">Foto de perfil de ECLIPTA si están registrados (con insignia); si no, la de tu agenda; si no, su inicial. Fotos y números de ejemplo.</p>', '')
rep('<div><b>Ubicación incluida en el mensaje</b><span>38.7223 N, 9.1393 O · Lisboa</span></div>',
    '<div><b>Ubicación incluida en el mensaje</b><span id="q-where"></span></div>')

# El aviso del SOS de la maqueta (con contactos de ejemplo) lo pone logic.js.
cut('function sosGo(){', 'function sosPanel(){')
rep('var sosOn=false,cdT=null,cdI=null;\n', 'var sosOn=false,cdT=null,cdI=null;\nfunction sosGo(){}\nfunction sosPanel(){')
rep("$('sp112').onclick=function(){toast('Llamaría al 112 (demo)')};", '')

# La respuesta inventada de la caja de Flyra (logic.js le pasa la pregunta
# a la app, que abre el chat de verdad).
rep("$('reply').textContent='Flyra: \"'+v+'\" . Déjame buscarlo para ti.';", '')

# Cada cuadrado del carrusel abre su pantalla (en la maqueta, un aviso).
rep("else toast('Abriría: '+t[1])};", "else toApp('tile:'+i)};")

# --- 6. Los avisos de ejemplo de la mini Flyra (la de verdad es de la app).
cut("(function(){var A=[['warn','Sin conexión", "setTimeout(go,6500)})();\n")

# --- 7. Lo de la app (logic.js), al final.
rep('</body>', '<script>\n' + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + '\n</script>\n</body>')
# Estilos para lo nuevo (el hueco de la foto y las caras de tus amigos).
a = s.rfind('</style>')
s = s[:a] + ('.q-addph{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;'
             'background:#ffffff0d;border:2px dashed #ffffff40;color:#8ff0c3;font:700 11px var(--b);padding:0;cursor:pointer}'
             '.q-addph svg{font-size:22px}'
             '.faces i{width:34px;height:34px;border-radius:50%;border:2px solid var(--surf);margin-left:-9px;display:grid;'
             'place-items:center;font:800 14px var(--d);font-style:normal;color:#0B1217}'
             '.faces i:first-child{margin:0}\n') + s[a:]

low = s[s.find('<main'):]
low = re.sub(r'data:[a-z/+]+;base64,[A-Za-z0-9+/=]+', 'DATA', low)
for bad in ('ejemplo', 'EJEMPLO', 'LUNA', 'demo)', 'Lisboa', 'Mamá', 'Abriría', 'Llamaría', 'DEMO', 'XDE482916'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
