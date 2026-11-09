// La maqueta "Pasaporte" con tus sellos de verdad. La app pone los datos en
// window.ECL (ver lib/features/passport/passport_page.dart) y manda lo nuevo
// con window.ECLin({...}). Lo que tocas se le dice a la app con toApp('...').
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
// book: closed (tapa) · opening (la tapa gira) · open · page: país abierto · dir: hacia dónde se pasó la página
this.state = { book: 'closed', page: 0, dir: 1, sel: null, n: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
componentWillUnmount() { clearTimeout(this.t); }
renderVals() {
const st = this.state;
const E = this.E;
/*ICONS*/
const C = E.pages || [];
const RAR = { common: ['#2F8F6B', '#1F6E52', '#E8FFF4'], rare: ['#3B6FD9', '#24459A', '#E3ECFF'], epic: ['#8E5BD9', '#5B2E9A', '#F1E8FF'], legendary: ['#E0A43B', '#B5651D', '#FFF3D6'] };
const go = (i) => { if (i < 0 || i >= C.length || i === st.page) return; this.setState({ page: i, dir: i > st.page ? 1 : -1, sel: null }); };
const pages = C.map((c, pi) => {
const got = c.cards.length;
return {
on: st.page === pi,
aria: c.country + ': ' + got,
country: c.country, sub: c.sub, city: c.city, tint: c.tint, flag: c.flag,
pageNo: c.pageNo,
count: c.count,
empty: !!c.empty, emptyTxt: E.emptyTxt || '', cameraTxt: E.cameraTxt || '', camera: () => toApp('camera'),
pageStyle: 'position: absolute; left: 12px; right: 12px; top: 6px; bottom: 26px; border-radius: 6px 20px 20px 6px; background: linear-gradient(135deg, #FBF4E4 0%, #F1E5CB 100%); box-shadow: 0 26px 50px rgba(0,0,0,0.5), inset -6px 0 0 #E4D4B2, inset -8px 0 0 #D8C59E; padding: 18px 18px 14px 26px; box-sizing: border-box; display: flex; flex-direction: column; gap: 10px; overflow: hidden; transform-origin: ' + (st.dir > 0 ? 'left' : 'right') + ' center; animation: ' + (st.dir > 0 ? 'nq-flipR' : 'nq-flipL') + ' 0.55s cubic-bezier(.2,.8,.3,1) both',
cards: c.cards.map((k, si) => {
const R = RAR[k.rar] || RAR.common;
return {
name: k.name, num: k.num, rar: k.rarLbl, icon: IC[k.icon] || IC.palace, det: DET[k.icon] || DET.palace, ink: R[1],
has: true, locked: false,
date: k.date,
aria: k.name + ', ' + k.rarLbl + ', ' + k.date,
pick: () => this.setState({ sel: pi + '-' + si }),
wrap: 'border: none; background: transparent; padding: 0; cursor: pointer; border-radius: 14px; animation: nq-deal 0.45s cubic-bezier(.2,1.2,.4,1) ' + (0.3 + Math.min(si, 8) * 0.08) + 's both',
face: 'position: relative; display: block; width: 136px; height: 192px; border-radius: 14px; overflow: hidden; box-shadow: 0 8px 18px rgba(60,40,20,0.35); background: radial-gradient(circle at 50% 35%, ' + R[0] + ' 0%, ' + R[1] + ' 100%)',
rarStyle: 'border-radius: 6px; padding: 2px 6px; font-size: 8.5px; letter-spacing: 0.06em; background: rgba(255,255,255,0.22)',
holo: 'position: absolute; top: -20%; left: 0; width: 45%; height: 140%; background: linear-gradient(90deg, transparent, rgba(255,255,255,' + (k.rar === 'legendary' ? 0.55 : k.rar === 'epic' ? 0.45 : k.rar === 'rare' ? 0.38 : 0.2) + '), transparent); animation: nq-holo ' + (k.rar === 'legendary' ? 2.2 : 3.4) + 's ease-in-out ' + (si * 0.4) + 's infinite; pointer-events: none'
};
})
};
});
// Una pestaña por país (un país con muchos cromos ocupa varias páginas).
const firsts = [];
C.forEach((c, i) => { if (!firsts.some((j) => C[j].group === c.group)) firsts.push(i); });
const cur = (C[st.page] || {}).group;
const tabs = firsts.map((i) => { const c = C[i]; const on = c.group === cur; return {
n: String(c.total || c.cards.length),
label: c.country, on, pick: () => go(i), flag: c.flag,
style: 'height: 52px; min-width: 64px; flex-shrink: 0; border-radius: 16px; font-family: inherit; color: #F2F5F3; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; cursor: pointer; ' + (on ? 'border: 2px solid #E6C478; background: #1E2A2E' : 'border: 1px solid #26363F; background: #141E25')
}; });
const arrow = (side, off) => 'position: absolute; ' + side + ': -4px; top: 250px; width: 40px; height: 40px; border-radius: 20px; border: none; background: rgba(11,18,23,0.75); display: flex; align-items: center; justify-content: center; cursor: pointer; z-index: 2; ' + (off ? 'opacity: 0.25; pointer-events: none' : '');
let cv = { hasCard: false };
if (st.sel) {
const [pi, si] = st.sel.split('-').map(Number);
const c = C[pi]; const k = c && c.cards[si];
if (k) {
const R = RAR[k.rar] || RAR.common;
const speaking = E.speaking === k.id;
cv = {
hasCard: true,
cNum: k.num, cRar: k.rarLbl, cIcon: IC[k.icon] || IC.palace, cDet: DET[k.icon] || DET.palace, cInk: R[1], cName: k.name,
cPlace: k.place,
cIconFill: '#FFFFFF',
cK1: k.k1, cV1: k.v1, cK2: k.k2, cV2: k.v2,
cText: k.text,
cAudio: speaking ? (E.stopTxt || '') : (E.listenTxt || ''),
cListen: () => toApp('listen:' + k.id),
cMap: () => toApp('map:' + k.id), mapTxt: E.mapTxt || '',
cMapSt: k.map ? '' : 'display: none; ',
bigCard: 'position: relative; width: 260px; height: 360px; border-radius: 22px; overflow: hidden; flex-shrink: 0; box-shadow: 0 30px 60px rgba(0,0,0,0.6); animation: nq-cardin 0.7s cubic-bezier(.2,.9,.3,1) both; background: radial-gradient(circle at 50% 35%, ' + R[0] + ' 0%, ' + R[1] + ' 100%)',
cRarStyle: 'border-radius: 8px; padding: 3px 8px; font-size: 11px; letter-spacing: 0.06em; background: rgba(255,255,255,0.22)',
cHolo: 'position: absolute; top: -20%; left: 0; width: 45%; height: 140%; background: linear-gradient(90deg, transparent, rgba(255,255,255,0.45), transparent); animation: nq-holo 2.4s ease-in-out 0.7s infinite; pointer-events: none; display: block'
};
}
}
return {
pages, tabs, infoLine: E.info || '', ...cv,
title: E.title || '', totalLabel: E.total || '', memTxt: E.memTxt || '', memories: () => toApp('memories'), back: () => toApp('back'),
cov1: E.cov1 || '', cov2: E.cov2 || '', tapOpen: E.tapOpen || '',
closeCard: () => { if (E.speaking) toApp('stop'); this.setState({ sel: null }); },
closed: st.book === 'closed',
opening: st.book === 'opening',
open: st.book !== 'closed',
openBook: () => { this.setState({ book: 'opening', dir: 1 }); clearTimeout(this.t); this.t = setTimeout(() => this.setState({ book: 'open' }), 700); },
prev: () => go(st.page - 1),
next: () => go(st.page + 1),
prevStyle: arrow('left', st.page === 0),
nextStyle: arrow('right', st.page >= C.length - 1)
};
}
}
