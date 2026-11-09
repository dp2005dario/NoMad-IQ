# Crea assets/flights/vuelos.html a partir de la maqueta "Cazador de vuelos".
# Uso:
#   python3 tool/vuelos/build_page.py <Vuelos.dc.html> <support.js> assets/flights/vuelos.html
#
# Se queda TODO lo de la maqueta (el buscador con su calendario de precios,
# "Planea tu viaje", el chollo con sus barras, la animación "¡VUELO
# CAZADO!", la ganga a medida, el globo con la ruta, el vuelo simulado, las
# fichas de las dos ciudades, el aviso de 48 h, tus alertas y el aviso de
# Flyra) y solo se quitan los datos de ejemplo y las notas para DARIO:
#   - fuera "Datos de ejemplo", "Ejemplo", "PROBAR AVISO" y las notas;
#   - la barra de abajo de la maqueta tampoco: la app ya tiene la suya.
# Lo de verdad lo pone la app (lib/features/flights/flights_page.dart) en
# la marca /*ECLIPTA*/: tus chollos de hoy, la ruta con sus coordenadas, tus
# alertas... Y lo que llega después (el precio de cada día del calendario,
# las fichas de ciudad) entra sin recargar con window.ECLin({...}).
#
# Los aeropuertos del buscador van dentro de la página (sin Internet), de
# assets/geo (OpenFlights, licencia ODbL; ver assets/geo/LEEME.md).
import base64
import json
import os
import re
import sys

src, runtime, dst = sys.argv[1], sys.argv[2], sys.argv[3]
here = os.path.dirname(os.path.abspath(__file__))
mobile = os.path.dirname(os.path.dirname(here))
s = open(src, encoding='utf-8').read()
rt = open(runtime, encoding='utf-8').read()


def rep(old, new, count=1):
    """Cambia [old] por [new] y comprueba que estaba (si no, la maqueta cambió)."""
    global s
    assert s.count(old) == count, (s.count(old), old[:120])
    s = s.replace(old, new)


def rep_re(pattern, new, count=1, flags=0):
    global s
    s, n = re.subn(pattern, new, s, flags=flags)
    assert n == count, (n, pattern[:120])


def element_end(text, start):
    """Dónde acaba el elemento que empieza en [start] (contando etiquetas)."""
    depth = 0
    for m in re.finditer(r'<(/?)([a-zA-Z][\w-]*)[^>]*?(/?)>', text[start:]):
        if m.group(3) == '/' or m.group(2) in ('input', 'br', 'img', 'meta', 'link'):
            continue
        depth += 1 if m.group(1) == '' else -1
        if depth == 0:
            return start + m.end()
    raise AssertionError('sin cierre')


def block(marker, nth=0):
    """(inicio, fin) del elemento que contiene [marker] (la n-ésima vez)."""
    at = -1
    for _ in range(nth + 1):
        at = s.find(marker, at + 1)
        assert at >= 0, marker[:120]
    a = s.rfind('<', 0, at + 1) if not marker.startswith('<') else at
    return a, element_end(s, a)


def svg_flag(seg, new):
    """La primera bandera dibujada (svg 3×2) de [seg] pasa a ser [new]."""
    m = re.search(r'<svg width="\d+" height="\d+" viewBox="0 0 3 2".*?</svg>', seg, re.S)
    assert m, seg[:120]
    return seg[:m.start()] + new + seg[m.end():]


# --- 1. El motor de la maqueta (React + plantillas) va dentro: sin Internet.
# "<!--", "<script" y "</script" dentro del código confunden al navegador al
# leer la página: se escriben con \x3c (es lo mismo dentro de un texto JS).
rt_safe = rt.replace('<!--', '\\x3c!--').replace('<script', '\\x3cscript').replace('</script', '\\x3c/script')

