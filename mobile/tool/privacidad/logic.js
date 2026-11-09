// La maqueta "Privacidad" con tus ajustes de verdad. La app pone los datos
// en window.ECL (ver lib/features/settings/privacy_page.dart) y manda lo
// nuevo con window.ECLin({...}). Lo que tocas se le dice a la app con
// toApp('...'): "t:<clave>:1" enciende un interruptor y ":0" lo apaga.
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { n: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const E = this.E;
const toggles = (E.toggles || []).map((d, i) => {
const on = d.locked ? true : !!d.on;
return {
title: d.title,
hint: d.hint,
checked: on ? 'true' : 'false',
flip: () => { if (!d.locked) toApp('t:' + d.key + ':' + (on ? 0 : 1)); },
rowStyle: 'display: flex; align-items: center; gap: 12px; padding: 12px 14px;' + (i > 0 ? ' border-top: 1px solid #22313A;' : ''),
trackStyle: 'width: 52px; height: 32px; flex-shrink: 0; border-radius: 16px; border: none; padding: 0; position: relative; cursor: ' + (d.locked ? 'not-allowed; opacity: 0.6' : 'pointer') + '; background: ' + (on ? accent : '#33444E'),
knobStyle: 'position: absolute; top: 4px; left: ' + (on ? '24px' : '4px') + '; width: 24px; height: 24px; border-radius: 12px; transition: left .2s; background: ' + (on ? '#0B1217' : '#DCE5E9')
};
});
const k = E.know || [];
return {
accent, toggles,
title: E.title || '', prot: E.prot || '', protSub: E.protSub || '',
offTxt: E.offTxt || '', offCount: E.offCount || '', openOffline: () => toApp('offline'),
hasPwd: !!E.pwdTxt, pwdTxt: E.pwdTxt || '', openPwd: () => toApp('password'),
knowH: E.knowH || '', k1: k[0] || '', k2: k[1] || '', k3: k[2] || '', k4: k[3] || '',
hasPush: !!E.push, forgetTxt: E.forgetTxt || '', forgetSub: E.forgetSub || '',
forgetSt: E.paused ? 'background: #3DDC97; border: none; color: #0B1217' : 'border: 1px solid #7A4433; background: #24140F; color: #FFB199',
forget: () => { if (!E.busy) toApp(E.paused ? 'resume' : 'forget'); },
back: () => toApp('back')
};
}
}
