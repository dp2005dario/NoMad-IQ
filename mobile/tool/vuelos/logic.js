class Component extends DCLogic {
// Lo que pinta la maqueta "Cazador de vuelos" con TUS datos. La app los pone
// en window.ECL (ver lib/features/flights/flights_page.dart) y, sin recargar
// la página, manda lo que llega después (precios del calendario, fichas de
// ciudad) con window.ECLin({...}). La página le pide cosas a la app con
// toApp("aviso") (ver flights_screen.dart).
constructor(props) {
super(props);
const E = window.ECL || {};
this.E = E;
// Los nombres (ciudad y país en español) salen de la lista de aeropuertos.
const by = window.AP_BY || {};
this.ccName = {};
(window.AP || []).forEach((a) => { if (a[4] && !this.ccName[a[4]]) this.ccName[a[4]] = a[3]; });
const ap = (c) => by[c] || [c, c, c, '', '', [], 0];
(E.deals || []).forEach((x) => {
const o = ap(x.o), d = ap(x.d);
x.oPlace = x.oPlace || (o[2] + (o[3] ? ', ' + o[3] : ''));
x.dPlace = x.dPlace || (d[2] + (d[3] ? ', ' + d[3] : ''));
x.occ = x.occ || o[4]; x.dcc = x.dcc || d[4];
const R = x.route;
if (R) {
[['o', o], ['d', d]].forEach(([k, a]) => { R[k].city = R[k].city || a[2]; R[k].country = R[k].country || a[3]; R[k].cc = R[k].cc || a[4]; });
R.o.time = R.o.time || this.utc(R.o.off, R.o.alt);
R.d.time = R.d.time || this.diff(R.d.off - R.o.off, R.o.city);
R.regions = (R.regions || []).map((r) => [r[0], r[1] === '^' ? 'Despegando de ' + R.o.city : r[1] === '$' ? 'Llegando a ' + R.d.city : r[1] ? 'Sobrevolando ' + (this.ccName[r[1]] || r[1]) : 'Sobrevolando el océano']);
}
});
(E.alerts || []).forEach((a) => { a.cc = a.cc || ap(a.d || '')[4]; });
if (!E.fromCity && E.origin) E.fromCity = ap(E.origin)[2];
// Precios del calendario ya recibidos: "MAD-HND-ow-2027-3" → {día: céntimos}.
this.cal = {};
this.asked = {};
// Fichas de ciudad (origen y destino de la ruta), cuando lleguen.
this.fichas = {};
const hunt = (E.deals || [])[0] || null;
const today = E.today || Math.floor(Date.now() / 86400000);
this.state = { hunt: hunt, day: hunt ? hunt.sel : 0, bars: hunt ? hunt.bars : [], showHunt: !!hunt, view: 'world', t: 0, follow: false, clock: 0,
srO: E.origin || null, srOq: E.origin ? this.apName(E.origin) : '', srD: null, srDq: '', srFocus: null, srTrip: 'rt', srAd: 1, srKi: 0, srPax: false, srCal: false, srM: 0,
srDep: null, srRet: null, srDone: false, srGoMsg: '', srGoOk: false, gaOpen: false, gaStep: 'ask', gaMax: 300, showFail: false, flyOn: !!E.fly, tick: 0, today: today };
}
componentDidMount() {
window.ECLin = (d) => this.fromApp(d || {});
this.globeTimer = setInterval(() => {
if (this.state.view === 'world') this.setState({ clock: this.state.clock + 1 });
}, 50);
const h = this.state.hunt;
if (h) this.askCal(h.o, h.d, h.ow, h.y, h.m);
}
componentWillUnmount() {
clearInterval(this.globeTimer);
clearTimeout(this.replayTimer);
clearInterval(this.tick);
clearTimeout(this.wait);
this.gaStop();
}
// Lo que manda la app después de pintar la página.
fromApp(d) {
if (d.cal) { this.cal[d.cal.k] = d.cal.p || {}; this.setState({ tick: this.state.tick + 1 }); this.syncBars(); }
if (d.ficha) { this.fichas[d.ficha.side] = d.ficha; this.setState({ tick: this.state.tick + 1 }); }
if (d.fly !== undefined) this.setState({ flyOn: !!d.fly });
}
calKey(o, d, ow, y, m) { return o + '-' + d + '-' + (ow ? 'ow' : 'rt') + '-' + y + '-' + m; }
askCal(o, d, ow, y, m) {
if (!o || !d || o === d) return;
const k = this.calKey(o, d, ow, y, m);
if (this.asked[k]) return;
this.asked[k] = 1;
toApp('cal:0:' + pack({ k: k, o: o, d: d, ow: !!ow, y: y, m: m }));
}
// Las barras del chollo: el precio de cada día de su mes (si ya llegó).
syncBars() {
const h = this.state.hunt;
if (!h) return;
const p = this.cal[this.calKey(h.o, h.d, h.ow, h.y, h.m)];
if (!p) return;
const days = Object.keys(p).map(Number).sort((a, b) => a - b);
if (!days.length) return;
let from = Math.max(0, days.indexOf(h.day) - 10);
const pick = days.slice(from, from + 21);
if (pick.indexOf(h.day) < 0) return;
const bars = pick.map((dd) => ({ d: dd, p: p[dd] }));
this.setState({ bars: bars, day: pick.indexOf(h.day) });
}
fmt(minor, cur) {
const E = this.E;
const c = cur || (this.state.hunt && this.state.hunt.cur) || E.cur || 'EUR';
const exp = (E.exp && E.exp[c] !== undefined) ? E.exp[c] : 2;
const v = Math.round(minor / Math.pow(10, exp));
try { return new Intl.NumberFormat(E.locale || 'es-ES', { style: 'currency', currency: c, maximumFractionDigits: 0, minimumFractionDigits: 0 }).format(v); } catch (e) { return v + ' ' + c; }
}
stopFlight() {
clearInterval(this.tick);
clearTimeout(this.wait);
}
startFlight() {
this.stopFlight();
this.setState({ view: 'flight', t: 0, follow: false });
this.wait = setTimeout(() => {
this.setState({ follow: true });
this.tick = setInterval(() => {
const t = Math.min(1, this.state.t + 0.005);
if (t >= 1) {
clearInterval(this.tick);
this.setState({ t: 1, view: 'dest', follow: false });
this.ficha('d');
} else {
this.setState({ t });
}
}, 50);
}, 900);
}
// La ficha de la ciudad (la pide la app al servidor la primera vez).
ficha(side) {
if (this.fichas[side] || this['f_' + side]) return;
this['f_' + side] = 1;
toApp('ficha:' + (side === 'o' ? 0 : 1));
}
// ---- Ganga a medida: el chollo más bajado que no pase de tu máximo.
gaStop() { clearTimeout(this.gaT1); clearTimeout(this.gaT2); clearTimeout(this.gaT3); }
gaFind(max) {
const deals = this.E.deals || [];
const ok = deals.filter((x) => x.pm <= max * Math.pow(10, (this.E.exp || {})[x.cur] ?? 2));
ok.sort((a, b) => b.drop - a.drop || a.pm - b.pm);
return ok[0] || null;
}
gaRunNow() {
this.gaStop();
this.setState({ gaOpen: true, gaStep: 'load' });
this.gaT1 = setTimeout(() => {
const found = this.gaFind(this.state.gaMax);
if (found) {
// Hay ganga: se relanza la animación de vuelo cazado con ESE chollo.
this.setState({ gaOpen: false, gaStep: 'ask', showHunt: false, hunt: found, bars: found.bars, day: found.sel, view: 'world', t: 0 });
this.stopFlight();
this.fichas = {}; this.f_o = 0; this.f_d = 0;
toApp('hunt:' + found.i);
this.askCal(found.o, found.d, found.ow, found.y, found.m);
const el = document.getElementById('q-scroll');
if (el && el.scrollTo) el.scrollTo({ top: 0, behavior: 'smooth' });
clearTimeout(this.replayTimer);
this.replayTimer = setTimeout(() => this.setState({ showHunt: true }), 60);
} else {
// Sin ganga: el avión cae y luego el mensaje con "subir el máximo".
this.setState({ gaOpen: false, gaStep: 'ask', showFail: false });
this.gaT2 = setTimeout(() => this.setState({ showFail: true }), 60);
this.gaT3 = setTimeout(() => this.setState({ showFail: false, gaOpen: true, gaStep: 'fail' }), 7100);
}
}, 2800);
}
gangaVals() {
const st = this.state;
const cur = (st.hunt && st.hunt.cur) || this.E.cur || 'EUR';
const exp = (this.E.exp || {})[cur] ?? 2;
const lab = (n) => this.fmt(n * Math.pow(10, exp), cur);
const pct = Math.round(st.gaMax / 1200 * 100);
const n = (this.E.deals || []).filter((x) => x.pm <= st.gaMax * Math.pow(10, (this.E.exp || {})[x.cur] ?? 2)).length;
return {
gaOpen: () => this.setState({ gaOpen: true, gaStep: 'ask' }),
gaClose: () => { this.gaStop(); this.setState({ gaOpen: false, gaStep: 'ask', showFail: false }); },
gaRun: () => this.gaRunNow(),
gaRaise: () => { this.setState({ gaMax: Math.min(1200, this.state.gaMax + 100) }); setTimeout(() => this.gaRunNow(), 0); },
gaIn: (e) => this.setState({ gaMax: Number(e && e.target ? e.target.value : 300) }),
showFail: st.showFail, gaAsk: st.gaOpen && st.gaStep === 'ask', gaLoad: st.gaOpen && st.gaStep === 'load', gaFail: st.gaOpen && st.gaStep === 'fail',
gaLabel: lab(st.gaMax), gaVal: st.gaMax, gaMin: lab(0), gaMid: lab(600), gaTop: lab(1200),
gaTrack: 'background: linear-gradient(90deg, #6CA8FF 0%, #3DDC97 ' + pct + '%, #26363F ' + pct + '%)',
gaHint: n === 1 ? 'Hay 1 chollo de hoy por debajo de este importe.' : n > 1 ? 'Hay ' + n + ' chollos de hoy por debajo de este importe.' : 'Con este importe aún no sale ningún chollo de hoy. Prueba a subirlo.'
};
}
// "UTC+1 (+2 en verano)": la hora de ahora y la de la otra mitad del año.
utc(off, alt) {
if (off === undefined || off === null) return 'Sin datos';
const h = (m) => (m < 0 ? '−' : '+') + (Math.abs(m) % 60 ? (Math.abs(m) / 60).toLocaleString('es-ES') : Math.abs(m) / 60);
let out = 'UTC' + (off === 0 ? '' : h(off));
if (alt !== undefined && alt !== null && alt !== off) out += ' (' + (alt === 0 ? '0' : h(alt)) + (alt > off ? ' en verano' : ' en invierno') + ')';
return out;
}
// "8 h más que Madrid" / "La misma hora que Madrid".
diff(m, city) {
if (isNaN(m)) return 'Sin datos';
if (m === 0) return 'La misma hora que ' + city;
const n = (Math.abs(m) / 60).toLocaleString('es-ES');
return n + ' h ' + (m > 0 ? 'más' : 'menos') + ' que ' + city;
}
apName(code) { const a = (window.AP_BY || {})[code]; return a ? a[1] : code; }
airports() { return window.AP || []; }
// Banderas dibujadas con degradados (aproximadas, sin escudos)
flagBg(cc) {
const F = {
ES: 'linear-gradient(#AA151B 25%,#F1BF00 25% 75%,#AA151B 75%)',
PT: 'linear-gradient(90deg,#046A38 40%,#DA291C 40%)',
FR: 'linear-gradient(90deg,#1F3E9E 33.3%,#fff 33.3% 66.6%,#E1283A 66.6%)',
IT: 'linear-gradient(90deg,#009246 33.3%,#fff 33.3% 66.6%,#CE2B37 66.6%)',
DE: 'linear-gradient(#000 33.3%,#DD0000 33.3% 66.6%,#FFCE00 66.6%)',
GB: 'linear-gradient(#C8102E,#C8102E) center/100% 22% no-repeat, linear-gradient(#C8102E,#C8102E) center/18% 100% no-repeat, linear-gradient(#fff,#fff) center/100% 40% no-repeat, linear-gradient(#fff,#fff) center/32% 100% no-repeat, #012169',
US: 'linear-gradient(#3C3B6E,#3C3B6E) top left/45% 54% no-repeat, repeating-linear-gradient(#B22234 0 7.7%,#fff 7.7% 15.4%)',
JP: 'radial-gradient(circle,#BC002D 0 26%,#fff 28%)',
NL: 'linear-gradient(#AE1C28 33.3%,#fff 33.3% 66.6%,#21468B 66.6%)',
BE: 'linear-gradient(90deg,#000 33.3%,#FDDA24 33.3% 66.6%,#EF3340 66.6%)',
CH: 'linear-gradient(#fff,#fff) center/60% 18% no-repeat, linear-gradient(#fff,#fff) center/18% 60% no-repeat, #DA291C',
AT: 'linear-gradient(#ED2939 33.3%,#fff 33.3% 66.6%,#ED2939 66.6%)',
GR: 'repeating-linear-gradient(#0D5EAF 0 11.1%,#fff 11.1% 22.2%)',
MT: 'linear-gradient(90deg,#fff 50%,#CF142B 50%)',
TR: 'radial-gradient(circle at 40% 50%,#fff 0 22%,transparent 24%), #E30A17',
MA: 'radial-gradient(circle,#006233 0 18%,transparent 20%), #C1272D',
EG: 'linear-gradient(#CE1126 33.3%,#fff 33.3% 66.6%,#000 66.6%)',
AE: 'linear-gradient(90deg,#CE1126 25%,transparent 25%), linear-gradient(#00732F 33.3%,#fff 33.3% 66.6%,#000 66.6%)',
TH: 'linear-gradient(#A51931 17%,#F4F5F8 17% 33%,#2D2A4A 33% 67%,#F4F5F8 67% 83%,#A51931 83%)',
MY: 'linear-gradient(#010066,#010066) top left/50% 54% no-repeat, repeating-linear-gradient(#CC0001 0 7.1%,#fff 7.1% 14.2%)',
SG: 'linear-gradient(#EF3340 50%,#fff 50%)',
CN: 'radial-gradient(circle at 25% 30%,#FFDE00 0 14%,transparent 16%), #DE2910',
KR: 'radial-gradient(circle,#CD2E3A 0 20%,transparent 22%), #fff',
MX: 'linear-gradient(90deg,#006847 33.3%,#fff 33.3% 66.6%,#CE1126 66.6%)',
AR: 'linear-gradient(#74ACDF 33.3%,#fff 33.3% 66.6%,#74ACDF 66.6%)',
BR: 'radial-gradient(circle,#002776 0 20%,transparent 22%), radial-gradient(ellipse,#FFDF00 0 60%,transparent 62%), #009C3B',
CO: 'linear-gradient(#FCD116 50%,#003893 50% 75%,#CE1126 75%)',
IE: 'linear-gradient(90deg,#169B62 33.3%,#fff 33.3% 66.6%,#FF883E 66.6%)',
PL: 'linear-gradient(#fff 50%,#DC143C 50%)',
SE: 'linear-gradient(#FECC02,#FECC02) 32% 0/12% 100% no-repeat, linear-gradient(#FECC02,#FECC02) 0 50%/100% 20% no-repeat, #006AA7',
DK: 'linear-gradient(#fff,#fff) 32% 0/12% 100% no-repeat, linear-gradient(#fff,#fff) 0 50%/100% 20% no-repeat, #C60C30',
NO: 'linear-gradient(#002868,#002868) 32% 0/8% 100% no-repeat, linear-gradient(#002868,#002868) 0 50%/100% 12% no-repeat, linear-gradient(#fff,#fff) 31% 0/14% 100% no-repeat, linear-gradient(#fff,#fff) 0 50%/100% 24% no-repeat, #BA0C2F',
FI: 'linear-gradient(#003580,#003580) 32% 0/12% 100% no-repeat, linear-gradient(#003580,#003580) 0 50%/100% 20% no-repeat, #fff',
CZ: 'linear-gradient(to bottom right,#11457E 50%,transparent 50%) left/50% 100% no-repeat, linear-gradient(#fff 50%,#D7141A 50%)',
HU: 'linear-gradient(#CE2939 33.3%,#fff 33.3% 66.6%,#477050 66.6%)',
RO: 'linear-gradient(90deg,#002B7F 33.3%,#FCD116 33.3% 66.6%,#CE1126 66.6%)',
RU: 'linear-gradient(#fff 33.3%,#0039A6 33.3% 66.6%,#D52B1E 66.6%)',
UA: 'linear-gradient(#0057B7 50%,#FFD700 50%)',
IN: 'radial-gradient(circle,#000080 0 12%,transparent 14%), linear-gradient(#FF9933 33.3%,#fff 33.3% 66.6%,#138808 66.6%)',
CA: 'linear-gradient(90deg,#D80621 25%,#fff 25% 75%,#D80621 75%)',
AU: 'linear-gradient(#012169,#012169)',
PE: 'linear-gradient(90deg,#D91023 33.3%,#fff 33.3% 66.6%,#D91023 66.6%)',
CL: 'linear-gradient(#0039A6,#0039A6) top left/33% 50% no-repeat, linear-gradient(#fff 50%,#D52B1E 50%)',
CU: 'repeating-linear-gradient(#002A8F 0 20%,#fff 20% 40%)',
IS: 'linear-gradient(#DC1E35,#DC1E35) 32% 0/8% 100% no-repeat, linear-gradient(#DC1E35,#DC1E35) 0 50%/100% 12% no-repeat, linear-gradient(#fff,#fff) 31% 0/14% 100% no-repeat, linear-gradient(#fff,#fff) 0 50%/100% 24% no-repeat, #02529C',
HR: 'linear-gradient(#FF0000 33.3%,#fff 33.3% 66.6%,#171796 66.6%)',
QA: 'linear-gradient(90deg,#fff 30%,#8A1538 30%)',
IL: 'linear-gradient(#fff 15%,#0038B8 15% 25%,#fff 25% 75%,#0038B8 75% 85%,#fff 85%)',
VN: 'radial-gradient(circle,#FFFF00 0 20%,transparent 22%), #DA251D',
ID: 'linear-gradient(#FF0000 50%,#fff 50%)'
};
return 'width: 26px; height: 18px; border-radius: 3px; flex-shrink: 0; box-shadow: 0 0 0 1px rgba(255,255,255,0.2); background: ' + (F[cc] || '#2A3E63');
}
// La bandera en otro tamaño (la misma de arriba).
flag(cc, w, h, r) { return this.flagBg(cc).replace('width: 26px; height: 18px; border-radius: 3px', 'width: ' + w + 'px; height: ' + h + 'px; border-radius: ' + r + 'px'); }
srNorm(s) { return (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim(); }
// Autocompletado por texto: ciudad, alias, palabras del aeropuerto, pais o (como ultimo recurso) codigo
srSuggest(q) {
const n = this.srNorm(q);
const AP = this.airports();
if (!n) return AP.filter((a) => a[6]).slice(0, 6);
const sc = [];
AP.forEach((a) => {
let s = 0;
if (a[0].toLowerCase() === n) s = 120;
else if (this.srNorm(a[2]).startsWith(n) || a[5].some((x) => this.srNorm(x).startsWith(n))) s = 100 + (a[6] ? 5 : 0);
else if (this.srNorm(a[1]).split(/[\s\-()]+/).some((w) => w.startsWith(n))) s = 70;
else if (this.srNorm(a[3]).startsWith(n)) s = 50 + (a[6] ? 5 : 0);
else if (n.length > 2 && this.srNorm(a[2]).includes(n)) s = 30;
if (s) sc.push([s, a]);
});
sc.sort((x, y) => y[0] - x[0]);
return sc.slice(0, 7).map((x) => x[1]);
}
searchVals() {
const st = this.state;
const by = window.AP_BY || {};
const MES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const MESL = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];
const ord = (y, m, d) => Math.round(Date.UTC(y, m, d) / 86400000);
const TODAY = st.today;
const T0 = new Date(TODAY * 86400000);
const lab = (o) => { if (!o) return 'Elegir'; const dt = new Date(o * 86400000); return dt.getUTCDate() + ' ' + MES[dt.getUTCMonth()]; };
const iso = (o) => new Date(o * 86400000).toISOString().slice(0, 10);
const O = by[st.srO];
const D = by[st.srD];
const rt = st.srTrip === 'rt';
// Calendario de precios: el más barato de cada día (lo pide la app).
const y = T0.getUTCFullYear() + Math.floor((T0.getUTCMonth() + st.srM) / 12);
const m = (T0.getUTCMonth() + st.srM) % 12;
const P = (O && D) ? this.cal[this.calKey(O[0], D[0], !rt, y, m + 1)] : null;
if (st.srCal && O && D && O[0] !== D[0]) this.askCal(O[0], D[0], !rt, y, m + 1);
const price = (o) => { const dt = new Date(o * 86400000); if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m || !P) return null; const v = P[dt.getUTCDate()]; return v === undefined ? null : v; };
const pick = (code) => () => {
const f = this.state.srFocus;
const a = by[code];
if (f === 'o') this.setState({ srO: code, srOq: a[1], srFocus: null, srDone: false });
else this.setState({ srD: code, srDq: a[1], srFocus: null, srDone: false });
};
const focus = st.srFocus;
const q = focus === 'o' ? (st.srO ? '' : st.srOq) : focus === 'd' ? (st.srD ? '' : st.srDq) : '';
const showSug = focus !== null && (focus === 'o' ? !st.srO : !st.srD);
const list = showSug ? this.srSuggest(q) : [];
const sugs = list.map((a) => ({ name: a[1], where: a[2] + ', ' + a[3], code: a[0], flag: this.flagBg(a[4]), aria: a[1] + ', ' + a[2] + ', ' + a[3], pick: pick(a[0]) }));
const days = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
const first = (new Date(Date.UTC(y, m, 1)).getUTCDay() + 6) % 7;
let mn = 1e15, mx = 0;
for (let d = 1; d <= days; d++) { const o = ord(y, m, d); if (o < TODAY) continue; const p = price(o); if (p === null) continue; mn = Math.min(mn, p); mx = Math.max(mx, p); }
const lo = mn + (mx - mn) * 0.25;
const hi = mn + (mx - mn) * 0.75;
const cells = [];
for (let i = 0; i < first; i++) cells.push({ day: '', price: '', off: true, aria: '', pick: () => {}, style: 'visibility: hidden; height: 46px', pStyle: '' });
for (let d = 1; d <= days; d++) {
const o = ord(y, m, d);
const p = price(o);
const past = o < TODAY;
const isDep = o === st.srDep;
const isRet = rt && o === st.srRet;
const inR = rt && st.srRet && o > st.srDep && o < st.srRet;
let bg = '#101A21'; let bd = 'transparent'; let col = '#F2F5F3'; let pc = '#B7C5CC';
const cheap = !past && p !== null && mx > mn && p <= lo;
const dear = !past && p !== null && mx > mn && p >= hi;
if (cheap) { bg = 'rgba(61,220,151,0.10)'; bd = '#2E7A57'; pc = '#7FE8B9'; }
else if (dear) { bg = 'rgba(255,138,101,0.10)'; bd = 'rgba(255,138,101,0.45)'; pc = '#FFB86B'; }
if (inR) { bg = 'rgba(108,168,255,0.22)'; bd = '#35507F'; }
if (isDep || isRet) { bg = '#6CA8FF'; bd = '#6CA8FF'; col = '#0B1217'; pc = '#0B1217'; }
cells.push({
day: String(d), price: past ? '' : p === null ? (P ? '—' : '') : this.fmt(p), off: past,
aria: d + ' de ' + MESL[m] + (past ? ', no disponible' : p === null ? ', sin precio' : ', desde ' + this.fmt(p)) + (cheap ? ', de los más baratos' : dear ? ', de los más caros' : ''),
style: 'height: 46px; border-radius: 10px; border: 1px solid ' + bd + '; background: ' + bg + '; color: ' + col + '; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; font-family: inherit; padding: 0; cursor: ' + (past ? 'default' : 'pointer') + '; opacity: ' + (past ? 0.35 : 1),
pStyle: 'font-size: 9.5px; font-weight: 800; line-height: 1; color: ' + pc + '; font-variant-numeric: tabular-nums',
pick: () => {
if (past) return;
if (!rt) this.setState({ srDep: o, srRet: null, srCal: false, srDone: false });
else if (!this.state.srDep || this.state.srRet || o <= this.state.srDep) this.setState({ srDep: o, srRet: null, srDone: false });
else this.setState({ srRet: o, srCal: false, srDone: false });
}
});
}
const pax = st.srAd + st.srKi;
const paxLabel = st.srAd + (st.srAd === 1 ? ' adulto' : ' adultos') + (st.srKi ? ' · ' + st.srKi + (st.srKi === 1 ? ' niño' : ' niños') : '');
const pDep = st.srDep ? price(st.srDep) : null;
let summary = 'Elige la fecha de ida.';
if (O && D && st.srCal && !P) summary = 'Buscando el precio de cada día…';
else if (st.srDep && !rt) summary = 'Solo ida · ' + lab(st.srDep) + (pDep !== null ? ' · desde ' + this.fmt(pDep) + ' por persona.' : '.');
else if (st.srDep && !st.srRet) summary = 'Ida el ' + lab(st.srDep) + '. Ahora elige la vuelta.';
else if (st.srDep && st.srRet) summary = lab(st.srDep) + ' → ' + lab(st.srRet) + ' · ' + (st.srRet - st.srDep) + ' noches' + (pDep !== null ? ' · ida y vuelta desde ' + this.fmt(pDep * pax) + ' para ' + pax + (pax === 1 ? ' pasajero' : ' pasajeros') : '') + '.';
const pill = (on) => 'border: ' + (on ? 'none' : '1px solid #2A3E63') + '; background: ' + (on ? '#F2F5F3' : '#0E1828') + '; color: ' + (on ? '#0B1217' : '#DCE5E9');
const dateBtn = (on) => 'border: 1px solid ' + (on ? '#6CA8FF' : '#2A3E63') + '; background: #0E1828; box-shadow: ' + (on ? '0 0 0 3px rgba(108,168,255,0.2)' : 'none');
const navStyle = (dis) => 'opacity: ' + (dis ? 0.3 : 1) + '; pointer-events: ' + (dis ? 'none' : 'auto');
const swap = () => {
const s = this.state;
this.setState({ srO: s.srD, srOq: s.srDq, srD: s.srO, srDq: s.srOq, srFocus: null, srDone: false });
};
const typed = (f) => (e) => {
const v = e && e.target ? e.target.value : '';
if (f === 'o') this.setState({ srOq: v, srO: null, srFocus: 'o', srDone: false });
else this.setState({ srDq: v, srD: null, srFocus: 'd', srDone: false });
};
const onFocus = (f) => (e) => {
if (e && e.target && e.target.select) e.target.select();
this.setState({ srFocus: f, srPax: false });
};
const go = () => {
const s = this.state;
let msg = ''; let ok = false;
if (!O || !D) msg = 'Elige origen y destino de la lista de sugerencias.';
else if (O[0] === D[0]) msg = 'El origen y el destino son el mismo. Cambia uno.';
else if (!s.srDep) { msg = 'Elige la fecha de ida.'; this.setState({ srCal: true }); }
else if (rt && !s.srRet) { msg = 'Elige también la fecha de vuelta.'; this.setState({ srCal: true }); }
else ok = true;
if (ok) {
// Los vuelos de verdad los busca la app (y salen en su pantalla).
this.setState({ srDone: false, srFocus: null });
toApp('go:0:' + pack({ o: O[0], d: D[0], dep: iso(s.srDep), ret: rt ? iso(s.srRet) : '', ad: s.srAd, ki: s.srKi }));
return;
}
this.setState({ srDone: true, srGoMsg: msg, srGoOk: false, srFocus: null });
};
const step = (k, d, min, max) => () => this.setState({ [k]: Math.max(min, Math.min(max, this.state[k] + d)) });
return {
srOq: st.srOq, srDq: st.srDq, srOIn: typed('o'), srDIn: typed('d'), srOFocus: onFocus('o'), srDFocus: onFocus('d'),
srOFlag: O ? this.flagBg(O[4]) : 'display: none', srDFlag: D ? this.flagBg(D[4]) : 'display: none',
srOCode: O ? O[0] : '—', srDCode: D ? D[0] : '—',
srSugs: sugs, srShowSug: showSug, srNoSug: showSug && sugs.length === 0,
srSugHead: (focus === 'o' ? 'ORIGEN' : 'DESTINO') + (q ? ' · SUGERENCIAS' : ' · POPULARES'),
srSwap: swap, srIsRT: rt, srRtStyle: pill(rt), srOwStyle: pill(!rt),
srSetRT: () => this.setState({ srTrip: 'rt', srDone: false }),
srSetOW: () => this.setState({ srTrip: 'ow', srRet: null, srDone: false }),
srPaxLabel: paxLabel, srPaxOpen: st.srPax, srTogglePax: () => this.setState({ srPax: !this.state.srPax, srFocus: null }),
srAdults: st.srAd, srKids: st.srKi,
srAMinus: step('srAd', -1, 1, 9), srAPlus: () => this.setState({ srAd: Math.min(9 - this.state.srKi, this.state.srAd + 1) }), srKMinus: step('srKi', -1, 0, 8), srKPlus: () => this.setState({ srKi: Math.min(9 - this.state.srAd, this.state.srKi + 1) }),
srDepLabel: lab(st.srDep), srRetLabel: lab(st.srRet), srDepStyle: dateBtn(st.srCal && !(rt && st.srDep && !st.srRet)), srRetStyle: dateBtn(st.srCal && rt && st.srDep && !st.srRet),
srToggleCal: () => this.setState({ srCal: !this.state.srCal, srFocus: null }),
srCalOpen: st.srCal, srCalTitle: MESL[m] + ' ' + y, srCells: cells, srCalSummary: summary,
srPrevM: () => this.setState({ srM: Math.max(0, this.state.srM - 1) }), srNextM: () => this.setState({ srM: Math.min(11, this.state.srM + 1) }),
srPrevStyle: navStyle(st.srM === 0), srNextStyle: navStyle(st.srM === 11),
srGo: go, srSearched: st.srDone, srMsg: st.srGoMsg,
srMsgStyle: 'border-radius: 14px; padding: 10px 12px; font-size: 12.5px; line-height: 1.45; font-weight: 700; animation: q-pop 0.4s ease both; border: 1px solid ' + (st.srGoOk ? 'rgba(61,220,151,0.45)' : 'rgba(255,138,101,0.5)') + '; background: ' + (st.srGoOk ? 'rgba(61,220,151,0.10)' : 'rgba(255,138,101,0.10)') + '; color: ' + (st.srGoOk ? '#BFF3DA' : '#FFD2C2')
};
}
// La ruta del chollo en el globo, el vuelo y las fichas de las dos ciudades.
routeVals() {
const st = this.state;
const h = st.hunt;
const R = h ? h.route : null;
const E = this.E;
const out = { hasRoute: !!R };
const { view, t } = st;
const space = view === 'world';
const clock = st.clock ?? 0;
const spin = 38 * Math.sin(clock / 70);
const GC = [179, 185], GR = 135, TILT = 0.72;
const C = R ? R.c : 62;
const proj = (lat, lon, alt) => {
const th = (lon - C + spin) * Math.PI / 180, la = lat * Math.PI / 180, r = GR * (alt || 1);
const up = Math.sin(la) * Math.cos(TILT) - Math.cos(la) * Math.cos(th) * Math.sin(TILT);
const z = Math.cos(la) * Math.cos(th) * Math.cos(TILT) + Math.sin(la) * Math.sin(TILT);
return [GC[0] + r * Math.cos(la) * Math.sin(th), GC[1] - r * up, z];
};
const hide = 'position: absolute; left: 0; top: 0; opacity: 0; pointer-events: none';
const gmon = (k) => {
const M = R && R.mons[k];
if (!M) return hide;
const [x, y, z] = proj(M[0], M[1]);
if (!space || z < 0.04) return hide;
const ang = Math.atan2(x - GC[0], GC[1] - y) * 180 / Math.PI;
const s = 0.34 + 0.3 * z;
const sy = 0.6 + 0.4 * Math.sqrt(Math.max(0, 1 - z * z));
return 'position: absolute; left: ' + (x - 50).toFixed(1) + 'px; top: ' + (y - 116).toFixed(1) + 'px; width: 100px; height: 120px; transform-origin: 50% 96.7%; transform: rotate(' + (ang * 0.55).toFixed(1) + 'deg) scale(' + s.toFixed(3) + ', ' + (s * sy).toFixed(3) + '); opacity: ' + Math.min(1, z * 5).toFixed(2) + '; z-index: 7; pointer-events: none';
};
const W = 0.16;
const mon = (k) => {
const M = R && R.mons[k];
if (!M) return hide;
const t0 = M[2], side = M[3];
const p = (t - t0 + W) / W;
if (space || p < 0 || p > 1.3) return hide;
const q = p * p;
const s = 0.16 + q * 1.15;
const x = 179 + side * (44 + q * 150);
const y = 112 + q * 205;
const op = p < 0.12 ? p / 0.12 : p > 1.05 ? Math.max(0, (1.3 - p) / 0.25) : 1;
return 'position: absolute; left: ' + (x - 50).toFixed(1) + 'px; top: ' + (y - 120).toFixed(1) + 'px; width: 100px; height: 120px; transform-origin: 50% 100%; --inv: ' + (1 / s).toFixed(3) + '; --lab: ' + (p > 0.95 ? 0 : 1) + '; transform: scale(' + s.toFixed(3) + '); opacity: ' + op.toFixed(2) + '; z-index: ' + Math.round(q * 10) + '; transition: all 0.06s linear; pointer-events: none';
};
const pin = (P) => {
if (!P) return hide;
const [x, y, z] = proj(P.lat, P.lon);
return 'position: absolute; z-index: 8; left: ' + (x - 22).toFixed(1) + 'px; top: ' + (y - 22).toFixed(1) + 'px; width: 44px; height: 44px; border: none; background: transparent; padding: 0; cursor: pointer; ' + (space && z > 0.05 ? 'opacity: 1' : 'opacity: 0; pointer-events: none');
};
// El camino del avión: el arco de círculo máximo entre las dos ciudades.
let routeD = '';
if (R) {
const rad = Math.PI / 180;
const v = (P) => [Math.cos(P.lat * rad) * Math.cos(P.lon * rad), Math.cos(P.lat * rad) * Math.sin(P.lon * rad), Math.sin(P.lat * rad)];
const A = v(R.o), B = v(R.d);
const dot = Math.max(-1, Math.min(1, A[0] * B[0] + A[1] * B[1] + A[2] * B[2]));
const w = Math.acos(dot);
let pen = false;
for (let i = 0; i <= 40; i++) {
const k = i / 40;
const sa = w < 1e-6 ? 1 - k : Math.sin((1 - k) * w) / Math.sin(w), sb = w < 1e-6 ? k : Math.sin(k * w) / Math.sin(w);
const X = sa * A[0] + sb * B[0], Y = sa * A[1] + sb * B[1], Z = sa * A[2] + sb * B[2];
const lat = Math.atan2(Z, Math.sqrt(X * X + Y * Y)) / rad, lon = Math.atan2(Y, X) / rad;
const [x, y, z] = proj(lat, lon, 1.05);
if (z > 0) { routeD += (pen ? ' L' : ' M') + x.toFixed(1) + ' ' + y.toFixed(1); pen = true; } else { pen = false; }
}
}
const keys = ['palacio', 'alcala', 'eiffel', 'branden', 'basilio', 'muralla', 'fuji', 'ttower'];
keys.forEach((k) => { out['gm_' + k] = gmon(k); out['mon_' + k] = mon(k); });
let region = '';
if (R) { for (const r of R.regions) { if (t >= r[0]) region = r[1]; } }
const leftMin = R ? Math.round((1 - t) * R.min) : 0;
const fic = (side) => {
const F = this.fichas[side];
const P = R ? R[side] : null;
const wait = F ? null : '…';
const pl = F && F.places ? F.places.map((x, i) => ({ name: x.name, desc: x.desc || '', img: 'display: block; width: 150px; height: 96px; background: ' + (x.img ? '#0F171D url(' + JSON.stringify(x.img) + ') center/cover no-repeat' : '#1A2630'), open: () => toApp('photo:' + (side === 'o' ? 0 : 1) + ':' + i) })) : [];
const o = {};
o[side + 'Country'] = P ? P.country : '';
o[side + 'City'] = P ? P.city : '';
o[side + 'Capital'] = wait || F.capital || 'Sin datos';
o[side + 'Lang'] = wait || F.lang || 'Sin datos';
o[side + 'Cur'] = wait || F.cur || 'Sin datos';
o[side + 'Time'] = P ? P.time : '';
o[side + 'Culture'] = wait || F.culture || 'Sin datos';
o[side + 'Why'] = wait || F.why || 'Sin datos';
o[side + 'Places'] = pl;
o[side + 'NoPlaces'] = !!F && pl.length === 0;
o[side + 'Loading'] = !F;
o[side + 'FlagBig'] = this.flag(P ? P.cc : '', 54, 36, 6) + '; box-shadow: 0 3px 10px rgba(0,0,0,0.35)';
o[side + 'FlagSm'] = this.flag(P ? P.cc : '', 18, 12, 2);
return o;
};
Object.assign(out, fic('o'), fic('d'));
const ON = R ? R.o.city : '', DN = R ? R.d.city : '';
Object.assign(out, {
rO: R ? R.o.iata : '', rD: R ? R.d.iata : '',
routeD: routeD || 'M0 0',
pinMad: pin(R && R.o), pinHnd: pin(R && R.d),
pinOAria: 'Ver la ficha de ' + ON + ', origen', pinDAria: 'Ver la ficha de ' + DN + ', destino',
zoomLabel: view === 'world' ? 'Toca ' + (R ? R.o.iata : '') + ' o ' + (R ? R.d.iata : '') + ' en el globo' : view === 'origin' ? ON + ' desde el aire' : view === 'dest' ? DN + ' desde el aire' : 'Cámara detrás del avión',
regionLabel: region,
kmLabel: Math.round(t * (R ? R.km : 0)).toLocaleString('es-ES') + ' km',
leftLabel: Math.floor(leftMin / 60) + ' h ' + (leftMin % 60) + ' min',
photoCredit: E.credit || 'Fotos de Wikimedia Commons y textos de Wikipedia, con licencia libre. Toca una foto para ver su autor.'
});
return out;
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const h = st.hunt;
const bars0 = st.bars || [];
const sel = Math.min(st.day, Math.max(0, bars0.length - 1));
const max = bars0.reduce((a, b) => Math.max(a, b.p), 1) * 1.1;
const cheapCut = h ? h.usualMinor * 0.6 : 0;
const MESL = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const dayLabel = (d) => d + ' de ' + (h ? MESL[h.m - 1] : '');
const bars = bars0.map((b, i) => ({
label: dayLabel(b.d) + ': ' + this.fmt(b.p),
pick: () => this.setState({ day: i }),
style: 'flex: 1; border: none; padding: 0; border-radius: 4px; cursor: pointer; height: ' + Math.max(4, Math.round((b.p / max) * 56)) + 'px; background: ' + (i === sel ? (b.p < cheapCut ? '#7FE8B9' : '#FFFFFF') : (b.p < cheapCut ? '#3E7F66' : '#2E4672'))
}));
const colors = ['#FF8A65', '#6CA8FF', '#3DDC97', '#FFB86B', '#B69CFF', '#F1BF00'];
const confetti = Array.from({ length: 18 }, (_, i) => {
const a = (i / 18) * Math.PI * 2;
const r = 120 + (i % 3) * 30;
return { style: 'position: absolute; left: -5px; top: -5px; width: ' + (i % 2 ? 10 : 7) + 'px; height: ' + (i % 2 ? 6 : 10) + 'px; border-radius: 2px; background: ' + colors[i % colors.length] + '; --dx: ' + Math.round(Math.cos(a) * r) + 'px; --dy: ' + Math.round(Math.sin(a) * r) + 'px; animation: nq-burst 1.6s cubic-bezier(.1,.7,.3,1) 2.9s both' };
});
// El precio que se ve: el del día elegido en las barras (o el del chollo).
const bp = bars0[sel];
const pMinor = bp ? bp.p : h ? h.pm : 0;
const dSel = bp ? bp.d : h ? h.day : 0;
const LAND = "radial-gradient(ellipse 34% 22% at 22% 30%, #4F8A4E 0 55%, transparent 72%), radial-gradient(ellipse 22% 30% at 70% 22%, #8A7A4E 0 50%, transparent 70%), radial-gradient(ellipse 28% 18% at 60% 70%, #4B7F45 0 55%, transparent 72%), radial-gradient(ellipse 16% 22% at 12% 78%, #6E8F4A 0 50%, transparent 70%), radial-gradient(ellipse 12% 8% at 88% 52%, #E9EEF2 0 50%, transparent 70%), radial-gradient(ellipse 20% 12% at 40% 52%, #3E7444 0 55%, transparent 72%), linear-gradient(#1D5C9C, #1A4F88)";
const LIGHTS = "radial-gradient(circle at 20% 30%, #FFD27A 0 1.2px, transparent 2px), radial-gradient(circle at 62% 70%, #FFD27A 0 1px, transparent 2px), radial-gradient(circle at 70% 24%, #FFE3A3 0 1.4px, transparent 2.4px), radial-gradient(circle at 36% 54%, #FFD27A 0 1px, transparent 2px)";
const SKY = [[0, '#3F86DA', '#BFE0FF'], [0.42, '#2C3E7A', '#F4A261'], [0.58, '#050A1C', '#1B2B55'], [0.8, '#050A1C', '#1B2B55'], [0.93, '#3B4F8F', '#FFC78A'], [1, '#5FA0E8', '#D6ECFF']];
const hex = (x) => [1, 3, 5].map((i) => parseInt(x.slice(i, i + 2), 16));
const mix = (a, b, k) => { const A = hex(a), B = hex(b); return 'rgb(' + A.map((v, i) => Math.round(v + (B[i] - v) * k)).join(',') + ')'; };
const skyAt = (x) => { let i = 0; while (i < SKY.length - 2 && x > SKY[i + 1][0]) i++; const a = SKY[i], b = SKY[i + 1]; const k = Math.max(0, Math.min(1, (x - a[0]) / (b[0] - a[0]))); return [mix(a[1], b[1], k), mix(a[2], b[2], k)]; };
const { view, t } = st;
const space = view === 'world';
const sky = space ? ['#020611', '#0A1430'] : skyAt(t);
const night = space ? 0 : Math.max(0, Math.min(1, t < 0.5 ? (t - 0.4) / 0.12 : (0.9 - t) / 0.1));
const clock = st.clock ?? 0;
const spin = 38 * Math.sin(clock / 70);
const ph = clock * 0.03;
const front = Math.sin(ph) > 0;
const os = 0.45 + 0.55 * (Math.sin(ph) + 1) / 2;
const ox = 179 + 205 * Math.cos(ph), oy = 168 + 60 * Math.sin(ph) - 34 * Math.cos(ph);
const flying = view === 'flight';
const bank = flying ? Math.sin(t * 14) * 5 : 0;
const E = this.E;
const alerts = (E.alerts || []).map((a, i) => ({
route: a.route, target: a.target, price: a.price, hit: a.hit, miss: !a.hit,
style: '--c: ' + (a.hit ? '#3DDC97' : '#6CA8FF') + '; animation-delay: ' + (0.15 + i * 0.12).toFixed(2) + 's; display: flex; flex-direction: column; gap: 8px; border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 10px 12px; cursor: pointer',
flag: this.flag(a.cc, 26, 18, 3),
pStyle: 'font-size: 15px; font-weight: 800; font-variant-numeric: tabular-nums' + (a.hit ? '; color: #7FE8B9' : ''),
track: 'width: ' + a.pct + '%; background: linear-gradient(90deg, ' + (a.hit ? '#3DDC97, #3DDC97' : '#6CA8FF, #6CA8FF') + ')',
open: () => toApp('alert:' + i)
}));
const saving = h && h.usualMinor > pMinor ? '−' + Math.round((1 - pMinor / h.usualMinor) * 100) + ' %' : '';
return {
flyOn: !!st.flyOn,
flyHide: () => this.setState({ flyOn: false }),
flyRetry: () => { this.setState({ flyOn: false }); toApp('retry'); },
...this.searchVals(),
...this.gangaVals(),
...this.routeVals(),
accent, bars, confetti,
fromCity: E.fromCity || '',
// Tu foto de perfil (la del móvil o la de Google) llena el círculo; sin
// foto, la inicial de tu nombre como antes.
userInitial: E.photo ? '' : (E.initial || '?'),
userAvatarStyle: 'width: 44px; height: 44px; border-radius: 22px; background: #B69CFF; color: #0B1217; font-weight: 800; font-size: 16px; display: flex; align-items: center; justify-content: center; text-decoration: none; flex-shrink: 0; box-shadow: 0 0 0 2px #0B1217, 0 0 0 4px #B69CFF55, 0 0 18px #B69CFF66'
  + (E.photo ? '; background-image: url("' + String(E.photo).replace(/["\\()\s]/g, encodeURIComponent) + '"); background-size: cover; background-position: center' : ''),
openSettings: () => toApp('settings'),
shareTrip: () => toApp(E.guest ? 'signin' : 'share'),
tile0: () => toApp('tile:0'), tile1: () => toApp('tile:1'), tile2: () => toApp('tile:2'), tile3: () => toApp('tile:3'), tile4: () => toApp('tile:4'),
hasHunt: !!h, noHunt: !h, noHuntMsg: (E.empty || '').replace('{city}', E.fromCity || E.origin || ''),
huntKind: h ? h.kind : '', huntAgo: h ? h.ago : '',
huntO: h ? h.o : '', huntD: h ? h.d : '', huntOPlace: h ? h.oPlace : '', huntDPlace: h ? h.dPlace : '',
huntOFlag: this.flag(h ? h.occ : '', 36, 24, 4) + '; box-shadow: 0 3px 8px rgba(0,0,0,0.35)',
huntDFlag: this.flag(h ? h.dcc : '', 36, 24, 4) + '; box-shadow: 0 3px 8px rgba(0,0,0,0.35)',
huntOFlagMid: this.flag(h ? h.occ : '', 34, 22, 3), huntDFlagMid: this.flag(h ? h.dcc : '', 34, 22, 3),
usual: h ? this.fmt(h.usualMinor) : '', price0: h ? this.fmt(h.pm) : '',
huntLine: h ? h.trip + ' · ' + dayLabel(dSel) + (h.extra ? ' · ' + h.extra : '') : '',
book: () => toApp('book:' + (h ? h.i : 0) + ':' + dSel),
watch: () => toApp('watch:' + (h ? h.i : 0)),
open3d: () => toApp('fly3d'),
hasAlerts: alerts.length > 0, alerts: alerts, alertsNote: alerts.length ? '' : (E.alertsNote || ''), noAlerts: !alerts.length,
alertsTap: () => { if (!alerts.length) toApp(E.guest ? 'signin' : 'alerts'); },
warnStyle: 'width: ' + Math.round(Math.min(1, (E.seenH || 0) / 48) * 100) + '%',
showHunt: st.showHunt && !!h,
replay: () => {
if (!this.state.hunt) return;
this.setState({ showHunt: false });
clearTimeout(this.replayTimer);
this.replayTimer = setTimeout(() => this.setState({ showHunt: true }), 60);
},
price: h ? this.fmt(pMinor) : '',
saving: saving,
skyStyle: 'position: absolute; inset: 0; background: linear-gradient(' + sky[0] + ', ' + sky[1] + ' 55%); transition: background 0.3s',
starsOp: (space ? 1 : night).toFixed(2),
globeTex: 'position: absolute; z-index: 5; left: 44px; top: 50px; width: 270px; height: 270px; border-radius: 135px; background: ' + LAND + '; background-size: 560px 270px; background-position: ' + (spin * 2.4).toFixed(1) + 'px 0',
orbitStyle: 'position: absolute; left: ' + (ox - 120).toFixed(1) + 'px; top: ' + (oy - 42).toFixed(1) + 'px; width: 240px; height: 84px; z-index: ' + (front ? 20 : 2) + '; transform: perspective(700px) rotateY(' + (Math.cos(ph) * 38).toFixed(1) + 'deg) scale(' + (front ? -os : os).toFixed(3) + ', ' + os.toFixed(3) + ') rotate(' + (front ? 4 : -4) + 'deg); filter: drop-shadow(0 18px 14px rgba(0,0,0,0.5))' + (front ? '' : ' brightness(0.7)') + '; pointer-events: none',
spaceStyle: 'position: absolute; inset: 0; transition: opacity 1s ease, transform 1.2s ease; transform-origin: 179px 155px; ' + (space ? 'opacity: 1; transform: scale(1)' : 'opacity: 0; transform: scale(4); pointer-events: none'),
nearStyle: 'position: absolute; inset: 0; transition: opacity 1s ease, transform 1.2s ease; transform-origin: 179px 110px; ' + (space ? 'opacity: 0; transform: scale(0.5); pointer-events: none' : 'opacity: 1; transform: scale(1)'),
terrainStyle: 'position: absolute; left: -800px; top: -1500px; width: 3000px; height: 2400px; transform-origin: 50% 100%; transform: rotateX(76deg); background: ' + LAND + '; background-size: 420px 420px; background-position: 0 ' + (t * 5200).toFixed(0) + 'px; transition: background-position 0.06s linear',
lightsStyle: 'position: absolute; left: -800px; top: -1500px; width: 3000px; height: 2400px; transform-origin: 50% 100%; transform: rotateX(76deg); background: ' + LIGHTS + '; background-size: 60px 60px; background-position: 0 ' + (t * 5200).toFixed(0) + 'px; opacity: ' + night.toFixed(2),
nightStyle: 'position: absolute; inset: 0; background: rgba(3,8,24,0.62); opacity: ' + night.toFixed(2),
planeStyle: 'position: absolute; left: 39px; top: ' + (flying ? 150 : 120) + 'px; width: 280px; height: 140px; z-index: 6; transform-origin: 50% 50%; transform: rotate(' + bank.toFixed(1) + 'deg) scale(' + (flying ? 1 : 0.7) + '); transition: transform 1s ease, top 1s ease; pointer-events: none; filter: drop-shadow(0 14px 10px rgba(0,0,0,0.45))',
miniBar: 'position: absolute; left: 0; top: 0; height: 4px; border-radius: 2px; background: #6CA8FF; width: ' + Math.round((view === 'dest' ? 1 : t) * 100) + '%',
miniPlane: 'position: absolute; top: -5px; width: 14px; height: 14px; margin-left: -7px; border-radius: 7px; background: #FFFFFF; box-shadow: 0 0 8px rgba(255,255,255,0.8); left: ' + Math.round((view === 'dest' ? 1 : t) * 100) + '%',
isWorld: view === 'world', hasGlobe: true,
isOrigin: view === 'origin',
isFlight: view === 'flight',
isDest: view === 'dest',
progressStyle: 'height: 10px; border-radius: 5px; background: #6CA8FF; width: ' + Math.round(t * 100) + '%',
goWorld: () => { this.stopFlight(); this.setState({ view: 'world', t: 0, follow: false }); },
goOrigin: () => { this.stopFlight(); this.setState({ view: 'origin', t: 0, follow: false }); this.ficha('o'); },
goDest: () => { this.stopFlight(); this.setState({ view: 'dest', t: 1, follow: false }); this.ficha('d'); },
fly: () => this.startFlight(),
replayFlight: () => this.startFlight()
};
}
}
