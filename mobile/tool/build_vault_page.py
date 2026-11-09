# Crea assets/vault/boveda.html a partir de la maqueta "Bóveda".
# Uso: python3 tool/build_vault_page.py <Boveda.dc.html> <support.js> assets/vault/boveda.html
#
# Se queda TODO lo de la maqueta (la puerta acorazada que se abre con la
# huella, el tesoro, las 13 tarjetas por grupos, el menú Cámara / Galería /
# PDF / A mano, la lectura del PDF, el aviso de Flyra si el PDF no sirve y
# el formulario con la vista previa) y solo se quitan los datos de ejemplo y
# las notas para DARIO. Lo real lo pone la app (lib/features/vault/
# vault_page.dart) en la marca /*ECLIPTA*/:
#   - la huella de verdad (la del sistema) y el cierre a los 2 minutos;
#   - tus documentos (cifrados en el móvil): la foto en miniatura y los
#     datos que escribes o que se leen del PDF;
#   - la cámara, la galería y el selector de PDF son los del móvil.
import re
import sys

src, runtime, dst = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding='utf-8').read()
rt = open(runtime, encoding='utf-8').read()


def rep(old, new, count=1):
    global s
    assert s.count(old) >= count, old[:90]
    s = s.replace(old, new) if count == 0 else s.replace(old, new, count)


def rep_all(old, new):
    global s
    assert old in s, old[:90]
    s = s.replace(old, new)


# --- El motor de la maqueta (React + plantillas) va dentro: sin Internet.
# "<!--", "<script" y "</script" dentro del código confunden al navegador al
# leer la página: se escriben con \x3c (es lo mismo dentro de un texto JS).
rt_safe = rt.replace('<!--', '\\x3c!--').replace('<script', '\\x3cscript').replace('</script', '\\x3c/script')
rep('<script src="./support.js"></script>',
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
    '<script>window.ECL=/*ECLIPTA*/{"phase":"locked","slots":{},"found":[],"file":"","msg":""};</script>\n'
    '<script>' + rt_safe + '</script>')
# Que ocupe toda la pantalla del móvil (la maqueta mide 390 × 844).
rep('body{margin:0}', 'html,body{margin:0;height:100%;background:#050708;overflow:hidden}')

# --- Fuera los datos de ejemplo y las notas para DARIO.
rep_all('>TU FOTO<', '><')
rep_all('>DATOS · EJEMPLO<', '><')
rep('>FOTO DE EJEMPLO · SIMULADA<', '><')
rep('>3 datos encontrados · de ejemplo<', '><span id="e_found"></span><')
rep('>Vista previa: así queda la tarjeta con tus datos (ejemplo)<', '>Vista previa: así queda la tarjeta con tus datos<')
rep('<span class="bv-fnok">reserva.pdf · prueba</span><span class="bv-fnbad">carta-restaurante.pdf · prueba</span>',
    '<span class="bv-fnok e_file"></span><span class="bv-fnbad e_file"></span>')
s = re.sub(r'(<span class="bv-df"[^>]*>)([^<]*)(</span>)', r'\1<span class="e_df"></span>\3', s)

# --- La foto de cada tarjeta (.bv-ph): en vez del dibujo de ejemplo, tu
# foto en miniatura (la pone la página).
def thumbs():
    global s
    out, pos = [], 0
    for m in re.finditer(r'<span class="bv-ph"[^>]*>', s):
        a = m.end()
        b = element_end(s, a)
        out.append(s[pos:a] + '<img class="e_thumb" alt="" style="width: 100%; height: 100%; object-fit: cover; display: block">')
        pos = b
    assert len(out) == 13
    s = ''.join(out) + s[pos:]


# --- Las 13 tarjetas: los textos de ejemplo de los dibujos "con datos"
# (.bv-fil y la vista previa .bv-sdocf) pasan a ser huecos que rellena la
# página con TUS datos (data-f = qué dato va ahí).
FILL = {
    1: [('XX0000000', 'num')],
    2: [('>MAD<', 'from'), ('>NRT<', 'to'), ('VUELO XX123 · ASIENTO 23A', 'flight')],
    3: [('POL 4471 0092', 'pol'), ('VÁLIDO HASTA 30/04/2027', 'until')],
    4: [('ALEX EJEMPLO', 'name'), ('00000000T', 'num'), ('>ESP<', 'blank'), ('01/01/1990', 'exp')],
    5: [('V&lt;USAEJEMPLO&lt;&lt;ALEX&lt;&lt;&lt;', 'mrz')],
    6: [('Hotel Ejemplo · 3 noches', 'hotel'), ('>12/03<', 'in'), ('>15/03<', 'out'), ('Confirmación HX4821', 'conf')],
    7: [('>Concierto<', 'event'), ('14/03 · Puerta 4 · Fila 12', 'where')],
    8: [('Ejemplo · 600 000 000', 'c1'), ('>A<', 'i1'), ('>B<', 'i2'), ('>C<', 'i3')],
    9: [('ALEX EJEMPLO', 'name'), ('00000000T', 'blank'), ('Caduca 2031', 'exp'), ('>B<', 'cls')],
    10: [('8072 4000 0000', 'num'), ('CADUCA 31/12/2029', 'exp')],
    11: [('>12/03<', 'in'), ('>15/03<', 'out'), ('Reserva CR-2291', 'conf')],
    12: [('>MAD<', 'from'), ('>BCN<', 'to'), ('12/03 · Coche 5 · Plaza 7A', 'seat')],
    13: [('10 GB · Japón', 'plan')],
}