# Los aeropuertos: [código, nombre, ciudad, país, código del país, otros
# nombres para buscar, popular]. La ciudad y el país, en español.
CITY_ES = {
    'Tokyo': 'Tokio', 'London': 'Londres', 'New York': 'Nueva York', 'Paris': 'París',
    'Rome': 'Roma', 'Munich': 'Múnich', 'Lisbon': 'Lisboa', 'Seville': 'Sevilla',
    'Milan': 'Milán', 'Venice': 'Venecia', 'Naples': 'Nápoles', 'Florence': 'Florencia',
    'Athens': 'Atenas', 'Moscow': 'Moscú', 'Beijing': 'Pekín', 'Cairo': 'El Cairo',
    'Istanbul': 'Estambul', 'Geneva': 'Ginebra', 'Brussels': 'Bruselas',
    'Copenhagen': 'Copenhague', 'Stockholm': 'Estocolmo', 'Warsaw': 'Varsovia',
    'Prague': 'Praga', 'Vienna': 'Viena', 'Berlin': 'Berlín', 'Dublin': 'Dublín',
    'Edinburgh': 'Edimburgo', 'Zurich': 'Zúrich', 'Singapore': 'Singapur',
    'Seoul': 'Seúl', 'Shanghai': 'Shanghái', 'New Delhi': 'Nueva Delhi',
    'Mexico City': 'Ciudad de México', 'Havana': 'La Habana', 'Cape Town': 'Ciudad del Cabo',
    'Frankfurt': 'Fráncfort', 'Hamburg': 'Hamburgo', 'Cologne': 'Colonia',
    'Krakow': 'Cracovia', 'Bucharest': 'Bucarest', 'St. Petersburg': 'San Petersburgo',
    'Philadelphia': 'Filadelfia', 'Dubai': 'Dubái', 'Abu Dhabi': 'Abu Dabi',
    'Marseille': 'Marsella', 'Nice': 'Niza', 'Bordeaux': 'Burdeos', 'Toulouse': 'Toulouse',
    'Gothenburg': 'Gotemburgo', 'Reykjavik': 'Reikiavik', 'Malaga': 'Málaga',
    'Cordoba': 'Córdoba', 'La Coruna': 'A Coruña', 'Porto': 'Oporto', 'Sao Paulo': 'São Paulo',
    'Bogota': 'Bogotá', 'Mumbai': 'Bombay', 'Kyoto': 'Kioto', 'Moskow': 'Moscú',
    'Marrakech': 'Marrakech', 'Tangier': 'Tánger', 'Lyon': 'Lyon', 'Strasbourg': 'Estrasburgo',
    'Basel': 'Basilea', 'Antwerp': 'Amberes', 'The Hague': 'La Haya', 'Belgrade': 'Belgrado',
    'Bratislava': 'Bratislava', 'Vilnius': 'Vilna', 'Kiev': 'Kiev', 'Bangkok': 'Bangkok',
    'Hanoi': 'Hanói', 'Taipei': 'Taipéi', 'Jerusalem': 'Jerusalén', 'Tunis': 'Túnez',
    'Algiers': 'Argel', 'Washington': 'Washington', 'New Orleans': 'Nueva Orleans',
    'Montreal': 'Montreal', 'Quebec': 'Quebec', 'Lima': 'Lima', 'Panama': 'Panamá',
    'Palma de Mallorca': 'Palma de Mallorca', 'Las Palmas': 'Gran Canaria',
}
POPULAR = ['MAD', 'BCN', 'LHR', 'CDG', 'FCO', 'JFK']

cc_of = {}
for line in open(os.path.join(mobile, 'assets/geo/countries.txt'), encoding='utf-8'):
    p = line.rstrip('\n').split('|')
    if len(p) == 2:
        cc_of[p[0]] = p[1]
es_of = {}
rows = open(os.path.join(mobile, 'assets/geo/country_names.txt'), encoding='utf-8').read().split('\n')
for line in rows[1:]:
    p = line.split('|')
    if len(p) > 5:
        es_of[p[0]] = p[5]
ap = []
for line in open(os.path.join(mobile, 'assets/geo/airports.txt'), encoding='utf-8'):
    p = line.rstrip('\n').split('|')
    if len(p) != 6 or len(p[0]) != 3 or not p[3]:
        continue
    cc = cc_of.get(p[4], '')
    city = CITY_ES.get(p[3], p[3])
    alias = [p[3]] if city != p[3] else []
    ap.append([p[0], 'Aeropuerto de ' + city, city, es_of.get(cc, p[4]), cc, alias, 1 if p[0] in POPULAR else 0])
