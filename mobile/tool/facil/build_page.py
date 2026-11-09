# Crea assets/easy/facil.html a partir de la maqueta "Facil" (Modo fácil).
# Uso:
#   python3 tool/facil/build_page.py <Facil.dc.html> <support.js> assets/easy/facil.html
#
# Se queda TODO lo de la maqueta (la tarjeta del vuelo con su avión, los
# cuatro cuadrados grandes, el botón de Flyra que brilla y las hojas de
# abajo: tu hotel y el taxista, la familia, la ayuda del aeropuerto y Flyra
# escuchando). Solo se quitan los datos de ejemplo (Carmen, Lisboa, la
# familia inventada) y la nota para DARIO. Los datos los pone la app en la
# marca /*ECLIPTA*/ (lib/features/easy/easy_page.dart).
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


def cut(start, end):
    """Quita desde [start] hasta [end] (incluido)."""
    global s
    a = s.find(start)
    assert a >= 0, start[:80]
    b = s.find(end, a)
    assert b >= 0, end[:80]
    s = s[:a] + s[b + len(end):]


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
s = s[:i] + '<title>ECLIPTA · Modo fácil</title>' + s[s.find('</title>', i) + len('</title>'):]
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(120% 50% at 50% 0%',
    '<div id="q-root" style="width: 390px; height: 844px; box-sizing: border-box; background: radial-gradient(120% 50% at 50% 0%')

# --- 2. Arriba: el día de hoy, tu nombre y "Modo normal".
rep('font-weight: 700">Jueves 23 de octubre</span>', 'font-weight: 700">{{day}}</span>')
rep('line-height: 1.1">Hola, Carmen</span>', 'line-height: 1.1">{{hello}}</span>')
rep('<a href="Inicio.dc.html" style="height: 44px;', '<a onClick="{{goNormal}}" style="cursor: pointer; flex-shrink: 0; height: 44px;')
rep('text-decoration: none">Modo normal</a>', 'text-decoration: none">{{normal}}</a>')

# --- 3. Tu vuelo (tocándolo se pone o se cambia). Sin vuelo, lo dice.
rep('<div style="position: relative; overflow: hidden; border-radius: 28px; padding: 18px;',
    '<div onClick="{{editTrip}}" style="cursor: pointer; position: relative; overflow: hidden; border-radius: 28px; padding: 18px;')
rep('<span style="font-size: 16px; font-weight: 800; color: #BCD6FF">TU VUELO · MAÑANA</span>',
    '<span style="font-size: 16px; font-weight: 800; color: #BCD6FF">{{flightK}}</span>\n'
    '<sc-if value="{{noFlight}}" hint-placeholder-val="{{ false }}"><span style="font-size: 18px; color: #DCE5E9; line-height: 1.35">{{noTripTxt}}</span><span style="font-size: 20px; font-weight: 800; color: #FFD166">{{setTrip}}</span></sc-if>\n'
    '<sc-if value="{{hasFlight}}" hint-placeholder-val="{{ true }}">')
rep('line-height: 1">10:30</span>', 'line-height: 1">{{flightTime}}</span>')
rep('<span style="font-size: 20px; font-weight: 700">Madrid → Lisboa</span>', '<span style="font-size: 20px; font-weight: 700">{{flightRoute}}</span>')
rep('<span style="font-size: 18px; color: #DCE5E9">Puerta <b style="font-size: 22px; color: #FFD166">B12</b> · sal de casa a las 7:45</span>\n</div>',
    '<span style="font-size: 18px; color: #DCE5E9">{{gateLbl}}<b style="font-size: 22px; color: #FFD166">{{gate}}</b>{{leave}}</span>\n</sc-if>\n</div>')

# --- 4. Los cuatro cuadrados, en tu idioma. "Mis papeles" abre la Bóveda.
rep('line-height: 1.15">Llévame al hotel</span>', 'line-height: 1.15">{{tHotel}}</span>')
rep('line-height: 1.15">Ver a la familia</span>', 'line-height: 1.15">{{tFamily}}</span>')
rep('<a href="Boveda.dc.html" style="display: flex;', '<a onClick="{{openPapers}}" style="display: flex;')
rep('line-height: 1.15">Mis papeles</span>', 'line-height: 1.15">{{tPapers}}</span>')
rep('color: #0B1217">Pregunta a Flyra</span>', 'color: #0B1217">{{tFly}}</span>')
rep('color: #0E3A2A">Habla, no hace falta escribir</span>', 'color: #0E3A2A">{{tFlySub}}</span>')
cut('<span style="font-size: 12px; color: #6F828C; text-align: center">Nombres, vuelo y hotel', '</span>')

