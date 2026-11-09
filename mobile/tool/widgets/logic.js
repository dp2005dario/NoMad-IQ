// La maqueta "Widgets" con tu vuelo, el chollo de hoy y tu presupuesto (lo
// mismo que pintan los widgets de Android). La app pone los datos en
// window.ECL (ver lib/features/widgets/widgets_page.dart) y manda lo nuevo
// con window.ECLin({...}). Lo que tocas se le dice a la app con
// toApp('...'): "edit" cambia el vuelo, "pin:<widget>" lo pone en el
// escritorio, "live" enciende o apaga el aviso en directo, "open:<widget>"
// abre esa parte de la app, "fly3d" y "boarding".
// ----
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
// view: dónde lo miras (móvil, avisos o reloj) · phase: qué momento del viaje.
this.state = { n: 0, view: 'home', phase: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const E = this.E;
const T = E.t || {};
const P = E.phases || [];
const ph = P[Math.min(st.phase, P.length - 1)] || { color: accent, facts: [], watch: ['', '', ''], pct: 0, shade: 0, clock: E.clock || '' };
const tabStyle = (on) => 'height: 34px; border-radius: 17px; border: none; padding: 0 14px; white-space: nowrap; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + (on ? 'background: #F2F5F3; color: #0B1217' : 'background: transparent; color: #F2F5F3');
const views = [['home', T.home], ['shade', T.shade], ['watch', T.watch]].map(([k, label]) => ({ label: label || '', on: st.view === k, pick: () => this.setState({ view: k }), style: tabStyle(st.view === k) }));
const phases = P.map((p, i) => ({ label: p.key, on: st.phase === i, pick: () => this.setState({ phase: i }), style: 'flex: 1; height: 44px; border-radius: 16px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + (st.phase === i ? 'border: none; background: ' + p.color + '; color: #0B1217' : 'border: 1px solid rgba(255,255,255,0.25); background: rgba(11,18,23,0.6); color: #F2F5F3') }));
const steps = [0, 1, 2, 3].map((i) => ({ style: 'position: absolute; top: 5px; width: 18px; height: 18px; border-radius: 9px; margin-left: -9px; left: ' + (i * 33.33) + '%; border: 3px solid #1A262E; box-sizing: border-box; background: ' + (i * 33.33 <= ph.shade ? ph.color : '#33444E') }));
const small = (w, k) => { w = w || {}; return { tag: w.tag || '', has: !!w.big, none: !w.big, title: w.title || '', big: w.big || '', small: w.small || '', empty: w.empty || '', open: () => toApp('open:' + k), pin: () => toApp('pin:' + k) }; };
const on = !!E.live;
const watch = ph.watch || ['', '', ''];
return {
accent, views, phases, steps,
back: () => toApp('back'), backTxt: T.back || '', title: T.title || '', viewsAria: T.views || '', openApp: T.openApp || '',
isHome: st.view === 'home', isShade: st.view === 'shade', isWatch: st.view === 'watch',
clock: ph.clock || E.clock || '', dateLine: ph.date || E.date || '', dateShort: ph.dateShort || E.dateShort || '',
hasFlight: !!E.hasFlight, noFlight: !E.hasFlight, noFlightTxt: E.noFlightTxt || '', flightName: T.flightName || '',
edit: () => toApp('edit'), editTxt: E.editTxt || '',
openFlight: () => toApp('open:flight'), widgetAria: (E.route || '') + ': ' + (ph.tag || ''),
phaseColor: ph.color, phaseTag: ph.tag || '', flightRight: E.flightRight || '',
fromCode: E.fromCode || '', toCode: E.toCode || '', depTime: E.depTime || '', arrTime: E.arrTime || '',
progressPct: ph.pct + '%', planeLeft: ph.pct + '%',
facts: (ph.facts || []).map(([k, v]) => ({ k, v })),
deal: small(E.deal, 'deal'), budget: small(E.budget, 'budget'),
canPin: !!E.canPin, pinTxt: T.pin || '', pinFlight: () => toApp('pin:flight'), howTo: T.howTo || '',
liveTag: T.liveTag || '', chipShort: ph.chip || '',
notifTitle: on ? (ph.title || '') : (T.liveOffH || ''), notifBody: on ? (ph.body || '') : (T.liveOffP || ''),
shadePct: ph.shade + '%', stops: T.stops || [],
fly3d: () => toApp('fly3d'), fly3dTxt: T.fly3d || '', boarding: () => toApp('boarding'), boardingTxt: T.boarding || '',
liveH: T.liveH || '', liveP: T.liveP || '', liveOn: on ? 'true' : 'false', toggleLive: () => toApp('live'),
liveTrack: 'width: 52px; height: 32px; flex-shrink: 0; border-radius: 16px; border: none; padding: 0; position: relative; cursor: pointer; transition: background .25s; background: ' + (on ? accent : '#33444E'),
liveKnob: 'position: absolute; top: 4px; left: ' + (on ? '24px' : '4px') + '; width: 24px; height: 24px; border-radius: 12px; transition: left .25s cubic-bezier(.2,.9,.3,1.2); background: ' + (on ? '#0B1217' : '#DCE5E9'),
watchTag: watch[0], watchBig: watch[1], watchSmall: watch[2], watchAria: watch.join(', '),
watchOffset: String(716.3 * (1 - ph.pct / 100)), watchHint: T.watchHint || '', qrTxt: T.qr || ''
};
}
}
