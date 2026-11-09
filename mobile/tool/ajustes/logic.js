class Component extends DCLogic {
// La maqueta "Ajustes" con tus datos de verdad. La app pone los datos en
// window.ECL (ver lib/features/settings/settings_page.dart) y manda lo nuevo
// con window.ECLin({...}). Lo que tocas se le pide a la app con toApp(...).
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { photo: true, copied: false, del: false, tog: Object.assign({}, this.E.toggles || {}) };
}
componentDidMount() {
window.ECLin = (d) => {
  Object.assign(this.E, d || {});
  const st = {};
  // La app manda cómo quedaron los interruptores (por si la huella falló).
  if (d && d.toggles) st.tog = Object.assign({}, d.toggles);
  if (d && d.closeDel) st.del = false;
  this.setState(st);
};
}
componentWillUnmount() { clearTimeout(this.t); }
renderVals() {
const accent = '#3DDC97';
const st = this.state;
const E = this.E;
// Los avatares de viajero (el primero es tu inicial).
const AV = [
{ c: '#B69CFF', label: 'Inicial', path: '' },
{ c: '#6CA8FF', label: 'Avión', path: 'M2 16l20-6-2-3-7 2-5-5-2 1 3 5-5 1.5-2-1.5-1.5.5z' },
{ c: '#3DDC97', label: 'Montaña', path: 'M3 19l6-10 4 6 3-4 5 8z' },
{ c: '#FFB86B', label: 'Sol', path: 'M12 8a4 4 0 1 0 0.01 0M12 2v2M12 20v2M2 12h2M20 12h2' },
{ c: '#FF8A65', label: 'Brújula', path: 'M12 3a9 9 0 1 0 0.01 0M15 9l-2 5-4 1 2-5z' },
{ c: '#F2C230', label: 'Mochila', path: 'M7 8a5 5 0 0 1 10 0v12H7zM9 13h6' }
];
const ph = E.photo || { av: 0 };
const avatar = ph.img ? -1 : (ph.av || 0);
const cur = AV[Math.max(0, avatar)];
const T = [
['ofertas', 'Avisos de chollos', 'Precios muy bajos y bajadas de precio', '#6CA8FF', 'M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4'],
['huella', 'Entrar con huella o cara', 'Para abrir la app y la bóveda', accent, 'M12 4a7 7 0 0 0-7 7v3M19 11a7 7 0 0 0-3-5.7M9 20c1-2 1.5-4.5 1.5-7a1.5 1.5 0 0 1 3 0c0 3-.5 5.5-1.5 8M16 19c.6-1.8 1-3.8 1-6'],
['ubicacion', 'Audioguías por zona', 'Usa tu ubicación solo con la app abierta', '#FF8A65', 'M12 21s-7-6-7-11a7 7 0 0 1 14 0c0 5-7 11-7 11zM12 8a2 2 0 1 0 0.01 0'],
['oscuro', 'Tema oscuro', 'Cambia solo según la hora', '#B69CFF', 'M20 14A8 8 0 1 1 10 4a6 6 0 0 0 10 10z']
];
const toggles = T.map(([k, title, sub, c, path], i) => { const on = !!st.tog[k]; return { title, sub, c, path, on: on ? 'true' : 'false', flip: () => { this.setState({ tog: Object.assign({}, st.tog, { [k]: !on }) }); toApp('tog:' + (on ? 0 : 1) + ':' + pack({ k: k })); }, sep: i < T.length - 1 ? '1px solid #22313A' : 'none', track: 'width: 50px; height: 30px; border-radius: 15px; flex-shrink: 0; position: relative; transition: background 0.2s; background: ' + (on ? accent : '#33444E'), knob: 'position: absolute; top: 3px; left: ' + (on ? 23 : 3) + 'px; width: 24px; height: 24px; border-radius: 12px; background: #F2F5F3; transition: left 0.2s; box-shadow: 0 2px 4px rgba(0,0,0,0.35)' }; });
const S = [['Hacer foto', accent, 'M4 8h3l2-3h6l2 3h3v11H4zM12 10a3 3 0 1 0 0.01 0'], ['Galería', '#6CA8FF', 'M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M15 9h.01'], ['De Google', '#FFB86B', 'M20 12h-8v3h4.6A5 5 0 1 1 15 8.5l2.2-2.2A8 8 0 1 0 20 12z'], ['Quitar', '#FF8A65', 'M5 7h14M10 7V4h4v3M7 7l1 13h8l1-13']];
const ring = ph.img ? accent : cur.c;
const circ = 'width: 76px; height: 76px; border-radius: 38px; background: ' + (ph.img ? "#141E25 center / cover no-repeat url('" + ph.img + "')" : cur.c) + '; color: #0B1217; font-weight: 800; font-size: 30px; display: flex; align-items: center; justify-content: center; font-family: Manrope, sans-serif; box-shadow: 0 0 0 3px #191A30, 0 0 0 5px ' + ring;
const signed = !!E.signedIn;
const go = (m) => () => toApp(m);
return {
accent, toggles,
name: E.name || '', email: E.email || '',
bigAv: circ,
avText: avatar === 0 ? (E.ini || '') : '',
avPath: cur.path,
avIco: avatar > 0 ? 'display: block' : 'display: none',
photoOpen: st.photo,
togglePhoto: () => this.setState({ photo: !st.photo }),
idHide: E.id ? '' : 'display: none; ',
idLabel: st.copied ? 'ID copiado' : 'ID: ' + (E.id || '') + ' · copiar',
copyId: () => { toApp('copy'); this.setState({ copied: true }); clearTimeout(this.t); this.t = setTimeout(() => this.setState({ copied: false }), 1600); },
src: S.map(([t, c, path], i) => ({ t, c, path, pick: () => { this.setState({ photo: false }); toApp('src:' + i); } })),
avatars: AV.map((a, i) => ({ label: 'Avatar: ' + a.label, path: a.path || 'M9 7h3a5 5 0 0 1 0 10H9z', pick: () => toApp('av:' + i), style: 'width: 44px; height: 44px; border-radius: 22px; cursor: pointer; display: flex; align-items: center; justify-content: center; background: ' + a.c + '; border: 2px solid ' + (i === avatar ? '#F2F5F3' : 'transparent') })),
lang: E.lang || '', cur: E.cur || '', easy: E.easy || '', ver: E.ver || '',
back: go('back'), goLang: go('lang'), goCur: go('cur'), goEasy: go('easy'), goPriv: go('privacy'), goNotices: go('notices'), goHelp: go('help'),
outTxt: signed ? 'Cerrar sesión' : 'Entrar con tu cuenta',
signOut: go(signed ? 'signout' : 'signin'),
delHide: signed ? '' : 'display: none; ',
delOpen: st.del,
askDelete: () => this.setState({ del: true }),
closeDelete: () => this.setState({ del: false }),
download: go('download'),
erase: () => { this.setState({ del: false }); toApp('erase'); }
};
}
}
