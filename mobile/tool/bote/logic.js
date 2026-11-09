class Component extends DCLogic {
// La maqueta "Bote común" con TUS botes. La app pone los datos en window.ECL
// (ver lib/features/money/kitty_page.dart) y, sin recargar, manda los
// nuevos con window.ECLin({...}). La página le pide cosas a la app con
// toApp("aviso"). ECLIPTA no mueve dinero: solo apunta lo que hacéis.
constructor(props) {
super(props);
this.E = window.ECL || {};
const pot = this.E.pot || {}, cp = this.E.couple || {};
this.state = { tab: this.E.tab === 'couple' ? 'couple' : 'pot', split: cp.split || 0, cp: this.cpFromE(), cpSheet: false, cpPeace: false, cpAdd: 0, cpD: 0, cpN: 0, put: this.putFromE(), spends: this.spendsFromE(), drops: [], outs: [], wob: 0, sheet: false, sp: '', fm: null, fly: '', fixed: false, shown: 0, intro: false, counting: false, seq: 0, rem: 0 };
}
componentDidMount() {
this.startIntro(); this.cpCount(400);
// Lo que llega de la app: se anima la diferencia (monedas que entran o salen).
window.ECLin = (d) => {
const before = this.inside(this.state);
Object.assign(this.E, d || {});
const st = { put: this.putFromE(), spends: this.spendsFromE() };
const after = this.inside(st);
const fly = this.E.fly || '';
this.E.fly = '';
const cp = this.cpFromE();
this.setState(Object.assign(st, { cp, split: (this.E.couple || {}).split || 0 }, fly ? { fly } : {}));
this.cpCount(0);
if (after > before) this.dropCoins(after, Math.min(6, Math.max(2, Math.ceil((after - before) / 20))));
this.countTo(after, 300);
};
}
goal() { const p = this.E.pot || {}; return Math.max(1, p.goal || 1); }
putFromE() { return ((this.E.pot || {}).people || []).map((p) => p.put || 0); }
spendsFromE() { return ((this.E.pot || {}).spends || []).map((x) => ({ name: x.name, meta: x.meta, amt: x.amt, cat: x.cat, icon: '' })); }
cpFromE() { return ((this.E.couple || {}).items || []).map((x, i) => ({ id: i, name: x.name, meta: x.meta, amt: x.amt, who: x.mine ? 'D' : 'N', settle: !!x.settle, cat: x.cat, icon: '' })); }
dropCoins(total, coins) {
  const y = this.levelFor(total); const xs = [52, 86, 66, 98, 44, 76]; const seq = this.state.seq;
  const drops = this.state.drops.slice(-6).concat(Array.from({ length: coins }, (_, i) => ({ id: seq + i, x: xs[(seq + i) % xs.length], y: y, delay: i * 0.22 })));
  this.setState({ drops, seq: seq + coins, wob: this.state.wob + 1 });
  try { if (navigator.vibrate) navigator.vibrate([20, 60, 20]); } catch (e) {}
}
componentWillUnmount() { clearInterval(this.iv2); clearTimeout(this.t4); clearTimeout(this.t); clearTimeout(this.t2); clearTimeout(this.t3); clearInterval(this.iv); }
startIntro() {
  clearTimeout(this.t);
  this.t = setTimeout(() => { this.setState({ intro: true }); this.countTo(this.inside(this.state), 0); }, 350);
}
sum(p) { return p.reduce((a, b) => a + b, 0); }

adStart(payers, sub, onAdd) { this.adPayers = payers; this.adSubTxt = sub; this.adOnAdd = onAdd; this.setState({ ad: { open: true, cat: 0, name: '', amt: 12, who: payers.length ? payers[0][0] : '', k: 0 } }); }
adVals(st) {
  const ad = st.ad || { open: false, cat: 0, name: '', amt: 0, who: '', k: 0 };
  const c = AD[ad.cat] || AD[0];
  const set = (o) => this.setState({ ad: Object.assign({}, ad, o) });
  const payers = this.adPayers || [];
  return {
    adOn: !!ad.open, adSub: this.adSubTxt || '',
    adBig: 'flex: none; width: 64px; height: 64px; border-radius: 20px; background: url(\'' + c.uri + '\') center / 78% no-repeat, linear-gradient(150deg, ' + c.c1 + ', ' + c.c2 + '); box-shadow: 0 10px 24px -10px ' + c.c1 + '; animation: ' + (ad.k % 2 ? 'ad-popA' : 'ad-popB') + ' .5s cubic-bezier(.2,.9,.3,1.3) both',
    adCats: AD.map((x, i) => { const on = ad.cat === i; return { label: x.label, on, pick: () => set({ cat: i, name: (!ad.name || c.sug.indexOf(ad.name) >= 0) ? '' : ad.name, k: ad.k + 1 }),
      tile: 'height: 92px; border-radius: 18px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; font-family: inherit; color: #F2F5F3; cursor: pointer; transition: transform .3s cubic-bezier(.2,.9,.3,1.4), background .3s, border-color .3s; animation: ad-tile .45s cubic-bezier(.2,.9,.3,1.2) ' + (0.05 + i * 0.04).toFixed(2) + 's both; ' + (on ? 'border: 2px solid ' + x.c1 + '; background: linear-gradient(160deg, ' + x.c1 + '44, ' + x.c2 + '88); transform: translateY(-3px) scale(1.04); box-shadow: 0 12px 24px -12px ' + x.c1 : 'border: 1px solid #26363F; background: #141E25'),
      art: 'display: block; width: ' + (on ? 52 : 44) + 'px; height: ' + (on ? 52 : 44) + 'px; background: url(\'' + x.uri + '\') center / contain no-repeat; transition: width .3s, height .3s' }; }),
    adSug: c.sug.map(n => ({ label: n, pick: () => set({ name: n }), style: 'height: 34px; border-radius: 17px; padding: 0 13px; font-family: inherit; font-size: 12.5px; font-weight: 800; cursor: pointer; transition: all .25s; ' + (ad.name === n ? 'border: none; background: ' + c.c1 + '; color: #0B1217; transform: scale(1.05)' : 'border: 1px solid #33444E; background: transparent; color: #DCE5E9') })),
    adAmt: ad.amt + ' €',
    adName: ad.name || '', adCount: (ad.name || '').length ? (ad.name || '').length + '/40' : '',
    adPh: 'Escribe el nombre, p. ej. ' + c.sug[0] + ' en el centro',
    adType: (e) => set({ name: String(e.target.value || '').slice(0, 40) }),
    adFocus: (e) => { try { const el = e.target; setTimeout(() => el.scrollIntoView({ block: 'center', behavior: 'smooth' }), 250); } catch (er) {} },
    adInput: 'width: 100%; height: 50px; box-sizing: border-box; border-radius: 15px; border: 2px solid ' + (ad.name ? c.c1 : '#33444E') + '; background: #0B1217; color: #F2F5F3; font-family: inherit; font-size: 16px; font-weight: 700; padding: 0 56px 0 14px; outline: none; transition: border-color .25s, box-shadow .25s; box-shadow: ' + (ad.name ? '0 0 0 4px ' + c.c1 + '22' : 'none'),
    adMinus: () => set({ amt: Math.max(1, ad.amt - 1) }), adPlus: () => set({ amt: ad.amt + 1 }),
    adQuick: [5, 10, 20, 50].map(v => ({ label: '+' + v, pick: () => set({ amt: ad.amt + v }) })),
    adPayWrap: 'display: ' + (payers.length > 1 ? 'flex' : 'none') + '; flex-direction: column; gap: 8px; flex-shrink: 0',
    adPayers: payers.map(([id, label, col]) => ({ label, pick: () => set({ who: id }), style: 'flex: 1; height: 44px; border-radius: 14px; font-family: inherit; font-size: 13.5px; font-weight: 800; cursor: pointer; transition: all .25s; ' + (ad.who === id ? 'border: none; background: ' + col + '; color: #0B1217; transform: scale(1.03)' : 'border: 1px solid #33444E; background: transparent; color: #DCE5E9') })),
    adClose: () => set({ open: false }),
    adConfirm: () => { const item = { cat: ad.cat, name: (ad.name || '').trim() || c.label, amt: ad.amt, who: ad.who, uri: c.uri, c1: c.c1, c2: c.c2 }; set({ open: false }); if (this.adOnAdd) this.adOnAdd(item); try { if (navigator.vibrate) navigator.vibrate([15, 40, 25]); } catch (e) {} },
    adOk: 'flex-grow: 1; height: 50px; border-radius: 15px; border: none; background: linear-gradient(120deg, ' + c.c1 + ', #FFD27A); color: #0B1217; font-family: inherit; font-size: 14.5px; font-weight: 800; cursor: pointer; box-shadow: 0 10px 24px -12px ' + c.c1,
    adOkLbl: 'Añadir · ' + ad.amt + ' €'
  };
}
artBox(uri, c1, c2, size) { return 'display: block; width: ' + size + 'px; height: ' + size + 'px; border-radius: ' + Math.round(size * 0.3) + 'px; flex-shrink: 0; background: url(\'' + uri + '\') center / 80% no-repeat, linear-gradient(150deg, ' + c1 + ', ' + c2 + ')'; }



cpTotals(cp) { let d = 0, n = 0, tot = 0; cp.forEach(x => { if (x.settle) { if (x.who === 'N') { n += x.amt; d -= x.amt; } else { d += x.amt; n -= x.amt; } } else { tot += x.amt; if (x.who === 'D') d += x.amt; else n += x.amt; } }); return { d, n, tot }; }
cpCount(delay) { clearInterval(this.iv2); clearTimeout(this.t4); this.t4 = setTimeout(() => { this.iv2 = setInterval(() => { const t = this.cpTotals(this.state.cp); const st = this.state; const mv = (c, g) => c === g ? c : c + Math.sign(g - c) * Math.max(1, Math.ceil(Math.abs(g - c) / 10)); const nd = mv(st.cpD, t.d), nn = mv(st.cpN, t.n); if (nd === st.cpD && nn === st.cpN) { clearInterval(this.iv2); return; } this.setState({ cpD: nd, cpN: nn }); }, 35); }, delay); }

inside(st) { return this.sum(st.put) - st.spends.reduce((a, x) => a + x.amt, 0); }
levelFor(v) { return 170 - Math.max(0, Math.min(1, v / this.goal())) * 118; }
spendNow(fmArg) {
  const st = this.state; const fm = fmArg || st.fm; const inside = this.inside(st);
  if (fm.amt > inside) { this.setState({ sp: '', fm: null, fly: 'nomoney', tried: fm.amt }); return; }
  const y0 = this.levelFor(inside); const n = Math.min(7, Math.max(2, Math.ceil(fm.amt / 25)));
  const seq = st.seq; const xs = [50, 88, 64, 100, 42, 78, 58];
  const outs = Array.from({ length: n }, (_, i) => ({ id: seq + i, x: xs[i % xs.length], y: y0 + 4, dx: (i % 2 ? 1 : -1) * (20 + i * 9), delay: i * 0.12 }));
  const spends = [{ name: fm.name, meta: 'Ahora · apuntado por ti · ' + fm.src, amt: fm.amt, icon: fm.icon, cat: fm.cat, fresh: true }].concat(st.spends.map(x => Object.assign({}, x, { fresh: false })));
  toApp('spend:0:' + pack({ n: fm.name, a: fm.amt, c: fm.cat }));
  this.setState({ sp: '', fm: null, spends, outs, seq: seq + n, wob: st.wob + 1, last: fm });
  this.countTo(this.inside(Object.assign({}, st, { spends })), 300);
  try { if (navigator.vibrate) navigator.vibrate([30, 40, 30, 40, 30]); } catch (e) {}
  clearTimeout(this.t2); this.t2 = setTimeout(() => { this.setState({ fly: 'group' }); this.t2 = setTimeout(() => this.setState({ fly: '' }), 3800); }, 1300);
}
countTo(target, delay) {
  clearInterval(this.iv); clearTimeout(this.t3);
  this.t3 = setTimeout(() => {
    this.setState({ counting: true });
    this.iv = setInterval(() => {
      const cur = this.state.shown; const d = target - cur;
      if (d === 0) { clearInterval(this.iv); this.setState({ counting: false }); return; }
      const step = Math.sign(d) * Math.max(1, Math.ceil(Math.abs(d) / 14));
      this.setState({ shown: cur + step });
    }, 40);
  }, delay);
}
addMoney(who, amount, coins) {
  const put = this.state.put.slice(); put[who] += amount;
  const total = this.sum(put) - this.state.spends.reduce((a, x) => a + x.amt, 0);
  const y = this.levelFor(total);
  const xs = [52, 86, 66, 98, 44, 76];
  const seq = this.state.seq;
  const drops = this.state.drops.slice(-6).concat(Array.from({ length: coins }, (_, i) => ({ id: seq + i, x: xs[(seq + i) % xs.length], y: y, delay: i * 0.22 })));
  this.setState({ put, drops, seq: seq + coins, wob: this.state.wob + 1 });
  this.countTo(total, 600);
  try { if (navigator.vibrate) navigator.vibrate([20, 60, 20]); } catch (e) {}
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const tabs = [['pot', 'Bote del grupo'], ['couple', 'Modo pareja']].map(([id, label]) => ({ label, on: st.tab === id, pick: () => this.setState({ tab: id }), style: 'flex: 1; height: 36px; border-radius: 12px; border: none; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + (st.tab === id ? 'background: #FFB86B; color: #1A1206' : 'background: transparent; color: #9FB0B8') }));
const E = this.E, POT = E.pot || null, CP = E.couple || null, CUR = E.cur || '€';
const GOAL = this.goal(), EACH = POT && POT.ask ? POT.ask : 0;
const PEO = POT ? POT.people || [] : [];
const meI = Math.max(0, PEO.findIndex((p) => p.me));
const total = this.sum(st.put);
const frac = Math.min(1, total / GOAL);
const spent = st.spends.reduce((a, x) => a + x.amt, 0);
const left = total - spent;
const level = st.intro ? this.levelFor(left) : 176;
const full = st.intro && EACH > 0 && total >= GOAL && !st.counting;
const PC = ['#FFB86B', '#6CA8FF', '#B69CFF', '#FF8A65', '#FF7EB6', '#7FE0E6'];
const P = PEO.map((p, i) => [p.name, p.me ? accent : PC[i % PC.length]]);
const people = P.slice(0, 4).map(([n, c], i) => { const v = st.put[i] || 0; const ok = EACH ? v >= EACH : v > 0; const pend = v === 0; return {
  ini: PEO[i].ini, name: n, put: v + ' ' + CUR, state: ok ? (EACH ? 'completo' : 'ha puesto') : (pend ? 'pendiente' : 'faltan ' + (EACH - v) + ' ' + CUR),
  rmSt: 'display: ' + (pend && !PEO[i].me && !(st.fly === 'sent' && st.rem === i) ? 'block' : 'none'), remind: () => this.setState({ fly: 'remind', rem: i }),
  card: 'flex: 1; min-width: 0; border-radius: 16px; background: #141E25; border: 1px solid ' + (pend ? '#FF8A6577' : '#26363F') + '; padding: 8px 4px; display: flex; flex-direction: column; align-items: center; gap: 4px' + (pend ? '; animation: bt-pend 1.8s ease-in-out infinite' : ''),
  av: 'width: 34px; height: 34px; border-radius: 17px; display: flex; align-items: center; justify-content: center; font-weight: 800; color: #0B1217; background: ' + c + (ok ? '; box-shadow: 0 0 0 2px #0B1217, 0 0 0 4px ' + c : ''),
  bar: 'display: block; height: 100%; width: ' + Math.round(Math.min(1, v / Math.max(1, EACH || Math.max(1, ...st.put))) * 100) + '%; background: ' + c + '; border-radius: 3px; transition: width 1s ease .5s',
  st: 'font-size: 10px; font-weight: 800; color: ' + (ok ? accent : '#FF8A65') }; });
const spends = st.spends.map((x, i) => ({ name: x.name, meta: x.meta, amt: '−' + x.amt + ' ' + CUR, icon: x.icon, box: (() => { const c = AD[x.cat != null ? x.cat : catOf(x.name)]; return this.artBox(c.uri, c.c1, c.c2, 40); })(), card: 'display: flex; align-items: center; gap: 10px; border-radius: 16px; background: ' + (x.fresh ? 'linear-gradient(120deg, #3A1E14, #141E25 60%)' : '#141E25') + '; border: 1px solid ' + (x.fresh ? '#FF8A6588' : '#26363F') + '; padding: 10px 12px; animation: ' + (x.fresh ? 'ad-enter .7s cubic-bezier(.2,.9,.3,1) both' : 'nq-in .4s ease ' + (0.2 + i * 0.08).toFixed(2) + 's both') }));
const outs = st.outs.map(o => ({ st: '--x: ' + o.x + 'px; --y: ' + o.y + 'px; --dx: ' + o.dx + 'px; animation-delay: ' + o.delay + 's', id: o.id }));
const drops = st.drops.map(d => ({ st: '--x: ' + d.x + 'px; --y: ' + d.y + 'px; animation-delay: ' + d.delay + 's',
  rp: 'transform: translate(' + d.x + 'px, ' + d.y + 'px)', id: d.id }));
const sp = [['Mitad', 50], ['Según sueldo 60/40', 60], ['Lo que toma 55/45', 55]];
const pct = sp[st.split][1];
const splits = sp.map(([label], i) => ({ label, on: st.split === i, pick: () => { if (st.split !== i) toApp('split:' + i); this.setState({ split: i, cpPeace: false }); }, style: 'flex: 1; min-width: 0; height: 36px; border-radius: 11px; padding: 0 4px; font-family: inherit; font-size: 11px; font-weight: 800; line-height: 1.1; cursor: pointer; transition: all .25s ease; ' + (st.split === i ? 'border: none; background: linear-gradient(120deg, #FF8FB1, #6CA8FF); color: #0B1217; transform: scale(1.04)' : 'border: 1px solid #5A2A44; background: rgba(0,0,0,0.2); color: #F2F5F3') }));
const ME = CP ? CP.me : { ini: 'T', name: 'Tú' }, OT = CP ? CP.ot : { ini: '?', name: '' };
const T = this.cpTotals(st.cp);
const owe = Math.round(T.d - T.tot * pct / 100);
const posD = T.tot ? Math.max(4, Math.min(96, (st.cpD / Math.max(1, st.cpD + st.cpN)) * 100)) : 50;
const peace = Math.abs(owe) < 1;
const who = owe > 0 ? OT.name : ME.name, other = owe > 0 ? ME.name : OT.name;
const iPay = owe < 0;
const lean = Math.abs(posD - pct) > 3;
const cpItems = st.cp.map(x => ({ box: (() => { const c = AD[x.settle ? 8 : (x.cat != null ? x.cat : catOf(x.name))]; return this.artBox(c.uri, x.settle ? '#3DDC97' : c.c1, x.settle ? '#0F3A2A' : c.c2, 40); })(), name: x.settle ? (x.who === 'N' ? OT.name + ' envió a ' + ME.name : ME.name + ' envió a ' + OT.name) : x.name, meta: x.meta, amt: (x.settle ? '' : '') + x.amt + ' €', icon: x.icon, ini: x.who === 'D' ? ME.ini : OT.ini,
  aria: 'Pagó ' + (x.who === 'D' ? ME.name : OT.name) + ', tocar para cambiar',
  swap: () => { if (x.settle) return; toApp('swap:' + x.id); this.setState({ cp: st.cp.map(y => y.id === x.id ? Object.assign({}, y, { who: y.who === 'D' ? 'N' : 'D', fresh: true }) : Object.assign({}, y, { fresh: false })), cpPeace: false }); this.cpCount(0); },
  card: 'display: flex; align-items: center; gap: 10px; border-radius: 16px; padding: 9px 10px 9px 12px; transition: all .35s ease; ' + (x.settle ? 'background: linear-gradient(120deg, #16302A, #141E25 70%); border: 1px solid #3DDC9766' : 'background: ' + (x.who === 'D' ? 'linear-gradient(100deg, #FF8FB114, #141E25 45%)' : 'linear-gradient(260deg, #6CA8FF14, #141E25 45%)') + '; border: 1px solid ' + (x.fresh ? (x.who === 'D' ? '#FF8FB1' : '#6CA8FF') : '#26363F')) + (x.fresh ? '; animation: ad-enter .7s cubic-bezier(.2,.9,.3,1) both' : ''),
  who: 'flex: none; width: 34px; height: 34px; border-radius: 17px; border: none; font-family: inherit; font-weight: 800; font-size: 14px; cursor: ' + (x.settle ? 'default' : 'pointer') + '; transition: all .3s ease; ' + (x.who === 'D' ? 'background: #FF8FB1; color: #2A0A16' : 'background: #6CA8FF; color: #0A1A2E') }));
const myPut = st.put[meI] || 0;
const dDone = EACH > 0 && myPut >= EACH;
const myPart = Math.max(0, EACH - myPut);
const flyCls = st.fly ? ' fs-' + st.fly : '';
return { ...this.adVals(st),
accent, tabs, people, spends, splits, drops, outs,
isPot: st.tab === 'pot', isCouple: st.tab === 'couple',
rootCls: (full ? 'bt-full' : '') + flyCls,
liqStyle: 'transform: translateY(' + level + 'px); transition: transform ' + (st.intro ? '1.6s' : '0s') + ' cubic-bezier(.3,1.35,.5,1) .55s',
wobCls: st.wob ? (st.wob % 2 ? 'bt-wobA' : 'bt-wobB') : '',
numCls: st.counting ? 'bt-counting' : '',
shownTxt: String(st.shown), totalTxt: String(total), spentTxt: spent + ' ' + CUR, curTxt: CUR, goalOf: EACH ? 'de ' + GOAL + ' ' + CUR : CUR,
barStyle: 'display: block; height: 100%; width: ' + Math.round(frac * 100) + '%; background: linear-gradient(90deg, #FFB84A, #FFE08A); border-radius: 4px; transition: width 1.4s ease .55s',
goalTxt: !EACH ? (POT ? 'Pedid una parte a cada uno con «Poner mi parte»' : '') : total >= GOAL ? 'Objetivo de ' + GOAL + ' ' + CUR + ' conseguido' : 'Faltan ' + (GOAL - total) + ' ' + CUR + ' por poner · ' + Math.round(frac * 100) + '%',
leftCol: total >= GOAL ? '#3DDC97' : '#FFB86B',
leftInPot: 'Dentro ahora: ' + left + ' ' + CUR, leftNum: String(left), anaHas: String(st.has || 0), gapTxt: String(Math.abs(left - (st.has || 0))),
openPay: () => { if (dDone) return; if (!EACH) { toApp('putask'); return; } this.setState({ sheet: true, fly: '' }); },
payLabel: dDone ? 'Tu parte, puesta' : EACH ? 'Poner mi parte · ' + myPart + ' ' + CUR : 'Poner mi parte',
payStyle: 'flex-grow: 1; height: 48px; border-radius: 14px; border: none; font-family: inherit; font-size: 14px; font-weight: 800; cursor: pointer; ' + (dDone ? 'background: #1E2C34; color: #3DDC97' : 'background: linear-gradient(120deg, #FFD27A, #FFB86B); color: #1A1206; box-shadow: 0 10px 24px -12px #FFB86B'),
sheetOn: st.sheet,
closeSheet: () => this.setState({ sheet: false }),
sendPay: () => { this.setState({ sheet: false }); toApp('put:' + myPart); },
sendRemind: () => { this.setState({ fly: 'sent' }); toApp('remind:' + st.rem); clearTimeout(this.t2); this.t2 = setTimeout(() => this.setState({ fly: '' }), 3200); },
closeFly: () => this.setState({ fly: '' }),
check: () => { this.setState({ fly: '' }); toApp('check'); },
fixGap: () => { this.setState({ fly: '' }); toApp('spend:0:' + pack({ n: 'Gastos sin apuntar', a: Math.abs(left - (st.has || 0)), c: 8 })); },
openSpend: () => this.setState({ sp: 'choose', fly: '' }),
spOn: !!st.sp, spChoose: st.sp === 'choose', spScanning: st.sp === 'scan', spForm: st.sp === 'form',
spClose: () => this.setState({ sp: '', fm: null }),
spScan: () => { this.setState({ sp: '' }); toApp('scan'); },
spManual: () => { this.setState({ sp: '' }); this.adStart([['B', 'Del bote', '#FFB86B']], 'Sale del bote ' + (POT ? POT.name : ''), (it) => this.spendNow({ name: it.name, amt: it.amt, src: 'apuntado a mano', icon: '', cat: it.cat })); },
fmName: st.fm ? st.fm.name : '', fmAmt: st.fm ? st.fm.amt + ' ' + CUR : '', fmSrc: st.fm ? (st.fm.src === 'leído del ticket' ? 'Leído del ticket (QR y líneas)' : 'Apuntado a mano') : '', fmWho: (PEO[meI] || {}).name || '',
fmMinus: () => { if (st.fm && st.fm.amt > 5) this.setState({ fm: Object.assign({}, st.fm, { amt: st.fm.amt - 5 }) }); },
fmPlus: () => { if (st.fm) this.setState({ fm: Object.assign({}, st.fm, { amt: st.fm.amt + 5 }) }); },
spConfirm: () => this.spendNow(),
groupTxt: st.last ? 'Has pagado ' + st.last.amt + ' ' + CUR + ' con el bote (' + st.last.name + '). Quedan ' + left + ' ' + CUR + ' dentro.' : '',
noMoneyTxt: 'Dentro quedan ' + left + ' ' + CUR + ' y el gasto es de ' + (st.tried || 0) + ' ' + CUR + '. Pedid más o pagad la diferencia aparte (se reparte en Saldar).',
askMore: () => { this.setState({ fly: '' }); toApp('more'); },
replay: () => { clearTimeout(this.t2); clearInterval(this.iv); this.setState({ drops: [], outs: [], intro: false, shown: 0, fly: '', sheet: false, sp: '', fm: null }); this.startIntro(); },
cpCls: st.cpPeace ? 'cp-peace' : '',
cpTotal: String(T.tot), cpD: String(st.cpD), cpN: String(st.cpN),
pullL: lean && posD > pct ? 'cp-pullL' : '', pullR: lean && posD < pct ? 'cp-pullR' : '',
ropeL: 'position: absolute; left: 0; top: 0; bottom: 0; width: ' + posD + '%; background: repeating-linear-gradient(115deg, #FF8FB1 0 8px, #FF6F9C 8px 12px); background-size: 24px 10px; animation: cp-rope 1s linear infinite; transition: width .9s cubic-bezier(.3,1.4,.5,1)',
ropeR: 'position: absolute; right: 0; top: 0; bottom: 0; width: ' + (100 - posD) + '%; background: repeating-linear-gradient(65deg, #6CA8FF 0 8px, #4F8DEB 8px 12px); background-size: 24px 10px; animation: cp-rope 1s linear infinite reverse; transition: width .9s cubic-bezier(.3,1.4,.5,1)',
knot: 'position: absolute; top: 8px; left: calc(' + posD + '% - 14px); width: 28px; height: 28px; border-radius: 14px; background: linear-gradient(135deg, #FF5C8A, #7C5CFF); display: flex; align-items: center; justify-content: center; box-shadow: 0 0 0 3px #1E1620, 0 6px 16px -4px #FF5C8A; transition: left .9s cubic-bezier(.3,1.4,.5,1)',
targetLine: 'position: absolute; top: 10px; bottom: 6px; left: ' + pct + '%; width: 0; border-left: 2px dashed #F2F5F3AA; transition: left .6s ease',
targetLbl: pct === 50 ? 'mitad' : pct + '/' + (100 - pct),
oweTxt: peace ? 'Estáis en paz' : iPay ? 'Debes ' + Math.abs(owe) + ' ' + CUR + ' a ' + OT.name : OT.name + ' te debe ' + Math.abs(owe) + ' ' + CUR,
owePill: 'height: 30px; padding: 0 14px; border-radius: 15px; display: flex; align-items: center; font-size: 13px; font-weight: 800; transition: all .3s ease; ' + (peace ? 'background: #16302A; color: #7FE8B9; animation: nq-pop .5s ease both' : 'background: rgba(0,0,0,0.3); color: #FFE1EA; border: 1px solid #FF8FB155'),
settleLbl: peace ? 'Todo saldado' : iPay ? 'Saldar ahora · ' + Math.abs(owe) + ' ' + CUR : 'Pedir ' + Math.abs(owe) + ' ' + CUR + ' a ' + OT.name,
settleStyle: 'height: 48px; border-radius: 14px; border: none; font-family: inherit; font-size: 14px; font-weight: 800; cursor: pointer; ' + (peace ? 'background: #1E2C34; color: #7FE8B9' : 'background: linear-gradient(120deg, #FF8FB1, #6CA8FF); color: #0B1217; box-shadow: 0 10px 24px -12px #FF8FB1'),
cpSettle: () => { if (peace) return; if (iPay) this.setState({ cpSheet: true }); else toApp('askpay:' + Math.abs(owe)); },
cpSheet: st.cpSheet, cpClose: () => this.setState({ cpSheet: false }),
sTitle: 'Envías ' + Math.abs(owe) + ' ' + CUR + ' a ' + OT.name, sTo: OT.name, sPhone: 'El de ' + OT.name, sAmt: Math.abs(owe) + ',00 ' + CUR, sWhat: (CP ? CP.place : '') + ' · ajuste de pareja',
cpDone: () => { const amt = Math.abs(owe); toApp('settle:' + amt); this.setState({ cpSheet: false, cp: [{ id: 900 + st.cpAdd, settle: true, who: owe > 0 ? 'N' : 'D', amt, name: '', meta: 'Ahora · apuntado por la app', icon: 'M5 12l5 5 9-10', fresh: true }].concat(st.cp.map(y => Object.assign({}, y, { fresh: false }))), cpAdd: st.cpAdd + 1, cpPeace: true, fly: 'peace', peaceAmt: amt, peaceWho: who }); this.cpCount(0); try { if (navigator.vibrate) navigator.vibrate([20, 50, 20, 50, 60]); } catch (er) {} clearTimeout(this.t2); this.t2 = setTimeout(() => this.setState({ fly: '' }), 3800); },
peaceTxt: 'Has enviado ' + (st.peaceAmt || 0) + ' ' + CUR + '. La app solo lo apunta: el dinero va por vuestro banco.',
cpAddOpen: () => this.adStart([['D', ME.name, '#FF8FB1'], ['N', OT.name, '#6CA8FF']], 'Modo pareja · ' + (CP ? CP.place : ''), (it) => { const s2 = this.state; toApp('cadd:0:' + pack({ n: it.name, a: it.amt, c: it.cat, w: it.who === 'D' ? 'me' : 'ot' })); this.setState({ cp: [{ id: 200 + (s2.cpAdd || 0), name: it.name, meta: 'Ahora · a mano · ' + AD[it.cat].label, amt: it.amt, who: it.who, cat: it.cat, icon: '', fresh: true }].concat(s2.cp.map(y => Object.assign({}, y, { fresh: false }))), cpAdd: (s2.cpAdd || 0) + 1, cpPeace: false }); this.cpCount(150); }),
tipCol: peace ? '#3DDC97' : (Math.abs(owe) > 50 ? '#FFB86B' : '#3DDC97'),
tipTitle: peace ? 'Todo en orden' : (Math.abs(owe) > 50 ? (iPay ? OT.name + ' va pagando de más' : 'Vas pagando de más') : 'Vais bastante a la par'),
tipTxt: peace ? 'Estáis en paz. Disfrutad del viaje.' : (Math.abs(owe) > 50 ? (iPay ? OT.name + ' lleva ' + Math.abs(owe) + ' ' + CUR + ' más de lo que le toca. Que la próxima cena la pagues tú o saldad ahora.' : 'Llevas ' + Math.abs(owe) + ' ' + CUR + ' más de lo que te toca. Que la próxima cena la pague ' + OT.name + ' o saldad ahora.') : 'Solo ' + Math.abs(owe) + ' ' + CUR + ' de diferencia. Podéis saldar al final del viaje.'),
cpItems,
// Lo que viene de la app.
hasPot: !!POT, noPot: !POT, potNote: E.potNote || '', potHead: POT ? POT.head : '',
putTitle: 'Pon tu parte: ' + myPart + ' ' + CUR, putAmt: myPart + ',00 ' + CUR, putWhat: (POT ? 'Bote ' + POT.name : '') + ' · ' + ((PEO[meI] || {}).name || ''),
okTitle: 'Apuntados tus ' + (E.okAmt || myPart) + ' ' + CUR, remName: (PEO[st.rem] || {}).name || '', remMiss: EACH ? 'Faltan sus ' + EACH + ' ' + CUR + ' para llenar el bote.' : 'Aún no ha puesto nada en el bote.',
hasCouple: !!CP, noCouple: !CP, coupleNote: E.coupleNote || '',
cpTitle: CP ? ME.name + ' y ' + OT.name + ' · ' + CP.place : '', meIni: ME.ini, otIni: OT.ini,
meUp: 'HAS PAGADO', otUp: (OT.name || '').toUpperCase() + ' HA PAGADO',
pickPot: () => toApp('pickpot'),
back: () => toApp('back')
};
}
}