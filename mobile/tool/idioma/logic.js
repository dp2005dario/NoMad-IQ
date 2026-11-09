// La maqueta "Idioma" con los idiomas que trae la app de verdad. La app pone
// los datos en window.ECL (ver lib/features/settings/language_page.dart) y
// manda lo nuevo con window.ECLin({...}). Elegir un idioma se le dice a la
// app con toApp('lang:es') ("lang:system" = el del móvil).
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { q: '', n: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const E = this.E;
const R = (x, y, w, h, f) => ({ d: 'M' + x + ' ' + y + 'h' + w + 'v' + h + 'h-' + w + 'z', f, s: 'none', w: 0 });
const C = (cx, cy, r, f, ry) => ({ d: 'M' + (cx - r) + ' ' + cy + 'a' + r + ' ' + (ry || r) + ' 0 1 0 ' + (2 * r) + ' 0a' + r + ' ' + (ry || r) + ' 0 1 0 -' + (2 * r) + ' 0z', f, s: 'none', w: 0 });
const P = (d, f) => ({ d, f, s: 'none', w: 0 });
const S = (d, s, w) => ({ d, f: 'none', s, w });
const tri = (a, b, c) => [R(0, 0, 10, 20, a), R(10, 0, 10, 20, b), R(20, 0, 10, 20, c)];
const hor = (a, b, c) => [R(0, 0, 30, 7, a), R(0, 7, 30, 6, b), R(0, 13, 30, 7, c)];
const star = (x, y, f) => P('M' + x + ' ' + (y - 5) + 'l1.2 3.6h3.8l-3.1 2.2 1.2 3.6-3.1-2.2-3.1 2.2 1.2-3.6-3.1-2.2h3.8z', f);
const F = {
es: [R(0, 0, 30, 20, '#C60B1E'), R(0, 5, 30, 10, '#FFC400')],
en: [R(0, 0, 30, 20, '#012169'), S('M0 0L30 20M30 0L0 20', '#fff', 4), S('M0 0L30 20M30 0L0 20', '#C8102E', 1.6), S('M15 0V20M0 10H30', '#fff', 6), S('M15 0V20M0 10H30', '#C8102E', 3.4)],
fr: tri('#0055A4', '#fff', '#EF4135'),
pt: [R(0, 0, 30, 20, '#DA291C'), R(0, 0, 12, 20, '#046A38'), C(12, 10, 4, '#FFE900'), C(12, 10, 2.4, '#DA291C')],
it: tri('#009246', '#fff', '#CE2B37'),
de: hor('#000', '#DD0000', '#FFCE00'),
ja: [R(0, 0, 30, 20, '#fff'), C(15, 10, 6, '#BC002D')],
zh: [R(0, 0, 30, 20, '#DE2910'), P('M5 3l1.2 3.6H10L7 8.8l1.1 3.6L5 10.2 1.9 12.4 3 8.8 0 6.6h3.8z', '#FFDE00'), C(11, 2.5, 0.9, '#FFDE00'), C(13, 4.8, 0.9, '#FFDE00'), C(13, 7.8, 0.9, '#FFDE00'), C(11, 10, 0.9, '#FFDE00')],
ko: [R(0, 0, 30, 20, '#fff'), P('M11 10a4 4 0 0 1 8 0z', '#CD2E3A'), P('M11 10a4 4 0 0 0 8 0z', '#0047A0'), S('M4 4l3 2M4.6 3.2l3 2M5.2 2.4l3 2M22 14l3 2M22.6 13.2l3 2M23.2 12.4l3 2M4 16l3-2M4.6 16.8l3-2M22 6l3-2M22.6 6.8l3-2', '#000', 0.6)],
ar: [R(0, 0, 30, 20, '#006C35'), S('M7 8.5c2-1 4 1 6 0s4 1 6 0 3 1 4 0', '#fff', 1.2), S('M8 13h14M20 12l2 1-2 1', '#fff', 1)],
hi: hor('#FF9933', '#fff', '#138808').concat([S('M12.7 10a2.3 2.3 0 1 0 4.6 0a2.3 2.3 0 1 0 -4.6 0z', '#000080', 0.7)]),
ru: hor('#fff', '#0039A6', '#D52B1E'),
tr: [R(0, 0, 30, 20, '#E30A17'), C(11, 10, 5, '#fff'), C(12.3, 10, 4, '#E30A17'), P('M17 10l3.6-1.2-2.2 3.1V8.1l2.2 3.1z', '#fff')],
// Los que no salían en la maqueta, dibujados igual de sencillos.
nl: hor('#AE1C28', '#fff', '#21468B'),
pl: [R(0, 0, 30, 10, '#fff'), R(0, 10, 30, 10, '#DC143C')],
ro: tri('#002B7F', '#FCD116', '#CE1126'),
uk: [R(0, 0, 30, 10, '#0057B7'), R(0, 10, 30, 10, '#FFD700')],
id: [R(0, 0, 30, 10, '#CE1126'), R(0, 10, 30, 10, '#fff')],
ms: [R(0, 0, 30, 20, '#CC0001'), R(0, 2.9, 30, 2.9, '#fff'), R(0, 8.6, 30, 2.9, '#fff'), R(0, 14.3, 30, 2.9, '#fff'), R(0, 0, 15, 11.4, '#010066'), C(6, 5.7, 3.2, '#FFCC00'), C(7.2, 5.7, 2.6, '#010066'), star(11, 6, '#FFCC00')],
th: [R(0, 0, 30, 20, '#A51931'), R(0, 3.3, 30, 13.4, '#F4F5F8'), R(0, 6.7, 30, 6.6, '#2D2A4A')],
vi: [R(0, 0, 30, 20, '#DA251D'), star(15, 10, '#FFFF00')],
bn: [R(0, 0, 30, 20, '#006A4E'), C(13, 10, 5, '#F42A41')],
fa: hor('#239F40', '#fff', '#DA0000'),
ur: [R(0, 0, 30, 20, '#01411C'), R(0, 0, 7.5, 20, '#fff'), C(18.5, 10, 5, '#fff'), C(20, 9, 4.3, '#01411C'), star(22, 7, '#fff')],
fil: [R(0, 0, 30, 10, '#0038A8'), R(0, 10, 30, 10, '#CE1126'), P('M0 0L17 10L0 20z', '#fff'), C(5.5, 10, 2, '#FCD116')],
// "El del móvil": un móvil dibujado.
system: [R(0, 0, 30, 20, '#26363F'), P('M11 2h8a1.5 1.5 0 0 1 1.5 1.5v13a1.5 1.5 0 0 1-1.5 1.5h-8a1.5 1.5 0 0 1-1.5-1.5v-13A1.5 1.5 0 0 1 11 2z', '#9FB0B8'), R(11.5, 4, 7, 10, '#0B1217'), C(15, 16, 0.8, '#0B1217')]
};
const sel = E.sel || 'system';
const L = E.langs || [];
// Sin tildes ni mayúsculas: "tieng" encuentra "Tiếng Việt".
const norm = (x) => String(x).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
const q = norm(st.q.trim());
const shown = L.filter((x) => !q || norm(x.native + ' ' + x.sub + ' ' + x.code).includes(q));
const cur = L.find((x) => x.code === sel) || L[0] || { pv: {} };
const langs = shown.map((x, i) => { const on = sel === x.code; return { native: x.native, es: x.sub, on, flag: F[x.code] || F.system, pick: () => toApp('lang:' + x.code), row: 'width: 100%; display: flex; align-items: center; gap: 14px; padding: 10px 14px; border: none; font-family: inherit; color: #F2F5F3; cursor: pointer; text-align: left; ' + (i ? 'border-top: 1px solid #1F2C34; ' : '') + (on ? 'background: #15243A' : 'background: transparent'), nativeStyle: 'font-size: 15px; font-weight: 800; font-family: ' + (x.font || '') + "'Manrope', sans-serif", radio: 'width: 22px; height: 22px; border-radius: 11px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; border: 2px solid ' + (on ? '#6CA8FF' : '#4A5C66'), dot: 'width: 10px; height: 10px; border-radius: 5px; background: ' + (on ? '#6CA8FF' : 'transparent') }; });
const ai = E.ai !== false;
return {
accent, langs,
title: E.title || '', sub: E.sub || '', hint: E.hint || '', allH: E.allH || '', aiTxt: E.aiTxt || '',
none: shown.length === 0, noneTxt: (E.none || '').replace('{q}', st.q.trim()),
search: (e) => this.setState({ q: (e && e.target && e.target.value) || '' }),
back: () => toApp('back'),
dir: cur.rtl ? 'rtl' : 'ltr', font: (cur.font || '') + "'Manrope', sans-serif",
pv: cur.pv || {},
aiOn: ai, toggleAi: () => toApp('ai:' + (ai ? 0 : 1)),
aiTrack: 'width: 42px; height: 24px; border-radius: 12px; flex-shrink: 0; position: relative; background: ' + (ai ? accent : '#33444E'),
aiKnob: 'position: absolute; top: 3px; width: 18px; height: 18px; border-radius: 9px; background: #F2F5F3; transition: left 0.2s; left: ' + (ai ? 21 : 3) + 'px'
};
}
}
