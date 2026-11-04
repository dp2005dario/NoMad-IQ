// Rellena la maqueta con TUS datos (los pone la app en window.ECL): la foto
// en miniatura de cada tarjeta, los datos en su dibujo, lo leído del PDF y
// las casillas del formulario (con la vista previa en vivo).
(function () {
  var E = window.ECL || {};
  var SL = E.slots || {};
  function q(s, r) { return (r || document).querySelector(s); }
  function qa(s, r) { return [].slice.call((r || document).querySelectorAll(s)); }
  function ini(t) { t = String(t || '').trim(); return t ? t[0].toUpperCase() : ''; }
  function split2(t) { var r = String(t || '').split(/\s*(?:→|->|–|—|-|\/)\s*/); return [r[0] || '', r[1] || '']; }
  // Qué texto va en cada hueco del dibujo de la tarjeta n con los datos v.
  window.cardVals = function (n, v) {
    v = v || []; var a = v[0] || '', b = v[1] || '', c = v[2] || '', r;
    switch (n) {
      case 1: return { num: b };
      case 2: r = split2(b); return { from: r[0], to: r[1], flight: [a ? 'VUELO ' + a : '', c ? 'ASIENTO ' + c : ''].filter(Boolean).join(' · ') };
      case 3: return { pol: a ? 'POL ' + a : '', until: b ? 'VÁLIDO HASTA ' + b : '' };
      case 4: return { name: a.toUpperCase(), num: b, blank: '', exp: c };
      case 5: return { mrz: ('V<' + a.toUpperCase().replace(/[^A-Z]/g, '').slice(0, 3) + '<<' + b.toUpperCase().replace(/[^A-Z0-9]/g, '') + '<<<<<<<<<<<<<<<<<<<<').slice(0, 21) };
      case 6: r = split2(b); return { hotel: a, in: r[0], out: r[1], conf: c ? 'Confirmación ' + c : '' };
      case 7: return { event: a, where: [b, c].filter(Boolean).join(' · ') };
      case 8: return { c1: a, i1: ini(a), i2: ini(b), i3: ini(c) };
      case 9: return { name: a.toUpperCase(), blank: '', exp: c ? 'Caduca ' + c : '', cls: b };
      case 10: return { num: a, exp: b ? 'CADUCA ' + b : '' };
      case 11: return { in: b, out: '', conf: c ? 'Reserva ' + c : '' };
      case 12: r = split2(a); var cp = String(c || '').split(/\s*·\s*/); return { from: r[0], to: r[1], seat: [b, cp[0] ? 'Coche ' + cp[0] : '', cp[1] ? 'Plaza ' + cp[1] : ''].filter(Boolean).join(' · ') };
      case 13: return { plan: [a, b].filter(Boolean).join(' · ') };
    }
    return {};
  };
  // La línea de abajo de una tarjeta guardada.
  window.cardLine = function (n, v, s) {
    v = v || []; var a = v[0] || '', b = v[1] || '', c = v[2] || '', t = '';
    switch (n) {
      case 1: t = b; break;
      case 2: t = b || a; break;
      case 3: t = a ? 'Póliza ' + a : ''; break;
      case 4: t = a; break;
      case 5: t = a; break;
      case 6: t = b || a; break;
      case 7: t = b || a; break;
      case 8: var k = [a, b, c].filter(Boolean).length; t = k ? k + (k === 1 ? ' contacto' : ' contactos') : ''; break;
      case 9: t = b ? 'Clase ' + b : ''; break;
      case 10: t = b ? 'Caduca ' + b : ''; break;
      case 11: t = b ? 'Recogida ' + b : ''; break;
      case 12: t = a; break;
      case 13: t = a; break;
    }
    return t || (s && s.pdf ? 'PDF guardado' : s && s.g ? 'Foto guardada' : '');
  };
  function paint(root, n, v) {
    var m = window.cardVals(n, v);
    qa('[data-f]', root).forEach(function (el) { var k = el.getAttribute('data-f'); if (k in m) el.textContent = m[k]; });
  }
  window.formValues = function (n) {
    var box = qa('.bv-fl' + n)[1];
    return qa('[data-in]', box).map(function (i) { return i.value.trim().slice(0, 80); });
  };
  window.foundValues = function () { return (E.found || []).slice(0, 3).map(function (x) { return String(x || ''); }); };
  // Los datos van a la app en base64url (solo letras, números, - y _).
  window.pack = function (v) {
    var b = btoa(unescape(encodeURIComponent(JSON.stringify(v))));
    return b.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  window.toApp = function (m) { try { if (window.ECLIPTA) window.ECLIPTA.postMessage(m); } catch (e) {} };
  function fill() {
    if (!q('.bv-root')) return false;
    for (var n = 1; n <= 13; n++) {
      var s = SL[n] || {};
      var card = q('.bv-doc' + n);
      if (card) {
        paint(q('.bv-fil', card), n, s.v);
        var df = q('.e_df', card); if (df) df.textContent = window.cardLine(n, s.v, s);
        var th = q('.e_thumb', card); if (th && s.thumb) th.src = s.thumb;
      }
      // El formulario: tus datos (o lo leído del PDF) y la vista previa.
      var start = (E.sd === n && (E.found || []).some(Boolean)) ? E.found : (s.v || []);
      var box = qa('.bv-fl' + n)[1];
      var prev = q('.bv-sdocf' + n);
      (function (n, box, prev) {
        var ins = qa('[data-in]', box);
        ins.forEach(function (i, k) {
          i.value = start[k] || '';
          i.addEventListener('input', function () { paint(prev, n, window.formValues(n)); });
        });
        paint(prev, n, ins.map(function (i) { return i.value; }));
      })(n, box, prev);
    }
    // Lo leído del PDF.
    var f = E.found || [];
    var sd = qa('.bv-fl' + (E.sd || 1))[0];
    qa('[data-found]', sd).forEach(function (el) { var k = +el.getAttribute('data-found'); el.textContent = f[k] || '—'; });
    var nf = f.filter(Boolean).length;
    var ef = q('#e_found'); if (ef) ef.textContent = nf === 1 ? '1 dato encontrado' : nf + ' datos encontrados';
    qa('.e_file').forEach(function (el) { el.textContent = E.file || ''; });
    if (E.msg) toast(E.msg);
    return true;
  }
  function toast(t) {
    var e = document.createElement('div');
    e.textContent = t;
    e.setAttribute('role', 'status');
    e.style.cssText = 'position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:99;max-width:320px;background:rgba(8,16,20,.96);border:1px solid #3DDC97;color:#F2F5F3;padding:9px 14px;border-radius:14px;font:700 12px Manrope,system-ui,sans-serif;text-align:center;transition:opacity .4s';
    document.body.appendChild(e);
    setTimeout(function () { e.style.opacity = '0'; }, 3200);
  }
  (function wait(k) { if (!fill() && k < 200) setTimeout(function () { wait(k + 1); }, 30); })(0);
})();
