// La maqueta "Modo coche" con lo que tienes cerca de verdad. La app pone los
// datos en window.ECL (ver lib/features/drive/drive_page.dart) y manda lo
// nuevo con window.ECLin({...}). Lo que tocas se le dice a la app con
// toApp('...'): "mode:fuel", "go:park", "voice", "back".
const ARROWS = { left: 'M15 20V10H7 M11 6l-4 4 4 4', right: 'M9 20V10h8 M13 6l4 4-4 4', ahead: 'M12 20V5 M7 10l5-5 5 5', back: 'M8 20V10a4 4 0 0 1 8 0v4 M12 11l4 4 4-4' };
const PATHS = { guide: 'M9 18V5l12-2v13 M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0', fuel: 'M4 21V5a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v16 M4 11h10 M14 8l4 3v7a2 2 0 0 0 4 0V9l-3-3', park: 'M6 21V3h7a5 5 0 0 1 0 10H6', ztl: 'M12 3l9 16H3z M12 10v4 M12 17h.01' };
const COLS = { guide: '#B69CFF', fuel: '#FFB86B', park: '#6CA8FF', ztl: '#FF6B6B' };
// Dónde va cada etiqueta en el mapa de la pantalla del coche.
const SLOTS = [[220, 46], [70, 128], [254, 132]];
function hhmm() { const d = new Date(); return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2); }
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { mode: 'guide', go: false, n: 0, clock: hhmm() };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1, go: false }); };
this.iv = setInterval(() => this.setState({ clock: hhmm() }), 15000);
}
componentWillUnmount() { clearTimeout(this.t); clearInterval(this.iv); }
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const E = this.E;
const L = E.labels || {};
const M = [['guide', L.guide || ''], ['fuel', L.fuel || ''], ['park', L.park || ''], ['ztl', L.ztl || '']];
const modes = M.map(([id, label]) => ({ label, on: st.mode === id, pick: () => { this.setState({ mode: id, go: false }); toApp('mode:' + id); }, style: 'flex: 1; height: 34px; border-radius: 12px; font-family: inherit; font-size: 11px; font-weight: 800; cursor: pointer; white-space: nowrap; ' + (st.mode === id ? 'border: none; background: ' + accent + '; color: #0B1217' : 'border: 1px solid #26363F; background: #141E25; color: #F2F5F3') }));
const c = (E.cards || {})[st.mode] || {};
const tr = (E.turns || {})[st.mode] || {};
const pois = (E.pois || []).slice(0, 3).map((p, i) => p && ({ label: p.label, pin: 'position: absolute; left: ' + SLOTS[i][0] + 'px; top: ' + SLOTS[i][1] + 'px; height: 20px; padding: 0 7px; border-radius: 10px; font-size: 10px; font-weight: 800; display: flex; align-items: center; color: #0B1217; max-width: 120px; overflow: hidden; white-space: nowrap; background: ' + COLS[p.kind] })).filter(Boolean);
const go = st.go && !!c.done;
return {
accent, modes, pois,
title: E.title || '', sub: E.sub || '',
clock: st.clock,
turnIcon: ARROWS[tr.icon] || ARROWS.ahead,
turnDist: tr.dist || '', turnName: tr.name || '',
cardIco: 'width: 28px; height: 28px; border-radius: 8px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; background: ' + COLS[st.mode],
cardPath: PATHS[st.mode], cardTitle: c.title || '', cardMeta: c.meta || '', cardBtn: go ? (E.doneBtn || '') : (c.btn || ''),
btnSt: c.btn ? '' : 'display: none; ',
cardGo: () => { if (!c.btn) return; if (c.done) this.setState({ go: !st.go }); if (!st.go || !c.done) toApp('go:' + st.mode); },
voice: go ? c.done : (c.voice || ''),
voiceTap: () => toApp('voice'),
back: () => toApp('back')
};
}
}