ap.sort(key=lambda a: (POPULAR.index(a[0]) if a[0] in POPULAR else 99))
ap_js = json.dumps(ap, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c')

rep('<script src="./support.js"></script>',
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
    '<script>window.ECL=/*ECLIPTA*/{};</script>\n'
    '<script>window.AP=' + ap_js + ';window.AP_BY={};window.AP.forEach(function(a){window.AP_BY[a[0]]=a});</script>\n'
    '<script>\n'
    '// Los datos van a la app en base64url (solo letras, números, - y _).\n'
    'window.pack=function(v){var b=btoa(unescape(encodeURIComponent(JSON.stringify(v))));return b.replace(/\\+/g,"-").replace(/\\//g,"_").replace(/=+$/,"")};\n'
    'window.toApp=function(m){try{if(window.ECLIPTA)window.ECLIPTA.postMessage(m)}catch(e){}};\n'
    '// La maqueta mide 390 de ancho: se amplía para llenar el ancho del móvil\n'
    '// y se estira a lo alto que tenga la pantalla.\n'
    'function fit(){if(!document.body){document.addEventListener("DOMContentLoaded",fit);return}var z=window.innerWidth/390;document.body.style.zoom=z;var st=document.getElementById("q-fit");if(!st){st=document.createElement("style");st.id="q-fit";document.head.appendChild(st)}st.textContent="#q-root{height:"+Math.round(window.innerHeight/z)+"px!important}#q-scroll{height:100%!important}"}\n'
    'fit();window.addEventListener("resize",fit);\n'
    '</script>\n'
    '<script>' + rt_safe + '</script>')
rep('body{margin:0}', 'html,body{margin:0;background:#0B1217;overflow:hidden}')
rep('<div style="position: relative; width: 390px; height: 844px; overflow: hidden; background: #0B1217"><div id="q-scroll"',
    '<div id="q-root" style="position: relative; width: 390px; height: 844px; overflow: hidden; background: #0B1217"><div id="q-scroll"')

# --- 2. Fuera las etiquetas "Datos de ejemplo" / "Ejemplo".
rep_re(r'<span class="q-ex">[^<]*</span>', '', count=3)

# --- 3. Cabecera: desde tu aeropuerto y tu inicial (abre Ajustes).
rep('Vigilando precios desde Madrid', '<span>Vigilando precios desde {{fromCity}}</span>')
rep_re(r'<a href="Ajustes.dc.html" (aria-label="Tu foto de perfil y ajustes" style="[^"]*")>D</a>',
       r'<a onClick="{{openSettings}}" \1>{{userInitial}}</a>')

# --- 4. Buscador: sin la "lista de ejemplo" ni la nota de precios de ejemplo.
rep('No encontramos ese lugar en la lista de ejemplo. Prueba con otra ciudad.',
    'No encontramos ese lugar. Prueba con otra ciudad.')
rep('Precio más barato de cada día, por persona. Precios de ejemplo; en la app salen del buscador real.',
    'Precio más barato de cada día, por persona.')

# --- 5. Planea tu viaje: cada cuadrado abre su pantalla; iconos dentro.
for i, page in enumerate(['Explorar', 'Hoteles', 'Eventos', 'Copiar', 'Ruta']):
    rep(f'href="{page}.dc.html"', f'onClick="{{{{tile{i}}}}}"')
ICONS = {
    '413bbcd73dca933e98d1e388cf127b97': os.path.join(mobile, 'assets/inicio/icono-0.webp'),
    'b49651c214908178b321a5bbe9f51506': os.path.join(mobile, 'assets/inicio/icono-2.webp'),
    '023e7eaa791b7bac8186b0f62a53bb33': os.path.join(here, 'icono-que-pasa.png'),
    '33e2fba77bec1f76a2a1f05d9988b591': os.path.join(mobile, 'assets/inicio/icono-11.webp'),
    'bcd16451f8d5a51741b0436233864e5d': os.path.join(mobile, 'assets/inicio/icono-3.webp'),
}
for blob, path in ICONS.items():
    kind = 'png' if path.endswith('.png') else 'webp'
    data = base64.b64encode(open(path, 'rb').read()).decode()
    rep(f'src="/_blob/{blob}"', f'src="data:image/{kind};base64,{data}"')
assert '/_blob/' not in s

# --- 6. El chollo (tu mejor chollo de hoy) o, si no hay, un aviso.
CARD = '<div style="border-radius: 28px; background: #13213A; border: 1px solid #2A3E63; padding: 16px; display: flex; flex-direction: column; gap: 12px">'
a, b = block(CARD)
seg = s[a:b]
for old, new in [
    ('>¡VUELO CAZADO! · ERROR DE TARIFA<', '>{{huntKind}}<'),
    ('>Hace 14 min<', '>{{huntAgo}}<'),
    ('line-height: 1">MAD</span><span style="font-size: 11px; color: #A9BEDF">Madrid, España<',
     'line-height: 1">{{huntO}}</span><span style="font-size: 11px; color: #A9BEDF">{{huntOPlace}}<'),
    ('line-height: 1">HND</span><span style="font-size: 11px; color: #A9BEDF">Tokio, Japón<',
     'line-height: 1">{{huntD}}</span><span style="font-size: 11px; color: #A9BEDF">{{huntDPlace}}<'),
    ('text-decoration: line-through">950 €<', 'text-decoration: line-through">{{usual}}<'),
    ('>Ida y vuelta · {{dateLabel}} · 1 escala · 14 h 35 min<', '>{{huntLine}}<'),
    ('<button type="button" style="height: 48px; border-radius: 16px; border: none; background: #6CA8FF',
     '<button type="button" onClick="{{book}}" style="height: 48px; border-radius: 16px; border: none; background: #6CA8FF'),
    ('<button type="button" style="height: 48px; border-radius: 16px; border: 1px solid #3A5584',
     '<button type="button" onClick="{{watch}}" style="height: 48px; border-radius: 16px; border: 1px solid #3A5584'),
]:
    assert seg.count(old) == 1, old
    seg = seg.replace(old, new)
seg = svg_flag(seg, '<span aria-hidden="true" style="{{huntOFlag}}"></span>')
seg = svg_flag(seg, '<span aria-hidden="true" style="{{huntDFlag}}"></span>')
EMPTY = ('<sc-if value="{{noHunt}}" hint-placeholder-val="{{ false }}">' + CARD +
         '<span style="font-size: 11px; font-weight: 800; letter-spacing: 0.05em; color: #A9BEDF">CHOLLOS DE HOY</span>'
         '<span style="font-size: 14px; line-height: 1.5; color: #DCE5E9">{{noHuntMsg}}</span></div></sc-if>')
s = s[:a] + '<sc-if value="{{hasHunt}}" hint-placeholder-val="{{ true }}">' + seg + '</sc-if>' + EMPTY + s[b:]

# --- 7. La ruta del vuelo (la del chollo, con sus ciudades de verdad).
a = s.find('<div style="display: flex; justify-content: space-between; align-items: baseline; padding: 0 4px; margin-top: 6px">')
# (El crédito de las fotos va con la ruta: sin ruta no hay fotos.)
foot = element_end(s, s.find('<span class="q-foot">'))
assert 0 < a < foot
seg = s[a:foot]
for old, new in [
    # "Ver el vuelo en 3D real" abre el Vuelo 3D de la app con esta ruta.
    ('<a href="https://claude.ai/artifact/9NnY2D2gcs7e58MiAVDpFQ" target="_blank" rel="noopener" style="',
     '<a onClick="{{open3d}}" style="cursor: pointer; '),
    ('aria-label="Ver la ficha de Madrid, origen"', 'aria-label="{{pinOAria}}"'),
    ('aria-label="Ver la ficha de Tokio, destino"', 'aria-label="{{pinDAria}}"'),
    ('white-space: nowrap">MAD</span></button>', 'white-space: nowrap">{{rO}}</span></button>'),
    ('white-space: nowrap">HND</span></button>', 'white-space: nowrap">{{rD}}</span></button>'),
    ('</svg>MAD\n', '</svg>{{rO}}\n'),
    ('\nHND<svg', '\n{{rD}}<svg'),
    ('Si tocas <b style="color: #6CA8FF">MAD</b>, la ficha de España entra por la izquierda. Si tocas <b style="color: #FF8A65">HND</b>, la de Japón entra por la derecha. Desde el origen puedes despegar y seguir el avión hasta Tokio.',
     'Si tocas <b style="color: #6CA8FF">{{rO}}</b>, la ficha de {{oCountry}} entra por la izquierda. Si tocas <b style="color: #FF8A65">{{rD}}</b>, la de {{dCountry}} entra por la derecha. Desde el origen puedes despegar y seguir el avión hasta {{dCity}}.'),
    ('>Empezar en Madrid<', '>Empezar en {{oCity}}<'),
]:
    assert seg.count(old) == 1, old
    seg = seg.replace(old, new)
# Las banderitas de la barra de arriba del globo.
i = seg.find('<span style="{{miniBar}}">')
head, tail = seg[:i], seg[i:]
k = head.rfind('<svg width="18" height="12"')
head = head[:k] + svg_flag(head[k:], '<span aria-hidden="true" style="{{oFlagSm}}"></span>')
tail = svg_flag(tail, '<span aria-hidden="true" style="{{dFlagSm}}"></span>')
seg = head + tail


def ficha(seg, side, country, city, extra, texts, color):
    """La ficha de una ciudad (origen o destino) con lo que manda la app."""
    a = seg.find('<sc-if value="{{is' + ('Origin' if side == 'o' else 'Dest') + '}}"')
    b = seg.find('</sc-if>', a)
    f = seg[a:b]
    f = svg_flag(f, '<span role="img" aria-label="{{' + side + 'Country}}" style="{{' + side + 'FlagBig}}"></span>')
    for old, new in [
        ('line-height: 1">' + country + '</span><span style="font-size: 13px; color: #B7C5CC">' + city + extra + '<',
         'line-height: 1">{{' + side + 'Country}}</span><span style="font-size: 13px; color: #B7C5CC">{{' + side + 'City}}' + extra + '<'),
    ] + [('font-weight: 800">' + t + '</span></div>', 'font-weight: 800">{{' + side + k + '}}</span></div>') for k, t in texts[:4]] + [
        ('color: #DCE5E9">' + texts[4][1] + '<', 'color: #DCE5E9">{{' + side + 'Culture}}<'),
        ('color: #DCE5E9">' + texts[5][1] + '<', 'color: #DCE5E9">{{' + side + 'Why}}<'),
    ]:
        assert f.count(old) == 1, old[:100]
        f = f.replace(old, new)
    # Los lugares: los de Wikipedia con su foto de Wikimedia Commons.
    box = '<div style="display: flex; gap: 10px; overflow-x: auto; scroll-snap-type: x mandatory; padding-bottom: 4px">'
    p = f.find(box)
    q = element_end(f, p)
    fig = ('<sc-for list="{{' + side + 'Places}}" as="p" hint-placeholder-count="4">'
           '<figure onClick="{{p.open}}" style="margin: 0; flex-shrink: 0; width: 240px; border-radius: 20px; overflow: hidden; background: #0F171D; border: 1px solid #26363F; scroll-snap-align: start; cursor: pointer">'
           '<div style="position: relative"><div role="img" aria-label="{{p.name}}" style="{{p.img}}"></div>'
           '<span style="position: absolute; left: 0; right: 0; bottom: 0; height: 50px; background: linear-gradient(transparent, rgba(0,0,0,0.55))"></span>'
           '<figcaption style="position: absolute; left: 12px; bottom: 9px; font-size: 15px; font-weight: 800; color: #FFFFFF; text-shadow: 0 1px 4px rgba(0,0,0,0.6)">{{p.name}}</figcaption></div>'
           '<p style="margin: 0; padding: 10px 12px 12px 12px; font-size: 13px; line-height: 1.45; color: #C9D5DB; border-top: 3px solid ' + color + '">{{p.desc}}</p>'
           '</figure></sc-for>'
           '<sc-if value="{{' + side + 'NoPlaces}}" hint-placeholder-val="{{ false }}"><span style="font-size: 13px; color: #9FB0B8">Sin datos</span></sc-if>'
           '<sc-if value="{{' + side + 'Loading}}" hint-placeholder-val="{{ false }}"><span style="font-size: 13px; color: #9FB0B8">…</span></sc-if>')
    f = f[:p] + box + fig + '</div>' + f[q:]
    return seg[:a] + f + seg[b:]


seg = ficha(seg, 'o', 'España', 'Madrid', ' · aquí empieza tu viaje', [
    ('Capital', 'Madrid'), ('Lang', 'Español'), ('Cur', 'Euro (EUR)'), ('Time', 'UTC+1 (+2 en verano)'),
    ('Culture', 'La vida se hace en la calle: comidas largas con sobremesa, cenas a partir de las 21:00 y terrazas llenas todo el año. Se saluda con dos besos, se va de tapas de bar en bar y hay fiesta para todo, desde el flamenco hasta las verbenas de San Isidro en mayo.'),
    ('Why', 'Madrid es la capital del arte: el Prado, el Reina Sofía y el Thyssen están a pocos minutos a pie entre sí. El Paseo del Prado y el Retiro son Patrimonio Mundial de la UNESCO desde 2021, y su ambiente nocturno es de los más animados de Europa.'),
], '#6CA8FF')
seg = ficha(seg, 'd', 'Japón', 'Tokio', ' · has llegado', [
    ('Capital', 'Tokio'), ('Lang', 'Japonés'), ('Cur', 'Yen (JPY)'), ('Time', '8 h más que Madrid'),
    ('Culture', 'El respeto y el orden lo son todo: se saluda con una pequeña reverencia, no se deja propina y en el metro se habla bajito. Conviven templos sintoístas y budistas con el anime, el manga y la tecnología más puntera, y en muchas casas y restaurantes te quitarás los zapatos al entrar.'),
    ('Why', 'Tokio mezcla lo más antiguo con lo más futurista: templos como el Sensō-ji a pocas paradas de cruces de neón como el de Shibuya. Es una de las capitales gastronómicas del mundo y en días despejados se ve el monte Fuji desde la ciudad.'),
], '#FF8A65')
s = s[:a] + '<sc-if value="{{hasRoute}}" hint-placeholder-val="{{ true }}">' + seg + '</sc-if>' + s[foot:]

# La nota de "imágenes ilustrativas" pasa a ser el crédito de las fotos.
rep('Imágenes ilustrativas. En la app saldrán fotos reales con licencia libre.', '{{photoCredit}}')

# --- 8. Tus alertas de precio (las rutas que vigilas).
OFFERS = '<div style="display: flex; flex-direction: column; gap: 8px">\n<div class="q-offer"'
a = s.find(OFFERS)
assert a > 0
b = element_end(s, a)
first = s[a:b]
hit_svg = re.search(r'<span class="q-hit">(<svg.*?</svg>)EN OBJETIVO</span>', first, re.S).group(1)
s = s[:a] + (
    '<div style="display: flex; flex-direction: column; gap: 8px">\n'
    '<sc-for list="{{alerts}}" as="a" hint-placeholder-count="2"><div class="q-offer" onClick="{{a.open}}" style="{{a.style}}">\n'
    '<div style="display: flex; align-items: center; gap: 10px">\n'
    '<span aria-hidden="true" style="{{a.flag}}"></span>\n'
    '<span style="font-size: 14px; font-weight: 800; flex-grow: 1; min-width: 0">{{a.route}} <span style="font-weight: 600; color: #9FB0B8">{{a.target}}</span></span>'
    '<sc-if value="{{a.miss}}" hint-placeholder-val="{{ true }}"><span class="q-miss">AÚN LEJOS</span></sc-if>'
    '<sc-if value="{{a.hit}}" hint-placeholder-val="{{ false }}"><span class="q-hit">' + hit_svg + 'EN OBJETIVO</span></sc-if>'
    '<span style="{{a.pStyle}}">{{a.price}}</span>\n'
    '</div>\n'
    '<div class="q-track" role="img" aria-label="Precio actual frente al objetivo"><i style="{{a.track}}"></i></div>\n'
    '</div></sc-for>\n'
    '<sc-if value="{{noAlerts}}" hint-placeholder-val="{{ false }}"><div onClick="{{alertsTap}}" style="border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 12px 14px; font-size: 13px; line-height: 1.45; color: #B7C5CC; cursor: pointer">{{alertsNote}}</div></sc-if>\n'
    '</div>') + s[b:]

# --- 9. Fuera la barra de abajo de la maqueta (la app tiene la suya).
a = s.find('<nav aria-label="Principal"')
s = s[:a] + s[element_end(s, a):]

# --- 10. "¡VUELO CAZADO!" con tu chollo.
a = s.find('<sc-if value="{{showHunt}}"')
b = s.find('</sc-if>', a)
seg = s[a:b]
seg = svg_flag(seg, '<span aria-hidden="true" style="{{huntOFlagMid}}"></span>')
seg = svg_flag(seg, '<span aria-hidden="true" style="{{huntDFlagMid}}"></span>')
for old, new in [('\nMAD → HND\n', '\n{{huntO}} → {{huntD}}\n'),
                 ('text-decoration: line-through">950 €<', 'text-decoration: line-through">{{usual}}<'),
                 ('font-weight: 800">389 €<', 'font-weight: 800">{{price0}}<')]:
    assert seg.count(old) == 1, old
    seg = seg.replace(old, new)
s = s[:a] + seg + s[b:]

# --- 11. Ganga a medida: importes en tu moneda y sin la nota de ejemplo.
rep('<span>0 €</span><span>600 €</span><span>1.200 €</span>', '<span>{{gaMin}}</span><span>{{gaMid}}</span><span>{{gaTop}}</span>')
rep_re(r'<span style="font-size: 10.5px; color: #8FA3AD; text-align: center">Datos de ejemplo:[^<]*</span>\n?', '')

# --- 12. Aviso de Flyra: sin el botón de prueba; "Reintentar" vuelve a pedir.
rep_re(r'<button type="button" onClick="\{\{flyShow\}\}".*?PROBAR AVISO</button>', '', flags=re.S)
rep_re(r'onClick="\{\{flyHide\}\}"([^>]*>Reintentar)', r'onClick="{{flyRetry}}"\1')

# --- 14. "Compartir mi viaje" (decisión de DARIO: va aquí, en Vuelos). Una
# fila debajo de "Planea tu viaje", con el mismo estilo que sus botones (el
# morado de "Copiar viaje", el brillo que pasa y la entrada "pop").
a = s.find('class="q-grid"')
a = s.rfind('<', 0, a)
b = element_end(s, a)
share = (
    '<a class="q-chip" onClick="{{shareTrip}}" style="--c: #9B7BFF; --d: 4.2s; animation-delay: 0.46s; '
    'margin-top: -2px; display: flex; align-items: center; gap: 12px; border-radius: 22px; '
    'background: radial-gradient(120% 90% at 0% 0%, color-mix(in srgb, #9B7BFF 30%, transparent), transparent 60%), '
    'linear-gradient(160deg, #1c2b36, #0f1a22); border: 1px solid color-mix(in srgb, #9B7BFF 35%, #2a3b47); '
    'box-shadow: 0 14px 22px -12px rgba(0,0,0,0.8), inset 0 1px 0 rgba(255,255,255,0.13); padding: 12px 14px; '
    'text-decoration: none; color: #E8F1EE; cursor: pointer">'
    '<span class="q-ico" style="width: 40px; height: 40px; border-radius: 13px; flex-shrink: 0; display: flex; '
    'align-items: center; justify-content: center; background: radial-gradient(120% 100% at 30% 20%, #B69CFF 0%, '
    '#2A1A5A 100%); box-shadow: inset 0 1px 0 #ffffff55, 0 4px 10px -4px #9B7BFF">'
    '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="2.2" '
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="18" cy="5" r="3"></circle>'
    '<circle cx="6" cy="12" r="3"></circle><circle cx="18" cy="19" r="3"></circle>'
    '<path d="M8.6 13.5l6.8 4M15.4 6.5l-6.8 4"></path></svg></span>'
    '<span style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1; min-width: 0">'
    '<span style="font-size: 14px; font-weight: 800">Compartir mi viaje</span>'
    '<span style="font-size: 12px; font-weight: 600; color: #B7C5CC">Publícalo para que otros lo copien</span></span>'
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#B69CFF" stroke-width="2.4" '
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6"></path></svg></a>'
)
s = s[:b] + share + s[b:]

# --- 13. La lógica: la de la maqueta, pero con tus datos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
s = s[:a] + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s.lower()
for ok in ('por ejemplo madrid', 'por ejemplo tokio'):
    low = low.replace(ok, '')
assert 'ejemplo' not in low and 'probar aviso' not in low and 'claude.ai' not in low, \
    low[max(0, low.find('ejemplo') - 200):low.find('ejemplo') + 60]
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
