# Crea assets/money/divisas.html a partir de la maqueta "Cambio de moneda".
# Uso:
#   python3 tool/divisas/build_page.py <Divisas.dc.html> <support.js> assets/money/divisas.html
#
# Se queda TODO lo de la maqueta (la cantidad, las monedas con bandera, la
# moneda que se lanza y gira en 3D, "Cómo llevarlo en efectivo" con sus tres
# formas y las fotos de billetes y monedas) y solo se quitan los datos de
# ejemplo, el botón de probar el aviso y las notas para DARIO (licencias,
# "VERIFICADO"...). Los tipos de cambio y las fotos los pone la app
# (lib/features/money/fx_page.dart) en la marca /*ECLIPTA*/; las fotos de
# cada moneda llegan después con window.ECLin({...}) al elegirla.
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


DATA = re.compile(r"url\('(data:[^']*)'\)")

# --- 2. Cabecera: sin "EJEMPLO"; la fecha de los tipos de verdad.
rep('>Pantalla 16 · tipos de EJEMPLO<', '>{{subTitle}}<')
cut_element('>DATOS DE EJEMPLO</div>', '<div')
# La cara de Flyra de la nota: la misma del aviso (va dentro, sin Internet).
flyra = re.search(r'<span class="fly-av"[^>]*><img src="(data:image/[^"]+)"', s).group(1)
rep('src="/_blob/1ff4e21dc5f936eb6eddcb7cb40b0441"', 'src="' + flyra + '"')

# --- 3. Fuera las notas para DARIO (licencias de las fotos, "VERIFICADO").
cut_element('{{stageNote}}</div>', '<div')
cut_element('{{verText}}</div>', '<div')
cut_element('{{imgNote}}</div>', '<div')

# --- 4. El aviso de Flyra: sale solo sin conexión (y "Reintentar" reintenta).
cut_element('>PROBAR AVISO</button>', '<button')
s = s.replace('<button type="button" onClick="{{flyHide}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FFB86B; color: #1A0B0B">Reintentar</button>',
              '<button type="button" onClick="{{flyRetry}}" style="height: 38px; border-radius: 12px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; border: none; background: #FFB86B; color: #1A0B0B">Reintentar</button>', 1)
assert '{{flyRetry}}' in s
rep('>Uso el último tipo de cambio guardado y te enseño su fecha. Puede haber cambiado.<', '>{{flyTxt}}<')

# --- 5. La lógica: la de la maqueta, con los tipos y las fotos de la app.
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
lg = s[a:b]


def lrep(old, new, count=1):
    global lg
    assert lg.count(old) == count, (lg.count(old), old[:120])
    lg = lg.replace(old, new)


lrep("this.state = { flyOn: false, amount: 50, from: 'EUR', to: 'GBP', phase: 'idle', show: true, sheet: '', combo: 0 };",
     "// Lo de la app: window.ECL (ver lib/features/money/fx_page.dart).\n"
     "this.E = window.ECL || {};\n"
     "this.state = { flyOn: !!this.E.offline, amount: 50, from: this.E.from || 'EUR', to: this.E.to || 'GBP', phase: 'idle', show: true, sheet: '', combo: 0, k: 0 };\n"
     "}\n"
     "componentDidMount() {\n"
     "// Lo que llega después (los tipos, las fotos de otra moneda): sin recargar.\n"
     "window.ECLin = (d) => { const ph = Object.assign({}, this.E.ph || {}, (d || {}).ph || {}); Object.assign(this.E, d || {}); this.E.ph = ph; this.setState({ k: this.state.k + 1, flyOn: !!this.E.offline && this.state.flyOn }); };")
# Los tipos: los del BCE que manda la app (unidades por 1 euro).
lrep("const codes = Object.keys(D);",
     "const RT = this.E.rates || {};\n"
     "Object.keys(D).forEach((c) => { D[c].r = RT[c] || 0; D[c].ecb = RT[c] ? 1 : 0; });\n"
     "const codes = Object.keys(D);")