# --- 5. Tu hotel: ir andando (Google Maps a pie) y la tarjeta del taxista
# con la frase en el idioma de allí. Sin hotel, lo dice.
rep('font-weight: 800">Tu hotel</span>', 'font-weight: 800">{{hotelTitle}}</span>')
rep('<sc-if value="{{taxiOff}}" hint-placeholder-val="{{ true }}">',
    '<sc-if value="{{noHotel}}" hint-placeholder-val="{{ false }}"><span style="font-size: 18px; color: #DCE5E9; line-height: 1.4">{{noHotelTxt}}</span><button type="button" onClick="{{editTrip}}" style="height: 64px; border-radius: 20px; border: none; font-family: inherit; font-size: 20px; font-weight: 800; cursor: pointer; display: flex; align-items: center; justify-content: center; gap: 10px; text-decoration: none; background: #3DDC97; color: #0B1217">{{setTrip}}</button></sc-if>\n'
    '<sc-if value="{{hasHotel}}" hint-placeholder-val="{{ true }}">\n'
    '<sc-if value="{{taxiOff}}" hint-placeholder-val="{{ true }}">')
rep('line-height: 1.4">Hotel Lisboa Centro<br>Rua Augusta 100 · a 12 min andando</span>',
    'line-height: 1.4">{{hotelLine}}<br>{{hotelLine2}}</span>')
rep('<a href="Mapa.dc.html" style="height: 64px;', '<a onClick="{{walk}}" style="height: 64px;')
rep('color: #0B1217">🚶 Ir andando · te guío</a>', 'color: #0B1217">{{walkTxt}}</a>')
rep('color: #1A1206">🚕 Enseñar al taxista</button>', 'color: #1A1206">{{taxiTxt}}</button>')
rep('color: #5A6A72">POR FAVOR, LLÉVEME A:</span>', 'color: #5A6A72">{{taxiTitle}}</span>')
rep('line-height: 1.1">Hotel Lisboa Centro</span>', 'line-height: 1.1">{{hotelName}}</span>')
rep('<span style="font-size: 24px; font-weight: 800">Rua Augusta 100, Lisboa</span>', '<span style="font-size: 24px; font-weight: 800">{{hotelAddr}}</span>')
rep('color: #5A6A72">Por favor, leve-me a este hotel. Obrigada.</span>', 'color: #5A6A72">{{taxiPhrase}}</span>')
rep('color: #F2F5F3">Volver</button>\n</sc-if>\n</div>\n</sc-if>',
    'color: #F2F5F3">{{backTxt}}</button>\n</sc-if>\n</sc-if>\n</div>\n</sc-if>')

# --- 6. La ayuda del aeropuerto: se guarda en el móvil y el mensaje para tu
# aerolínea se manda con lo que elijas (WhatsApp, correo...).
rep('font-weight: 800">Ayuda en el aeropuerto</span>', 'font-weight: 800">{{helpTitle}}</span>')
rep('line-height: 1.4">Es gratis. Te recogen en la entrada y te llevan hasta el avión. Mejor pedirla 2 días antes.</span>',
    'line-height: 1.4">{{helpWhy}}</span>')
rep('color: #1A1206">Pedirla ahora</button>', 'color: #1A1206">{{helpAsk}}</button>')
rep('color: #DCE5E9">Hecho: <b>{{optLabel}}</b>. Flyra la ha preparado con tu vuelo. Falta enviarla a tu aerolínea.</span>',
    'color: #DCE5E9">{{helpDone}}</span>')
rep('<a href="Ayuda.dc.html" style="height: 64px;', '<a onClick="{{sendHelp}}" style="height: 64px;')
rep('color: #1A1206">📞 Llamar a la aerolínea</a>', 'color: #1A1206">{{helpSend}}</a>')
rep('color: #F2F5F3">Cambiar lo que necesito</button>', 'color: #F2F5F3">{{helpChange}}</button>')

