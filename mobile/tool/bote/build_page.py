# Crea assets/money/bote.html a partir de la maqueta "Bote común".
# Uso:
#   python3 tool/bote/build_page.py <Bote.dc.html> <support.js> assets/money/bote.html
#
# Se queda TODO lo de la maqueta (el frasco que se llena y se vacía con
# monedas, quién ha puesto, gastar del bote, los avisos de Flyra, el modo
# pareja con la cuerda y "Añadir gasto") y solo se quitan los datos de
# ejemplo, las notas "son de ejemplo", el botón de probar el aviso (ahora
# "Comprobar el bote" de verdad) y el de volver al ejemplo. Lo de verdad lo
# pone la app (lib/features/money/kitty_page.dart) en la marca /*ECLIPTA*/
# y lo que llega después entra con window.ECLin({...}) sin recargar.
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
rep('<div class="{{rootCls}}" style="width: 390px;', '<div id="q-root" class="{{rootCls}}" style="width: 390px;')

# --- 2. Volver.
rep('<a href="Gastos.dc.html" aria-label="Volver" style="', '<a onClick="{{back}}" aria-label="Volver" style="cursor: pointer; ')

# --- 3. Bote del grupo: tu bote de verdad (o por qué no hay).
rep('color: #FFB86B">BOTE LISBOA · 4 PERSONAS<', 'color: #FFB86B; cursor: pointer" onClick="{{pickPot}}">{{potHead}}<')
rep('{{shownTxt}}</span><span style="font-size: 18px; font-weight: 800; color: #FFD9A8">€</span>',
    '{{shownTxt}}</span><span style="font-size: 18px; font-weight: 800; color: #FFD9A8">{{curTxt}}</span>')
rep('{{totalTxt}} de 480 €</b>', '{{totalTxt}} {{goalOf}}</b>')
a = s.find('<sc-if value="{{isPot}}" hint-placeholder-val="{{ true }}">') + len('<sc-if value="{{isPot}}" hint-placeholder-val="{{ true }}">')
b = s.find('</sc-if><sc-if value="{{isCouple}}"')
s = (s[:a] + '<sc-if value="{{noPot}}" hint-placeholder-val="{{ false }}"><div style="border-radius: 20px; background: #141E25; border: 1px solid #26363F; padding: 14px; font-size: 13px; line-height: 1.45; color: #DCE5E9">{{potNote}}</div></sc-if>'
     '<sc-if value="{{hasPot}}" hint-placeholder-val="{{ true }}">' + s[a:b] + '</sc-if>' + s[b:])
rep_ej = re.compile(r'<span style="[^"]*">Personas, importes y datos de Bizum son de ejemplo\.</span>')
s, n = rep_ej.subn('', s)
assert n == 1
rep('quien guarda el bote (aquí, Ana) por Bizum', 'quien guarda el bote por Bizum')
rep('Al enviarlo se apunta aquí y el frasco se llena. Ana confirma que le ha llegado.', 'Al enviarlo se apunta aquí y el frasco se llena.')
rep('>Comprobar con Ana (probar aviso)<', '>Comprobar el bote<')
rep('y Flyra avisa al grupo. Al final', 'y Flyra te lo cuenta. Al final')

# --- 4. Modo pareja: vuestro bote de dos (o por qué no hay).
a = s.find('<sc-if value="{{isCouple}}" hint-placeholder-val="{{ false }}">') + len('<sc-if value="{{isCouple}}" hint-placeholder-val="{{ false }}">')
b = element_end(s, a)
s = (s[:a] + '<sc-if value="{{noCouple}}" hint-placeholder-val="{{ false }}"><div style="border-radius: 20px; background: #141E25; border: 1px solid #26363F; padding: 14px; font-size: 13px; line-height: 1.45; color: #DCE5E9">{{coupleNote}}</div></sc-if>'
     '<sc-if value="{{hasCouple}}" hint-placeholder-val="{{ false }}">' + s[a:b] + '</sc-if>' + s[b:])
