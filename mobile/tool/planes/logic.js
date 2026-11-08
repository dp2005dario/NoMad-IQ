class Component extends DCLogic {
// La maqueta "Elegid planes" con los planes de verdad de vuestro viaje. La
// app pone los datos en window.ECL (ver lib/features/plans/plans_page.dart)
// y manda los nuevos con window.ECLin({...}). Los votos los guarda el
// servidor: la página solo le dice a la app qué has votado (toApp).
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { gone: [], drag: 0, dragging: false, match: null, toast: '', tk: 0 };
}
componentDidMount() {
window.ECLin = (d) => {
  Object.assign(this.E, d || {});
  const st = {};
  // Las tarjetas que ya no llegan, fuera de "votadas ahora".
  const ids = (this.E.cards || []).map((c) => c.id);
  st.gone = this.state.gone.filter((id) => ids.includes(id));
  if (d && d.match) { st.match = d.match; this.buzz(); }
  this.setState(st);
  if (d && d.toast) this.say(d.toast);
};
if (this.E.match) { this.setState({ match: this.E.match }); this.buzz(); }
}
componentWillUnmount() { clearTimeout(this.t); clearTimeout(this.t3); }
buzz() { try { if (navigator.vibrate) navigator.vibrate([40, 60, 40, 60, 160]); } catch (e) {} }
say(msg) { clearTimeout(this.t3); this.setState({ toast: msg, tk: this.state.tk + 1 }); this.t3 = setTimeout(() => this.setState({ toast: '' }), 3400); }
deck() { const gone = this.state.gone; return (this.E.cards || []).filter((c) => !gone.includes(c.id)); }
closeMatch(add) {
const m = this.state.match;
this.setState({ match: null });
if (m) toApp((add ? 'addplan' : 'keep') + ':0:' + pack({ id: m.id }));
if (add) this.say('Hecho. Está en el plan del grupo y les llega aviso a todos.');
}
vote(yes) {
const st = this.state;
const top = this.deck()[0];
if (st.match || !top) return;
this.setState({ drag: yes ? 440 : -440, dragging: false });
clearTimeout(this.t);
this.t = setTimeout(() => {
this.setState({ drag: 0, gone: this.state.gone.concat([top.id]) });
toApp('vote:' + (yes ? 1 : 0) + ':' + pack({ id: top.id }));
}, 280);
}
renderVals() {
const st = this.state;
const E = this.E;
const IMG = (c) => c.img || IMGS[(c.n || 0) % IMGS.length];
const deck = this.deck();
const total = E.total || 0;
const dx = st.drag || 0;
const top = deck.slice(0, 2).reverse();
const stack = top.map((c, k) => {
const isTop = k === top.length - 1;
const rot = isTop ? dx / 14 : 0;
const tx = isTop ? dx : 0;
const stamp = 'position: absolute; top: 26px; border-radius: 10px; padding: 2px 10px; font-family: Bricolage Grotesque, sans-serif; font-size: 24px; font-weight: 800; background: rgba(11,18,23,.55); ';
return {
title: c.title, meta: c.meta, why: '✦ ' + c.why, tags: c.tags || [], img: IMG(c), alt: c.title, aria: c.title + (c.meta ? ', ' + c.meta : ''),
credit: c.img ? 'Wikimedia Commons' : 'Dibujo de ECLIPTA',
style: 'position: absolute; inset: 0; border-radius: 28px; overflow: hidden; background: #1A1530; border: 1px solid #3E3163; box-shadow: 0 20px 40px rgba(0,0,0,0.45); touch-action: none; cursor: grab; user-select: none; transition: ' + (st.dragging ? 'none' : 'transform 0.3s ease') + '; transform: translateX(' + tx + 'px) rotate(' + rot + 'deg) scale(' + (isTop ? 1 : 0.95) + ') translateY(' + (isTop ? 0 : 14) + 'px)',
yes: stamp + 'left: 16px; border: 4px solid #3DDC97; color: #3DDC97; transform: rotate(-14deg); opacity: ' + (isTop ? Math.max(0, Math.min(1, dx / 80)) : 0),
no: stamp + 'right: 16px; border: 4px solid #FF6B6B; color: #FF6B6B; transform: rotate(14deg); opacity: ' + (isTop ? Math.max(0, Math.min(1, -dx / 80)) : 0),
down: (e) => { if (!isTop) return; this.x0 = e.clientX; this.setState({ dragging: true }); },
move: (e) => { if (!isTop || !this.state.dragging) return; this.setState({ drag: e.clientX - this.x0 }); },
up: () => { if (!isTop) return; const d = this.state.drag || 0; if (Math.abs(d) > 90) this.vote(d > 0); else this.setState({ drag: 0, dragging: false }); }
};
});
const P = E.people || [];
const people = P.map((p, k) => {
const off = !p.me && !p.on;
return { i: p.i, st: p.me ? 'Tú' : off ? 'sin entrar' : 'ya votó',
style: 'width: 38px; height: 38px; border-radius: 19px; font-size: ' + (p.me ? 11 : 14) + 'px; font-weight: 800; color: #0B1217; display: flex; align-items: center; justify-content: center; background: radial-gradient(circle at 35% 30%, #FFFFFF88, ' + p.c + ' 60%); ' + (p.me ? 'box-shadow: 0 0 0 2px #F2F5F3' : '') + (off ? 'opacity: .35; filter: grayscale(1)' : ''),
dot: 'position: absolute; right: -1px; bottom: -1px; width: 11px; height: 11px; border-radius: 6px; border: 2px solid #0B1217; background: ' + (off ? '#5B6B73' : '#3DDC97') + (off ? '' : '; animation: pl-dot 2s ease-in-out ' + (k * 0.3) + 's infinite') };
});
const m = st.match;
let mv = { showMatch: false };
if (m) {
const who = m.who || [];
const all = ['Tú'].concat(who);
const colOf = (name) => { const p = P.find((x) => x.name === name); return p ? p.c : '#FF8A65'; };
const iniOf = (name) => { const p = P.find((x) => x.name === name); return p ? p.i : (name || '?').charAt(0).toUpperCase(); };
const me = P.find((x) => x.me);
const card = (col) => 'width: 100%; height: 100%; border-radius: 22px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; color: #120C24; background: radial-gradient(120% 100% at 30% 15%, #FFFFFFAA, ' + col + ' 55%); border: 3px solid #FFF3D6; box-shadow: 0 14px 30px rgba(0,0,0,.45)';
const W = '¡MATCH VIAJERO!';
mv = {
showMatch: true, mImg: IMG(m), mAria: 'Match viajero: ' + m.title,
mSub: names(all) + ' queréis ir a ' + m.title,
mL: card(me ? me.c : '#B69CFF'), mLi: '★', mLn: 'Tú',
mR: card(colOf(who[0])), mRi: iniOf(who[0]), mRn: who[0] || '',
mMore: who.length > 1, mMoreTxt: '+ ' + names(who.slice(1)),
mMoreSt: 'position: absolute; left: 50%; top: 556px; transform: translateX(-50%); height: 26px; border-radius: 13px; background: ' + colOf(who[1]) + '; color: #120C24; font-size: 12px; font-weight: 800; display: flex; align-items: center; padding: 0 12px; animation: mv-up .4s ease 1.3s both',
mFly: '¡Coincidís! ' + m.title + ' os encaja a ' + all.length + '. ¿Lo meto en el plan de los días?',
mKeep: () => this.closeMatch(false), mAdd: () => this.closeMatch(true),
letters: W.split('').map((ch, k) => ({ ch: ch === ' ' ? '\u00a0' : ch, st: 'display: inline-block; animation: mv-letter .55s cubic-bezier(.2,.9,.3,1.4) ' + (0.5 + k * 0.045).toFixed(3) + 's both, pl-shim 4s linear infinite' })),
burst: Array.from({ length: 12 }, (_, k) => { const a = k / 12 * Math.PI * 2; const d = 70 + R(k + 3, 50); return 'position: absolute; left: 30px; top: 26px; font-size: ' + (12 + R(k, 10)).toFixed(0) + 'px; color: ' + CONF[k % 4 === 3 ? 0 : k % 2 ? 1 : 2] + '; --dx: ' + (Math.cos(a) * d).toFixed(0) + 'px; --dy: ' + (Math.sin(a) * d).toFixed(0) + 'px; --r: ' + (R(k, 80) - 40).toFixed(0) + 'deg; animation: mv-burst 1.2s ease-out ' + (1.0 + R(k + 7, 0.25)).toFixed(2) + 's 2 both'; }),
conf: Array.from({ length: 30 }, (_, k) => 'position: absolute; top: -20px; left: ' + R(k + 11, 380).toFixed(0) + 'px; width: ' + (6 + R(k, 5)).toFixed(0) + 'px; height: ' + (10 + R(k + 2, 8)).toFixed(0) + 'px; border-radius: ' + (k % 3 === 0 ? '50%' : '2px') + '; background: ' + CONF[k % CONF.length] + '; --dx: ' + (R(k + 5, 120) - 60).toFixed(0) + 'px; --r: ' + (360 + R(k, 540)).toFixed(0) + 'deg; animation: mv-conf ' + (2.6 + R(k + 9, 1.8)).toFixed(2) + 's linear ' + (0.9 + R(k + 4, 1.6)).toFixed(2) + 's 2 both'),
spark: Array.from({ length: 10 }, (_, k) => 'position: absolute; left: ' + (20 + R(k + 21, 340)).toFixed(0) + 'px; top: ' + (30 + R(k + 33, 560)).toFixed(0) + 'px; font-size: ' + (10 + R(k, 14)).toFixed(0) + 'px; color: ' + (k % 2 ? '#FFD27A' : '#FFFFFF') + '; animation: mv-twk ' + (1.6 + R(k + 2, 1.4)).toFixed(2) + 's ease-in-out ' + R(k + 8, 2).toFixed(2) + 's infinite')
};
}
const mlist = (E.matched || []).map((x) => ({ img: IMG(x), title: x.title, who: 'Tú + ' + names(x.who || []),
tag: x.planned ? 'En el plan' : 'Match', tagSt: 'height: 24px; border-radius: 12px; font-size: 11px; font-weight: 800; display: flex; align-items: center; padding: 0 10px; color: #120C24; background: ' + (x.planned ? '#7FE8B9' : 'linear-gradient(90deg, #FF7AB6, #B69CFF)') }));
const wlist = (E.waiting || []).map((x) => ({ img: IMG(x), title: x.title }));
const left = deck.length;
return Object.assign({
back: () => toApp('back'), subTitle: E.sub || '',
stack, people, mlist, wlist, hasWait: wlist.length > 0,
alexNote: E.note || '',
hasCards: left > 0, done: left === 0,
progress: left > 0 ? 'Plan ' + Math.max(1, total - left + 1) + ' de ' + Math.max(total, left) : (total ? 'Has votado todos' : (E.loading || '')),
like: () => this.vote(true), nope: () => this.vote(false),
reset: () => { this.setState({ gone: [] }); toApp('again'); },
hasToast: !!st.toast && !m, toast: st.toast,
toastSt: 'position: absolute; left: 16px; right: 16px; bottom: 112px; z-index: 40; display: flex; align-items: center; gap: 10px; border-radius: 16px; background: #FFFFFF; color: #1A1036; font-size: 13px; font-weight: 700; padding: 10px 12px; box-shadow: 0 12px 30px rgba(0,0,0,.45); animation: pl-toast 3.4s ease both'
}, mv);
}
}