def element_end(text, start):
    """Dónde acaba el elemento que empieza en [start] (contando etiquetas)."""
    depth = 0
    for m in re.finditer(r'<(/?)([a-zA-Z][\w-]*)[^>]*?(/?)>', text[start:]):
        if m.group(3) == '/':
            continue
        depth += 1 if m.group(1) == '' else -1
        if depth == 0:
            return start + m.end()
    raise AssertionError('sin cierre')


def fill_block(cls, n):
    global s
    a = s.find(f'class="{cls}"' if cls != 'bv-fil' else 'class="bv-fil"', 0)
    if cls == 'bv-fil':
        # La .bv-fil de la tarjeta n está dentro de su botón .bv-docN.
        b0 = s.rfind('<', 0, s.find(f'class="bv-doc bv-doc{n}"'))
        b1 = element_end(s, b0)
        a = s.find('class="bv-fil"', b0)
        assert b0 < a < b1
    a = s.rfind('<', 0, a)
    b = element_end(s, a)
    seg = s[a:b]
    for old, key in FILL[n]:
        assert old in seg, (cls, n, old)
        seg = seg.replace(old, (('>' if old.startswith('>') else '') + f'<tspan data-f="{key}"></tspan>' + ('<' if old.endswith('<') else '')), 1)
    s = s[:a] + seg + s[b:]


thumbs()
for n in FILL:
    fill_block('bv-fil', n)
    fill_block(f'bv-sdocf bv-sdocf{n}', n)

# --- Lo encontrado en el PDF (lista con ✓) y el formulario "A mano":
# los valores de ejemplo pasan a ser los tuyos y casillas para escribir.
for n in range(1, 14):
    blocks = [m.start() for m in re.finditer(f'class="bv-fl bv-fl{n}"', s)]
    assert len(blocks) == 2, n
    # 1) La lista de lo leído en el PDF.
    a = s.rfind('<', 0, blocks[0])
    b = element_end(s, a)
    seg = s[a:b]
    k = [0]

    def found(m):
        k[0] += 1
        return f'{m.group(1)}<span data-found="{k[0] - 1}"></span></span>'

    seg = re.sub(r'(<span style="font-size: 13px; font-weight: 800">)[^<]*</span>', found, seg)
    assert k[0] == 3, n
    s = s[:a] + seg + s[b:]
    # 2) El formulario: casillas de verdad.
    blocks = [m.start() for m in re.finditer(f'class="bv-fl bv-fl{n}"', s)]
    a = s.rfind('<', 0, blocks[1])
    b = element_end(s, a)
    seg = s[a:b]
    k = [0]

    def box(m):
        k[0] += 1
        return (m.group(1)[:-1].replace('<span style="height: 40px;', '<input data-in="' + str(k[0] - 1) + '" style="height: 40px; width: 100%; box-sizing: border-box; color: #F2F5F3; font-family: inherit; outline: none;')
                + ' />')

    seg = re.sub(r'(<span style="height: 40px; border-radius: 12px; border: 1px solid #33444E; background: #141E25; display: flex; align-items: center; padding: 0 12px; font-size: 14px; font-weight: 700">)[^<]*</span>', box, seg)
    assert k[0] == 3, n
    s = s[:a] + seg + s[b:]

# --- La lógica: el estado empieza donde lo deja la app y cada botón le
# pide a la app lo que es de verdad (huella, cámara, galería, PDF, guardar).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
s = s[:a] + open(__file__.replace('build_vault_page.py', 'vault_logic.js'), encoding='utf-8').read() + s[b:]

# --- Rellenar los huecos con tus datos (lo hace la página al dibujarse).
rep('</body>', '<script>' + open(__file__.replace('build_vault_page.py', 'vault_fill.js'), encoding='utf-8').read() + '</script>\n</body>')

# El menú de "archivos de prueba" de la maqueta no se usa (la app abre el
# selector de PDF del móvil), pero tampoco se deja su texto de prueba.
rep('>Archivos de prueba de la maqueta: en la app real se abre el selector de tu móvil<', '><')
rep('>Prueba: PDF correcto<', '><')
rep('>Prueba: PDF que no sirve<', '><')
rep('>reserva.pdf<', '><')
rep('>carta-restaurante.pdf<', '><')

low = s.lower()
assert 'ejemplo' not in low and 'prueba' not in low, s[low.find('ejemplo') - 200:low.find('ejemplo') + 60]
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