rep('box-shadow: 0 0 0 3px #1E1620">D</span>', 'box-shadow: 0 0 0 3px #1E1620">{{meIni}}</span>')
rep('box-shadow: 0 0 0 3px #1E1620">N</span>', 'box-shadow: 0 0 0 3px #1E1620">{{otIni}}</span>')
rep('>Dario y Noelia · Roma<', '>{{cpTitle}}<')
rep('>Día 3 de 5 · gastado juntos <b style="color: #F2F5F3">{{cpTotal}} €</b>', '>Gastado juntos <b style="color: #F2F5F3">{{cpTotal}} {{curTxt}}</b>')
rep('>DARIO HA PAGADO<', '>{{meUp}}<')
rep('>NOELIA HA PAGADO<', '>{{otUp}}<')
rep('>{{cpD}} €<', '>{{cpD}} {{curTxt}}<')
rep('>{{cpN}} €<', '>{{cpN}} {{curTxt}}<')
s, n = re.subn(r'(<span class="\{\{pullL\}\}"[^>]*>)D(</span>)', r'\1{{meIni}}\2', s)
assert n == 1
s, n = re.subn(r'(<span class="\{\{pullR\}\}"[^>]*>)N(</span>)', r'\1{{otIni}}\2', s)
assert n == 1
a = s.find('<button type="button" onClick="{{cpReset}}"')
s = s[:a] + s[element_end(s, a):]
a = s.rfind('<div', 0, s.find('>PLAN PARA ESTA NOCHE<'))
s = s[:a] + s[element_end(s, a):]
s, n = re.subn(r'<span style="[^"]*">Gastos, importes y datos de Bizum son de ejemplo\.</span>', '', s)
assert n == 1

# --- 5. Poner tu parte: los datos para enviarla (la app no mueve dinero).
rep('>Pon tu parte: 20 €<', '>{{putTitle}}<')
rep('>ECLIPTA no guarda dinero. Lo envías tú a Ana, que lleva el bote. Te dejamos los datos copiados para pegarlos en Bizum (Bizum no deja abrirse con el importe ya puesto).<',
    '>ECLIPTA no guarda dinero. Lo envías tú a quien lleva el bote, por Bizum o transferencia. Al confirmarlo se apunta aquí y el frasco se llena.<')
rep('>Ana · guarda el bote<', '>Quien guarda el bote<')
rep('>6•• ••• 412 (ejemplo)<', '>Pídele su número<')
rep('>Bote Lisboa · Dario<', '>{{putWhat}}<')
rep('>20,00 €<', '>{{putAmt}}<')
rep('>Ya lo he enviado por Bizum<', '>Ya lo he enviado<')
rep('>Lo apunta</span><span style="font-weight: 800">Dario<', '>Lo apunta</span><span style="font-weight: 800">{{fmWho}}<')

# --- 6. Los avisos de Flyra con lo que pasa de verdad.
rep('>Aviso enviado al grupo<', '>Apuntado en el bote<')
rep('>Pedir 20 € más a cada uno<', '>Pedir 20 {{curTxt}} más a cada uno<')
rep('>Roma · ajuste de pareja<', '>{{sWhat}}<')
rep('>La app no mueve el dinero: se envía por Bizum o transferencia. Te dejamos los datos copiados (Bizum no deja abrirse con el importe ya puesto).<',
    '>La app no mueve el dinero: se envía por Bizum o transferencia. Al confirmarlo se apunta aquí y la cuerda vuelve al centro.<')
rep('>Sofía aún no ha puesto su parte<', '>{{remName}} aún no ha puesto su parte<')
rep('>Faltan sus 120 € para llenar el bote. Le mando un aviso con los datos de Ana para que haga el Bizum.<',
    '>{{remMiss}} Te preparo un mensaje para que se lo mandes.<')
rep('>Aviso enviado a Sofía<', '>Mensaje para {{remName}}<')
rep('>Te digo algo en cuanto lo ponga.<', '>Elige por dónde mandárselo.<')
rep('>Ana ha confirmado tus 20 €<', '>{{okTitle}}<')
rep('>Ya le ha llegado el Bizum. Tu parte está completa.<', '>Ya están en el bote.<')
rep('>Ana tiene {{leftNum}} € y aquí salen los mismos. Todo apuntado.<', '>En el bote hay {{leftNum}} {{curTxt}} y aquí salen los mismos. Todo apuntado.<')
rep('>Ana tiene {{anaHas}} € y aquí deberían quedar {{leftNum}} €. Seguramente falta apuntar un gasto de 14 €.<',
    '>En el bote hay {{anaHas}} {{curTxt}} y aquí deberían quedar {{leftNum}} {{curTxt}}. Seguramente falta apuntar un gasto de {{gapTxt}} {{curTxt}}.<')
rep('>Apuntar 14 €<', '>Apuntar {{gapTxt}} {{curTxt}}<')

# --- 7. La lógica: la de la maqueta, con tus datos (logic.js).
a = s.find('class Component extends DCLogic {')
b = s.find('</script>', a)
s = s[:a] + open(os.path.join(here, 'logic.js'), encoding='utf-8').read() + s[b:]

low = s[s.find('</head>'):]
for bad in ('ejemplo', '.dc.html', 'Noelia', 'Dario', 'Sofía', 'Lisboa', 'Roma', 'Ana '):
    i = low.find(bad)
    assert i < 0, (bad, low[max(0, i - 200):i + 60])
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, 'w', encoding='utf-8').write(s)
print('ok', len(s))
