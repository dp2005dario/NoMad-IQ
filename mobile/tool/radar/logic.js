// La maqueta "Radar" con los datos de verdad. La app pone los datos en
// window.ECL (ver lib/features/radar/radar_page.dart) y manda lo nuevo con
// window.ECLin({...}). Lo que tocas se le dice a la app con toApp('...'):
// "scam:<tipo>" avisa (o retira) un timo, "item:<cosa>" elige qué compras,
// "cur" abre la lista de monedas y "paid:<precio>" apunta lo que pagaste.
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { n: 0, asked: '', flyHidden: false };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const E = this.E;
const st = this.state;
const chip = (on) => 'flex: none; padding: 0 12px; white-space: nowrap; height: 36px; border-radius: 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + (on ? 'border: none; background: #F2F5F3; color: #0B1217' : 'border: 1px solid #26363F; background: #1C2A33; color: #F2F5F3');
const items = (E.items || []).map((i) => ({ label: i.label, on: E.item === i.k, pick: () => toApp('item:' + i.k), style: chip(E.item === i.k) }));
// Lo que te piden (lo escribes tú): con coma o con punto.
const asked = parseFloat(String(st.asked).replace(',', '.'));
const has = isFinite(asked) && asked > 0 && asked < 1e7;
const r = E.range;
let pos = 0, v = -1;
if (r && has) {
const lo = r.low * 0.6, hi = r.high * 1.8;
pos = Math.max(0, Math.min(100, (asked - lo) / (hi - lo) * 100));
// Igual que en la app: hasta lo que pagan casi todos = normal; hasta un 25 % más = algo caro.
v = asked <= r.high ? 0 : asked <= r.high * 1.25 ? 1 : 2;
}
const V = E.v || ['', '', ''];
const C = [accent, '#FFD166', '#FF6B6B'];
const key = has ? E.item + ':' + E.cur + ':' + asked.toFixed(2) : '';
const sent = has && key === E.sentKey;
const report = (E.report || []).map((d) => ({
label: d.label, on: d.on ? 'true' : 'false', tap: () => toApp('scam:' + d.k),
style: 'height: 32px; padding: 0 10px; border-radius: 10px; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; ' + (d.on ? 'border: none; background: #FFB86B; color: #0B1217' : 'border: 1px solid #5A4527; background: #33281A; color: #FFE7C7')
}));
return {
accent,
back: () => toApp('back'), backTxt: E.backTxt || '',
title: E.title || '', sub: E.sub || '',
rainy: !!E.rainy, rainLbl: E.rainLbl || '', rainTxt: E.rainTxt || '',
go: () => toApp('go'), goTxt: E.goTxt || '',
hasAttr: !!E.attr, attr: E.attr || '',
scams: (E.scams || []).map((z) => ({ lbl: z.lbl, title: z.title, why: z.why, hasBy: !!z.by, by: z.by || '' })),
canReport: report.length > 0, reportHint: E.reportHint || '', report,
showPrice: !!E.showPrice, priceH: E.priceH || '', items, askH: E.askH || '',
type: (e) => this.setState({ asked: (e && e.target && e.target.value) || '' }),
askStyle: 'flex: 1; height: 36px; border-radius: 12px; font-family: inherit; font-size: 13px; font-weight: 800; border: 1px solid #26363F; background: #1C2A33; color: #F2F5F3; padding: 0 10px',
cur: E.cur || '', curTxt: E.curTxt || '', pickCur: () => toApp('cur'),
curStyle: chip(true),
hasRange: !!r, lo: E.loTxt || '', hi: E.hiTxt || '', rangeTxt: E.rangeTxt || '',
needle: 'position: absolute; top: -5px; width: 6px; height: 24px; border-radius: 3px; background: #F2F5F3; border: 2px solid #0B1217; margin-left: -3px; transition: left 0.4s ease; left: ' + pos + '%; ' + (v < 0 ? 'display: none' : ''),
hasVerdict: v >= 0 || !r,
verdict: v >= 0 ? V[v] : (E.noPrices || ''),
verdictStyle: v >= 0 ? 'font-size: 15px; font-weight: 800; color: ' + C[v] : 'font-size: 12px; line-height: 1.5; color: #9FB0B8',
canPay: has,
pay: () => { if (!sent) toApp('paid:' + asked.toFixed(2)); },
payTxt: (sent ? '✓ ' : '') + (E.payTxt || ''),
payStyle: 'cursor: pointer; font-size: 13px; font-weight: 800; color: ' + (sent ? '#9FB0B8' : '#7FE8B9'),
note: E.note || '',
flyOn: !!E.flyOn && !st.flyHidden,
flyHide: () => this.setState({ flyHidden: true }),
flyTitle: E.flyTitle || '', flyText: E.flyText || '', flyOk: E.flyOk || ''
};
}
}
