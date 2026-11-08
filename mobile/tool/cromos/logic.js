class Component extends DCLogic {
// La maqueta "Cromos con amigos" con TU liga. La app pone los datos en
// window.ECL (ver lib/features/cards/cards_page.dart) y, sin recargar, manda
// los nuevos con window.ECLin({...}). La página le pide cosas a la app con
// toApp("aviso").
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { tab: 'swap', sw: 0, friend: 0, tick: 0, undo: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ tick: this.state.tick + 1, sw: d && d.keep ? this.state.sw : 0, undo: 0 }); };
}
componentWillUnmount() { clearTimeout(this.t); clearInterval(this.iv); }
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const E = this.E;
const T = [['swap', 'Cambiar'], ['league', 'Liga'], ['friends', 'Amigos']];
const tabs = T.map(([id, label]) => ({ label, on: st.tab === id, pick: () => this.setState({ tab: id }), style: 'flex: 1; height: 36px; border-radius: 12px; border: none; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + (st.tab === id ? 'background: #B69CFF; color: #0B1217' : 'background: transparent; color: #9FB0B8') }));
// Cambiar: el cambio que toca (tocar un móvil pasa al siguiente).
const SW = E.swaps || [];
const sw = SW.length ? SW[st.sw % SW.length] : null;
const done = st.undo > 0;
const ph = (left) => 'position: absolute; top: 60px; width: 96px; height: 170px; border-radius: 18px; background: #0B1217; border: 2px solid #33444E; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px; transition: left 0.6s ease, transform 0.6s ease; cursor: ' + (SW.length > 1 ? 'pointer' : 'default') + '; left: ' + left + 'px; transform: rotate(' + (left < 150 ? (done ? 0 : -8) : (done ? 0 : 8)) + 'deg)';
const RC = { legendary: ['#C9B6FF', '#6D4FD8', '#1E1050', '#E3D8FF', 'rgba(182,156,255,0.6)'], epic: ['#9CC3FF', '#3E6FD8', '#0E2350', '#CFE0FF', 'rgba(108,168,255,0.55)'], rare: ['#FFD36B', '#E08A2E', '#3B1E06', '#FFD36B', 'rgba(255,200,90,0.5)'], common: ['#CFE3D9', '#6F9A86', '#13261E', '#C9D3D8', 'rgba(127,232,185,0.35)'] };
const card = (c) => { const r = RC[(c && c.rar) || 'common']; return { name: c ? c.name : '', label: c ? c.label : '', has: !!c,
box: 'width: 70px; height: 96px; border-radius: 10px; background: linear-gradient(160deg, ' + r[0] + ', ' + r[1] + '); display: flex; flex-direction: column; align-items: center; justify-content: flex-end; padding-bottom: 6px; box-shadow: 0 0 18px ' + r[4] + (c ? '' : '; opacity: .25'),
ink: r[2], txt: 'font-size: 9px; font-weight: 800; color: ' + r[2] + '; text-align: center; padding: 0 4px; line-height: 1.1; max-height: 20px; overflow: hidden',
lab: 'font-size: 10px; font-weight: 800; color: ' + r[3] }; };
const L = card(sw && sw.mine), R = card(sw && sw.theirs);
const nextSw = () => { if (SW.length > 1 && !done) this.setState({ sw: st.sw + 1 }); };
const startUndo = () => { clearInterval(this.iv); this.setState({ undo: 30 }); this.iv = setInterval(() => { const u = this.state.undo - 1; if (u <= 0) clearInterval(this.iv); this.setState({ undo: Math.max(0, u) }); }, 1000); };
const doSwap = () => {
if (!sw) return;
if (done) { clearInterval(this.iv); this.setState({ undo: 0 }); toApp('undo:' + (st.sw % SW.length)); return; }
if (sw.kind === 'in') { startUndo(); toApp('accept:' + (st.sw % SW.length)); }
else if (sw.kind === 'new') toApp('offer:' + (st.sw % SW.length));
else if (sw.kind === 'join') toApp('create');
else if (sw.kind === 'invite') toApp('invite');
};
const passive = sw && sw.kind === 'out';
// Liga.
const lg = E.league || [];
const league = lg.map((p, i) => ({ name: p.name, meta: p.meta, n: i + 1, ini: p.ini, pts: p.pts, row: 'display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-radius: 16px; ' + (p.me ? 'background: #1E2A20; border: 1px solid ' + accent : 'background: #141E25; border: 1px solid #26363F'), pos: 'width: 20px; font-size: 14px; font-weight: 800; color: ' + (i === 0 ? '#FFD36B' : i === 1 ? '#C9D3D8' : i === 2 ? '#E0A070' : '#6F8490'), av: 'width: 32px; height: 32px; border-radius: 16px; display: flex; align-items: center; justify-content: center; font-weight: 800; color: #0B1217; background: ' + (p.me ? accent : ['#FF8A65', '#6CA8FF', '#FFB86B', '#B69CFF', '#7FE8B9'][i % 5]) }));
// Amigos: dónde está cada uno (solo quien lo comparte).
const SLOT = [[210, 90], [80, 210], [250, 280], [40, 320], [150, 30], [290, 180], [130, 300], [20, 150]];
const FC = ['#FF8A65', '#6CA8FF', '#FFB86B', '#B69CFF', '#7FE8B9', '#FF7EB6', '#7FE0E6', '#E6D86B'];
const FR = (E.friends || []).slice(0, 8);
const fi = Math.min(st.friend, Math.max(0, FR.length - 1));
const friends = FR.map((x, i) => { const c = FC[i % FC.length]; const [px, py] = SLOT[i]; return { name: x.name, ini: x.ini, pick: () => this.setState({ friend: i }), pin: 'position: absolute; left: ' + px + 'px; top: ' + py + 'px; display: flex; flex-direction: column; align-items: center; gap: 3px; background: none; border: none; padding: 0; cursor: pointer; font-family: inherit', av: 'width: 40px; height: 40px; border-radius: 20px; display: flex; align-items: center; justify-content: center; font-weight: 800; font-size: 16px; color: #0B1217; background: ' + c + '; box-shadow: 0 0 0 3px ' + (fi === i ? '#F2F5F3' : '#0B1217') + ', 0 0 20px ' + c, tag: 'font-size: 11px; font-weight: 800; color: #F2F5F3; background: rgba(11,18,23,0.8); padding: 2px 6px; border-radius: 6px' }; });
const f = FR[fi];
return {
accent, tabs, league, friends,
isSwap: st.tab === 'swap', isLeague: st.tab === 'league', isFriends: st.tab === 'friends',
phoneL: ph(done ? 98 : 40), phoneR: ph(done ? 164 : 222), nextSw,
whoL: 'TÚ', whoR: sw ? sw.who : '',
cL: L, cR: R,
swapHint: done ? (sw.doneHint || '') : (sw ? sw.hint : ''),
swapTitle: sw ? sw.title : '',
swapText: sw ? sw.text : '',
doSwap,
swapLabel: done ? 'Deshacer (tienes ' + st.undo + ' s)' : (sw ? sw.button : ''),
swapBtn: 'height: 46px; border-radius: 14px; font-family: inherit; font-size: 14px; font-weight: 800; cursor: ' + (passive ? 'default' : 'pointer') + '; ' + (done || passive ? 'border: 1px solid #B69CFF; background: transparent; color: #B69CFF' : 'border: none; background: #B69CFF; color: #0B1217'),
hasAlt: !!(sw && sw.alt) && !done, altLabel: sw && sw.alt ? sw.alt : '',
doAlt: () => { if (!sw) return; if (sw.kind === 'join') toApp('join'); else if (sw.kind === 'in') toApp('decline:' + (st.sw % SW.length)); },
headK: E.headK || '', headPos: E.headPos || '', headSub: E.headSub || '',
openLeague: () => toApp('league'),
pointsNote: E.pointsNote || '',
hasFriends: FR.length > 0, noFriends: FR.length === 0, friendsNote: E.friendsNote || '',
fr: { name: f ? f.name : '', where: f ? f.where : '', meta: f ? f.meta : '' },
shareNote: E.shareNote || '', share: () => toApp('share'),
back: () => toApp('back')
};
}
}
