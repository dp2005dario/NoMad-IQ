// La maqueta "Antes de salir" con los datos de tu viaje. La app pone los
// datos en window.ECL (ver lib/features/trip/before_page.dart) y manda lo
// nuevo con window.ECLin({...}). Lo que tocas se le dice a la app con
// toApp('...'): ella lo guarda en el móvil.
const NETS = [['all', 'Todo'], ['tt', 'TikTok'], ['ig', 'Instagram'], ['yt', 'YouTube']];
const NETN = { tt: 'TikTok', ig: 'Instagram', yt: 'YouTube Shorts' };
const NETC = { tt: '#FF2D55', ig: '#C13584', yt: '#FF0000' };
// El fondo de cada reel (en vez de una miniatura inventada).
const NETG = { tt: 'linear-gradient(160deg, #25F4EE 0%, #121212 45%, #FE2C55 100%)', ig: 'linear-gradient(160deg, #FEDA75 0%, #FA7E1E 25%, #D62976 55%, #962FBF 80%, #4F5BD5 100%)', yt: 'linear-gradient(160deg, #FF5A5A 0%, #B00000 60%, #2A0000 100%)' };
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { flip: -1, tip: 0, done: (this.E.done || []).slice(), burst: -1, net: 'all', reel: -1, saved: (this.E.saved || []).slice() };
}
componentDidMount() {
window.ECLin = (d) => {
  Object.assign(this.E, d || {});
  const st = {};
  if (d && d.done) st.done = d.done.slice();
  if (d && d.saved) st.saved = d.saved.slice();
  // Otro viaje: se vuelve al primer consejo y a todas las redes.
  if (d && d.key !== undefined && d.key !== this.key) { this.key = d.key; st.tip = 0; st.flip = -1; st.net = 'all'; st.reel = -1; }
  this.setState(st);
};
this.key = this.E.key;
}
componentWillUnmount() { clearTimeout(this.t); }
renderVals() {
const st = this.state;
const E = this.E;
const IC = D.IC;
const FACTS = E.facts || [];
const TIPS = E.tips || [];
const PACK = E.pack || [];
const REELS = E.reels || [];
const facts = FACTS.map((f, i) => { const open = st.flip === i; const c = f.c; return { k: f.k, v: f.v, more: f.more, src: f.src, img: IC[f.ic] || IC.talk, open, front: !open, flip: () => this.setState({ flip: open ? -1 : i }),
st: 'min-height: 128px; border-radius: 20px; padding: 12px; text-align: left; font-family: inherit; color: #F2F5F3; cursor: pointer; display: flex; flex-direction: column; justify-content: flex-start; perspective: 600px; animation: an-in .5s ease ' + (i * 0.05).toFixed(2) + 's both; background: ' + (open ? 'linear-gradient(150deg, #2B2150, #141E25)' : '#141E25') + '; border: ' + (open ? '2px solid ' + c : '1px solid #26363F') + '; box-shadow: 0 10px 24px -14px ' + c,
ico: 'width: 52px; height: 52px; border-radius: 16px; display: flex; align-items: center; justify-content: center; background: radial-gradient(120% 100% at 30% 20%, ' + c + ', #1B2A3A); box-shadow: inset 0 1px 0 #ffffff55' }; });
const tip = Math.min(st.tip, Math.max(0, TIPS.length - 1));
const tipDots = TIPS.map((_, i) => ({ label: 'Consejo ' + (i + 1), go: () => this.setState({ tip: i }), st: 'width: ' + (tip === i ? 22 : 8) + 'px; height: 8px; border-radius: 4px; border: none; padding: 0; cursor: pointer; transition: width .3s; background: ' + (tip === i ? '#6CA8FF' : '#33467A') }));
const packing = PACK.map((p, i) => { const done = st.done.includes(p.id);
const b = (j) => { const a = j / 5 * Math.PI * 2; return 'position: absolute; left: 11px; top: 11px; width: 6px; height: 6px; border-radius: 3px; background: ' + ['#FFD27A', '#FF7AB6', '#7FE8B9', '#6CA8FF', '#B69CFF'][j] + '; --dx: ' + (Math.cos(a) * 22).toFixed(0) + 'px; --dy: ' + (Math.sin(a) * 22).toFixed(0) + 'px; ' + (st.burst === i ? 'display: block; animation: an-burst .6s ease-out both' : 'display: none'); };
return { title: p.t, why: p.w, done: done ? 'true' : 'false',
toggle: () => { const d = done ? st.done.filter((x) => x !== p.id) : st.done.concat([p.id]); clearTimeout(this.t); this.setState({ done: d, burst: done ? -1 : i }); this.t = setTimeout(() => this.setState({ burst: -1 }), 700); toApp('pack:' + (done ? 0 : 1) + ':' + i); },
style: 'display: flex; align-items: center; gap: 12px; min-height: 54px; border-radius: 16px; border: 1px solid ' + (done ? '#2E7A5A' : '#26363F') + '; background: ' + (done ? '#10251D' : '#141E25') + '; padding: 8px 12px; font-family: inherit; color: #F2F5F3; cursor: pointer; transition: background .3s, border .3s',
box: 'position: absolute; inset: 0; border-radius: 9px; display: flex; align-items: center; justify-content: center; box-sizing: border-box; ' + (done ? 'background: #3DDC97; animation: an-pop .4s cubic-bezier(.2,.9,.3,1.3) both' : 'border: 2px solid #33444E') + '; color: transparent',
titleStyle: 'font-size: 14px; font-weight: 700; transition: color .3s; ' + (done ? 'text-decoration: line-through; color: #9FB0B8' : ''),
b0: b(0), b1: b(1), b2: b(2), b3: b(3), b4: b(4) }; });
const nets = NETS.map(([id, label]) => { const on = st.net === id; return { label, on: on ? 'true' : 'false', pick: () => this.setState({ net: id }), st: 'height: 32px; border-radius: 16px; padding: 0 12px; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; ' + (on ? 'border: none; background: #F2F5F3; color: #120C24' : 'border: 1px solid #33444E; background: transparent; color: #E3DAFF') }; });
const reels = REELS.map((r, i) => [r, i]).filter(([r]) => st.net === 'all' || r.net === st.net).map(([r, i], k) => ({ title: r.t, who: r.who, net: NETN[r.net], open: () => this.setState({ reel: i }),
bg: 'position: absolute; inset: 0; background: ' + NETG[r.net] + '; background-size: 140% 140%; animation: an-kb 9s ease-in-out infinite alternate',
st: 'position: relative; flex: 0 0 132px; height: 228px; border-radius: 20px; overflow: hidden; border: none; padding: 0; color: #fff; font-family: inherit; cursor: pointer; scroll-snap-align: start; box-shadow: 0 12px 26px -12px ' + NETC[r.net] + '; animation: an-in .5s ease ' + (k * 0.08).toFixed(2) + 's both',
badge: 'position: absolute; left: 8px; top: 8px; height: 20px; border-radius: 10px; padding: 0 8px; font-size: 10px; font-weight: 800; display: flex; align-items: center; background: ' + NETC[r.net] }));
const pct = Math.max(0, Math.min(100, E.pct || 0));
const ri = st.reel >= 0 && st.reel < REELS.length ? st.reel : 0;
const R = REELS[ri] || { t: '', who: '', net: 'yt' };
const savedR = st.saved.includes(ri);
const esim = E.esim || {};
const ins = E.ins || {};
return {
facts, tipDots, packing, nets, reels,
back: () => toApp('back'), options: () => toApp('options'),
subTitle: E.sub || '', heroK: E.heroK || '', toriiSt: E.torii ? '' : 'display: none',
factsH: E.factsH || '', noFacts: FACTS.length === 0, emptyTxt: E.emptyTxt || '',
tipsH: E.tipsH || '',
readyPct: pct + '%', ringSt: 'stroke-dashoffset: ' + (176 - 176 * pct / 100).toFixed(1) + '; transition: stroke-dashoffset .6s ease; animation: an-ring 1s ease both',
petals: Array.from({ length: 7 }, (_, k) => 'position: absolute; top: 0; left: ' + (20 + k * 50) + 'px; width: 10px; height: 7px; border-radius: 10px 0 10px 0; background: #FFFFFF; opacity: .9; --dx: ' + (30 + (k % 3) * 20) + 'px; --r: ' + (180 + k * 40) + 'deg; animation: an-petal ' + (5 + (k % 3)) + 's linear ' + (k * 0.8).toFixed(1) + 's infinite'),
tipTxt: TIPS.length ? TIPS[tip].t : '', tipSrc: TIPS.length ? TIPS[tip].s : '',
openTip: () => { if (TIPS.length) toApp('tip:' + tip); },
tipSt: 'display: flex; flex-direction: column; gap: 6px; border-radius: 16px; background: rgba(255,255,255,.06); padding: 12px; min-height: 70px; cursor: pointer; animation: an-in .4s ease both',
nextTip: () => this.setState({ tip: TIPS.length ? (tip + 1) % TIPS.length : 0 }),
esimTxt: esim.txt || '', esimSub: esim.sub || '', insTxt: ins.txt || '', insSub: ins.sub || '',
esimSt: 'min-height: 96px; border-radius: 18px; padding: 12px; display: flex; flex-direction: column; gap: 3px; align-items: flex-start; text-align: left; font-family: inherit; color: #F2F5F3; cursor: pointer; background: linear-gradient(150deg, #13213A, #0F1A2C); border: ' + (esim.on ? '2px solid #6CA8FF' : '1px solid #2A3E63'),
insSt: 'min-height: 96px; border-radius: 18px; padding: 12px; display: flex; flex-direction: column; gap: 3px; align-items: flex-start; text-align: left; font-family: inherit; color: #F2F5F3; cursor: pointer; background: #12201A; border: ' + (ins.on ? '2px solid #3DDC97' : '1px solid #23423A'),
toggleEsim: () => toApp('esim'), toggleIns: () => toApp('ins'),
reelsH: E.reelsH || '',
sheet: st.reel >= 0 && REELS.length > 0, close: () => this.setState({ reel: -1 }),
sBg: 'width: 64px; height: 112px; border-radius: 12px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; cursor: pointer; background: ' + NETG[R.net],
sTitle: R.t, sWho: R.who, sNet: NETN[R.net], sHow: (E.how || {})[R.net] || '',
sBadge: 'align-self: flex-start; height: 20px; border-radius: 10px; padding: 0 8px; font-size: 10px; font-weight: 800; display: flex; align-items: center; background: ' + NETC[R.net],
watch: () => toApp('reel:' + ri), watchTxt: 'Ver en ' + NETN[R.net],
watchSt: 'height: 50px; border-radius: 16px; border: none; background: ' + NETC[R.net] + '; color: #FFFFFF; font-family: inherit; font-size: 14px; font-weight: 800; cursor: pointer',
saveTxt: savedR ? (E.savedTxt || '') : (E.saveTxt || ''),
saveReel: () => { const s2 = savedR ? st.saved.filter((x) => x !== ri) : st.saved.concat([ri]); this.setState({ saved: s2 }); toApp('save:' + (savedR ? 0 : 1) + ':' + ri); }
};
}
}