# --- 7. La familia: tus contactos del SOS. Tocar a la persona la llama; el
# botón verde abre WhatsApp para la videollamada. El "Llamando…" dibujado
# de la maqueta se quita: la llamada la hace el teléfono (o WhatsApp).
rep('font-weight: 800">¿A quién llamas?</span>', 'font-weight: 800">{{whoCall}}</span>')
rep('<span style="{{f.btn}}">', '<span onClick="{{f.video}}" aria-label="WhatsApp" style="{{f.btn}}">')
rep('<span style="font-size: 15px; color: #9FB0B8; text-align: center">Toca a una persona para hacer una videollamada</span>',
    '<sc-if value="{{noFamily}}" hint-placeholder-val="{{ false }}"><span style="font-size: 18px; color: #DCE5E9; line-height: 1.4">{{noFamilyTxt}}</span><button type="button" onClick="{{addFamily}}" style="height: 64px; border-radius: 20px; border: none; font-family: inherit; font-size: 20px; font-weight: 800; cursor: pointer; display: flex; align-items: center; justify-content: center; gap: 10px; text-decoration: none; background: #3DDC97; color: #0B1217">{{addFamilyTxt}}</button></sc-if>\n'
    '<span style="font-size: 15px; color: #9FB0B8; text-align: center">{{callHint}}</span>')
cut('<sc-if value="{{inCall}}"', '</sc-if>\n')
assert s.count('<sc-if value="{{fly}}"') == 1

# --- 8. Flyra escucha de verdad (el micro del móvil) y contesta con tu
# viaje. Si la respuesta tiene algo que hacer ("Llévame"...), sale su botón.
rep('<span style="font-size: 22px; font-weight: 800">Te escucho…</span>', '<span style="font-size: 22px; font-weight: 800">{{listenTxt}}</span>')
rep('<span style="font-size: 16px; color: #9FB0B8">Habla con normalidad, como por teléfono</span>', '<span style="font-size: 16px; color: #9FB0B8">{{listenSub}}</span>')
rep('<div style="align-self: stretch; border-radius: 20px 20px 4px 20px; background: #26363F; padding: 12px 14px; font-size: 18px; text-align: right; animation: fz-in .35s ease both">«¿A qué hora tengo que salir de casa?»</div>',
    '<sc-if value="{{hasQ}}" hint-placeholder-val="{{ true }}"><div style="align-self: stretch; border-radius: 20px 20px 4px 20px; background: #26363F; padding: 12px 14px; font-size: 18px; text-align: right; animation: fz-in .35s ease both">«{{q}}»</div></sc-if>')
i = s.find('animation: fz-in .35s ease .4s both">Sal a las')
j = s.find('</div>', i)
s = s[:i] + 'animation: fz-in .35s ease .4s both">{{a}}' + s[j:]
rep('<button type="button" onClick="{{askAgain}}"',
    '<sc-if value="{{hasAct}}" hint-placeholder-val="{{ false }}"><button type="button" onClick="{{doAct}}" style="height: 64px; border-radius: 20px; border: none; font-family: inherit; font-size: 20px; font-weight: 800; cursor: pointer; display: flex; align-items: center; justify-content: center; gap: 10px; text-decoration: none; align-self: stretch; background: #FFFFFF; color: #0B1217">{{act}}</button></sc-if>\n'
    '<button type="button" onClick="{{askAgain}}"')
rep('color: #0B1217">🎤 Preguntar otra cosa</button>', 'color: #0B1217">{{againTxt}}</button>')

# --- 9. La lógica: la de la maqueta con tus datos (logic.js).
a = s.find('const H = [')
b = s.find('</script>', a)
logic = open(os.path.join(here, 'logic.js'), encoding='utf-8').read()
s = s[:a] + logic[logic.find('const pad'):] + s[b:]

low = s[s.find('</head>'):]
low = '\n'.join(l for l in low.split('\n') if not l.lstrip().startswith('//'))
for bad in ('ejemplo', 'maqueta', 'Carmen', 'Lisboa', 'Noelia', 'Dario', '>B12<', '7:45', '.dc.html', 'Augusta'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
