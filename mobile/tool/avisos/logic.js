// La maqueta "Avisos" con tu historial de verdad. La app pone los avisos en
// window.ECL (ver lib/features/push/notices_page.dart) y manda lo nuevo con
// window.ECLin({...}). Tocar un aviso se le dice a la app con toApp('open:N').
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { tab: 'all', n: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
renderVals() {
const E = this.E;
const accent = this.props.accent ?? '#3DDC97';
/*KINDS*/
const all = E.items || [];
const map = { all: null, zones: ['zone', 'safety'], flights: ['flight'], group: ['group', 'money'] };
const allowed = map[this.state.tab];
const items = all.filter((x) => !allowed || allowed.includes(x.kind)).map((x, n) => {
const k = kinds[x.kind] || kinds.zone;
return {
...x,
open: () => toApp('open:' + x.i),
cardStyle: 'display: flex; gap: 12px; border-radius: 20px; background: linear-gradient(120deg, ' + k.c1 + '14, #141E25 45%); padding: 12px; text-decoration: none; color: #F2F5F3; cursor: pointer; flex-shrink: 0; border: 1px solid ' + (x.kind === 'safety' ? '#7A4433' : '#26363F') + '; animation: av-in .45s ease ' + (Math.min(n, 12) * 0.07).toFixed(2) + 's both',
iconStyle: '--c: ' + k.c1 + '; width: 48px; height: 48px; flex-shrink: 0; border-radius: 15px; background: url(\'' + k.uri + '\') center / 80% no-repeat, linear-gradient(150deg, ' + k.c1 + ', ' + k.c2 + '); border: 1px solid rgba(255,255,255,0.18); animation: av-glow 3s ease-in-out infinite'
};
});
const L = E.tabs || ['Todos', 'Zonas', 'Vuelos', 'Grupo'];
const tabDefs = [['all', L[0]], ['zones', L[1]], ['flights', L[2]], ['group', L[3]]];
const tabs = tabDefs.map(([id, label]) => ({
label,
pick: () => this.setState({ tab: id }),
style: 'height: 36px; border-radius: 18px; padding: 0 14px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + (this.state.tab === id ? 'border: none; background: ' + accent + '; color: #0B1217' : 'border: 1px solid #26363F; background: #141E25; color: #DCE5E9')
}));
return { accent, items, tabs, empty: items.length === 0, emptyTxt: E.empty || '', title: E.title || '', footer: E.footer || '', back: () => toApp('back') };
}
}