lrep("const rate = b.r / a.r;", "const ok = a.r > 0 && b.r > 0;\nconst rate = ok ? b.r / a.r : 0;")
# Las fotos: las medidas de la maqueta y la foto que manda la app.
pa = lg.find('const PH = {')
pb = lg.find('const MOT = {')
ph = re.sub(r"'/_blob/[0-9a-f]{32}'", '1', lg[pa:pb])
assert '/_blob/' not in ph
ph = ph.replace('const PH = {', 'const PHM = {', 1)
ph += ("// Solo las fotos que ha mandado la app (las de las monedas elegidas).\n"
       "const PH = {};\n"
       "Object.keys(PHM).forEach((c) => { const p = (this.E.ph || {})[c]; if (!p) return; const m = PHM[c]; const notes = {}, coins = {};\n"
       "  Object.keys(m.notes).forEach((v) => { if (p.n && p.n[v]) notes[v] = [p.n[v], m.notes[v][1]]; });\n"
       "  Object.keys(m.coins).forEach((v) => { if (p.m && p.m[v]) coins[v] = p.m[v]; });\n"
       "  PH[c] = { spin: p.s || '', notes, coins, size: m.size, nw: m.nw }; });\n")
lg = lg[:pa] + ph + lg[pb:]
lrep("photo: (PH[code] && PH[code].spin) || PH.EUR.spin,", "photo: (PH[code] && PH[code].spin) || '',")
# Al cambiar de moneda, la app manda sus fotos.
lrep("this.setState({ from, to, phase: 'idle', sheet: '' }); };",
     "this.setState({ from, to, phase: 'idle', sheet: '' }); toApp('pair:0:' + pack({ f: from, t: to })); };")
# Notas para DARIO fuera; las de verdad, con la fecha de los tipos.
ia = lg.find('const IMG_NOTE = {')
ib = lg.find('const srcNote =')
ie = lg.find('\n', ib)
lg = (lg[:ia] +
      "const day = this.E.day || '';\n"
      "const noEcb = [st.from, st.to].filter((c, i, arr) => !D[c].ecb && arr.indexOf(c) === i);\n"
      "const srcNote = 'Tipo oficial del Banco Central Europeo' + (day ? ' del ' + day : '') + '. Los bancos y casas de cambio aplican su propia comisión, así que el dinero que recibas será algo menor.' + (noEcb.length ? ' ' + noEcb.join(', ') + ': el BCE no lo publica, así que no puedo convertirlo.' : '');"
      + lg[ie:])
lrep("rateLabel: '1 ' + a.sym + ' = ' + new Intl.NumberFormat('es-ES', { maximumFractionDigits: rate >= 100 ? 1 : 4 }).format(rate) + ' ' + b.sym + ' (ejemplo · 28-10-2026 00:02 UTC)',",
     "rateLabel: ok ? '1 ' + a.sym + ' = ' + new Intl.NumberFormat('es-ES', { maximumFractionDigits: rate >= 100 ? 1 : 4 }).format(rate) + ' ' + b.sym + ' (BCE' + (day ? ' · ' + day : '') + ')' : 'Sin datos del tipo de cambio entre ' + st.from + ' y ' + st.to + '.',\n"
     "subTitle: day ? 'Tipos del BCE del ' + day : (this.E.failed ? 'Sin tipos de cambio' : 'Buscando los tipos del BCE…'),\n"
     "flyTxt: 'Uso el último tipo de cambio guardado, del ' + (day || '?') + '. Puede haber cambiado.',\n"
     "flyRetry: () => { this.setState({ flyOn: false }); toApp('retry'); },")
lrep("imgNote, stageNote, verText, verColor: (b.vn && b.vc) ? '#7FE8B9' : '#FFB86B',", '')
lrep("resultLabel: money(target / mul, st.to),", "resultLabel: ok ? money(target / mul, st.to) : 'Sin datos',")
lrep("const summary = cur.out.length ?", "const summary = !ok ? 'Sin el tipo de cambio no puedo repartirlo en billetes.' : cur.out.length ?")
lrep("flyShow: () => this.setState({ flyOn: true }),\n", '')
# Los comentarios de la maqueta que eran notas para DARIO (licencias, etc.).
lg = '\n'.join(l for l in lg.split('\n') if not (l.lstrip().startswith('//') and re.search(r'EJEMPLO|VERIFICAD|MAQUETA|licencia|Fotos reales', l)))
lg = lg.replace('renderVals() {\n', 'renderVals() {\n// Las monedas de la maqueta. "r" (unidades por 1 euro) lo pone la app.\n', 1)
s = s[:a] + lg + s[b:]

low = s[s.find('</head>'):]
for bad in ('ejemplo', 'EJEMPLO', '/_blob/', 'SOLO MAQUETA', 'NO VERIFICADO', 'PROBAR AVISO', '28-10-2026', 'open.er-api'):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
