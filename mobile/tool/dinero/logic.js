class Component extends DCLogic {
// La maqueta "Tu dinero fuera" con TUS datos. La app pone los datos en
// window.ECL (ver lib/features/money/abroad_page.dart) y, sin recargar,
// manda los nuevos con window.ECLin({...}). La página le pide cosas a la
// app con toApp("aviso"). Todos los importes van en unidades enteras.
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { tab: this.E.tab === 'budget' ? 'budget' : 'atm', atm: 0, plan: 0, fly: false, flyDone: false, tripPick: false, added: [] };
}
componentDidMount() {
if (this.state.tab === 'budget') this.count();
window.ECLin = (d) => {
  const before = this.spentTotal();
  const oldRecent = JSON.stringify((this.E.trip || {}).recent || []);
  Object.assign(this.E, d || {});
  const t = this.E.trip || {};
  const st = {};
  // Lo apuntado a mano ya viene en la lista de verdad.
  if (JSON.stringify(t.recent || []) !== oldRecent) st.added = [];
  if (st.added && this.state.added.length && this.state.atm >= (this.E.atms || []).length) st.atm = 0;
  if (this.state.atm >= (this.E.atms || []).length) st.atm = 0;
  if (!this.E.trip) { st.fly = false; st.tripPick = false; }
  this.setState(st);
  if (this.state.tab === 'budget' && this.spentTotal(Object.assign({}, this.state, st)) !== before) this.count(this.state.cnt == null ? 0 : Math.min(this.state.cnt, before));
  this.maybeFly();
};
}
cur() { return this.E.cur || '€'; }
money(v) { return String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, '.') + ' ' + this.cur(); }
spentTotal(st) { st = st || this.state; const t = this.E.trip || {}; return (t.spent || 0) + (st.added || []).reduce((a, x) => a + x.amt, 0); }
count(from) { clearInterval(this.iv); const T = this.spentTotal(); let v = Math.min(from || 0, T); this.setState({ cnt: v }); this.iv = setInterval(() => { v = Math.min(T, v + Math.max(1, Math.ceil((T - v) / 12))); this.setState({ cnt: v }); if (v >= T) clearInterval(this.iv); }, 32); }
// Flyra avisa (una vez) si hoy vas por encima de tu ritmo.
maybeFly() { const t = this.E.trip; if (!t || !t.flyToday || this.state.flyDone || this.state.tab !== 'budget') return; clearTimeout(this.ft); this.ft = setTimeout(() => this.setState({ fly: true, flyDone: true }), 1600); }

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
    adAmt: ad.amt + ' ' + this.cur(),
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
    adOkLbl: 'Añadir · ' + ad.amt + ' ' + this.cur()
  };
}
artBox(uri, c1, c2, size) { return 'display: block; width: ' + size + 'px; height: ' + size + 'px; border-radius: ' + Math.round(size * 0.3) + 'px; flex-shrink: 0; background: url(\'' + uri + '\') center / 80% no-repeat, linear-gradient(150deg, ' + c1 + ', ' + c2 + ')'; }

componentWillUnmount() { clearTimeout(this.t); clearTimeout(this.ft); clearInterval(this.iv); }
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const E = this.E;
const T = E.trip || null;
const cur = this.cur();
const tabs = [['atm', 'Cajeros'], ['budget', 'Gastos']].map(([id, label]) => ({ label, on: st.tab === id, pick: () => { this.setState({ tab: id, fly: false }); if (id === 'budget') { this.count(); setTimeout(() => this.maybeFly(), 0); } }, style: 'flex: 1; height: 36px; border-radius: 12px; border: none; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; transition: background .3s, color .3s, transform .3s; ' + (st.tab === id ? 'background: linear-gradient(135deg, #FFD08A, #FFB86B); color: #1A1206; box-shadow: 0 6px 16px -6px rgba(255,184,107,0.8); animation: nq-pop 0.3s ease both' : 'background: transparent; color: #9FB0B8') }));

// --- Cajeros: los de verdad (OpenStreetMap), el más cercano arriba.
const A = E.atms || [];
const fc = (k) => k === 0 ? accent : k === 1 ? '#FFD166' : '#FF6B6B';
const atms = A.slice(0, 6).map((x, i) => ({ name: x.name, meta: x.meta, fee: x.fee, short: x.short, pick: () => this.setState({ atm: i }),
row: 'display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 18px; font-family: inherit; color: #F2F5F3; cursor: pointer; text-align: left; animation: nq-in 0.4s ease ' + (0.3 + i * 0.08).toFixed(2) + 's both; transition: transform .25s, box-shadow .25s; ' + (st.atm === i ? 'border: 2px solid ' + fc(x.k) + '; background: linear-gradient(160deg, #1A2A33, #111C23); transform: translateY(-2px); box-shadow: 0 14px 30px -14px ' + fc(x.k) : 'border: 1px solid #26363F; background: #141E25'),
logo: 'width: 44px; height: 44px; border-radius: 14px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; color: #FFFFFF; font-size: ' + (x.short.length > 3 ? 11 : 13) + 'px; font-weight: 800; border: 2px solid rgba(255,255,255,0.85); background: linear-gradient(150deg, ' + x.c1 + ', ' + x.c2 + '); box-shadow: 0 6px 14px rgba(0,0,0,0.45)' + (st.atm === i ? '; animation: dn-bob 1.6s ease-in-out infinite' : ''),
badge: 'height: 28px; padding: 0 10px; border-radius: 14px; font-size: 12.5px; font-weight: 800; display: flex; align-items: center; flex-shrink: 0; color: #0B1217; background: ' + fc(x.k) + (st.atm === i ? '; animation: nq-pop 0.35s ease both' : '') }));
const PC = ['#4fe3a0', '#ffc874', '#ff9a7a'];
const pins = A.slice(0, 6).map((x, i) => ({ short: x.short, fee: x.pin,
  wrap: 'position: absolute; left: ' + x.x + 'px; top: ' + x.y + 'px; display: flex; flex-direction: column; align-items: center; gap: 3px; animation: dn-drop 0.6s cubic-bezier(.3,1.4,.5,1) ' + (0.15 + i * 0.12).toFixed(2) + 's both',
  dot: 'width: 38px; height: 38px; border-radius: 50%; border: 2.5px solid #FFFFFF; background: linear-gradient(150deg, ' + x.c1 + ', ' + x.c2 + '); box-shadow: 0 6px 14px rgba(0,0,0,0.6); display: flex; align-items: center; justify-content: center; color: #FFFFFF; font-size: 9px; font-weight: 800; animation: dn-bob 2.4s ease-in-out ' + (i * 0.3).toFixed(1) + 's infinite',
  chip: 'height: 16px; border-radius: 8px; padding: 0 6px; display: flex; align-items: center; font-size: 9.5px; font-weight: 800; color: #0B1217; background: ' + PC[x.k] }));

// --- Gastos: tu viaje, tu límite y lo que llevas (tu parte de cada gasto).
const limit = T ? Math.max(1, T.limit) : 1;
const dayN = T ? T.day : 1, daysN = T ? T.days : 1;
const left = Math.max(0, daysN - dayN);
const SPT = this.spentTotal();
const avg = T ? Math.round(SPT / Math.max(1, dayN)) : 0;
const P = [['Seguir igual', 1], ['Gastar un 25 % menos', 0.75], ['Gastar la mitad', 0.5]];
const rate = Math.round(avg * P[st.plan][1]);
const end = SPT + rate * left;
const PF = /*PF*/[];
const plans = P.map(([label, k], i) => { const e = SPT + Math.round(avg * k) * left; const ov = e > limit; return { label, path: '',
photo: "position: absolute; inset: 0; background: url('" + PF[i] + "') center / cover no-repeat, linear-gradient(150deg, #FFB86B, #3A2A16); animation: dn-kb 7s ease-in-out infinite alternate", end: this.money(e), on: st.plan === i, pick: () => this.setState({ plan: i }),
ico: 'position: relative; overflow: hidden; width: 100%; height: 62px; border-radius: 12px; display: block; ' + (st.plan === i ? 'box-shadow: 0 0 0 2px #FFB86B, 0 8px 18px -8px #FFB86B; animation: nq-pop 0.35s ease both' : 'opacity: 0.75'),
endStyle: 'font-family: Bricolage Grotesque, sans-serif; font-size: 15px; font-weight: 800; color: ' + (ov ? '#FF8A8A' : accent),
style: 'display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 12px 6px; border-radius: 18px; font-family: inherit; cursor: pointer; color: #F2F5F3; transition: all .3s; animation: nq-in 0.4s ease ' + (0.2 + i * 0.08).toFixed(2) + 's both; ' + (st.plan === i ? 'border: 2px solid #FFB86B; background: linear-gradient(160deg, #3A2A16, #1A1510); transform: translateY(-3px); box-shadow: 0 14px 26px -14px rgba(255,184,107,0.8)' : 'border: 1px solid #26363F; background: #141E25') }; });
const over = end - limit;
const Cc = 439.8;
const spentOff = (Cc * (1 - Math.min(SPT, limit) / limit)).toFixed(1);
const projLen = Cc * Math.min(end, limit) / limit;
const projDash = projLen.toFixed(1) + ' ' + Cc;
const dailyReal = T ? (T.daily || []).slice() : [];
if (dailyReal.length) dailyReal[dailyReal.length - 1] += (st.added || []).reduce((a, x) => a + x.amt, 0);
const top = Math.max(1, rate, ...dailyReal) * 1.1;
const days = Array.from({ length: daysN }, (_, i) => { const real = i < dayN; const v = real ? (dailyReal[i] || 0) : rate; const h = Math.max(2, Math.round(v / top * 56)); const today = i === dayN - 1;
  return { n: i + 1, bar: 'width: 100%; height: ' + h + 'px; border-radius: 6px; transform-origin: bottom; animation: dn-grow 0.6s cubic-bezier(.2,.9,.3,1.2) ' + (0.3 + Math.min(i, 20) * 0.06).toFixed(2) + 's both; transition: height .4s ease, background .4s; ' + (real ? 'background: linear-gradient(180deg, #FFD08A, #FF8A65)' + (today ? '; box-shadow: 0 0 12px rgba(255,184,107,0.8)' : '') : 'background: repeating-linear-gradient(135deg, ' + (over > 0 ? '#FF6B6B55' : '#3DDC9755') + ' 0 4px, transparent 4px 8px); border: 1px dashed ' + (over > 0 ? '#FF6B6B' : '#3DDC97')),
    lab: 'font-size: 10px; font-weight: 800; color: ' + (today ? '#FFB86B' : '#6F8490') }; });
const CATS = [['Comida', '#FFB86B', 'food'], ['Transporte', '#6CA8FF', 'train'], ['Ocio', '#B69CFF', 'fun'], ['Compras', '#3DDC97', 'shop']];
const CP = { food: 'M7 3v8M5 3v5a2 2 0 0 0 4 0V3M7 11v10M17 21V3c-2 1-3.5 4-3.5 8H17', train: 'M6 4h12a2 2 0 0 1 2 2v9a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3V6a2 2 0 0 1 2-2zM4 11h16M8 21l2-3M16 21l-2-3', fun: 'M4 8a2 2 0 0 0 0 4v5h16v-5a2 2 0 0 0 0-4V5H4zM10 5v12', shop: 'M5 8h14l-1 12H6zM9 8V6a3 3 0 0 1 6 0v2' };
const kf = SPT <= 0 ? 1 : (st.cnt == null ? SPT : Math.min(st.cnt, SPT)) / SPT;
// Lo apuntado a mano ahora mismo cuenta ya en su tipo.
const catV = (T ? (T.cats || [0, 0, 0, 0]) : [0, 0, 0, 0]).slice();
const AC = { 0: 0, 1: 0, 2: 1, 3: 2, 4: 3 };
(st.added || []).forEach((x) => { if (AC[x.cat] != null) catV[AC[x.cat]] += x.amt; });
const catTop = Math.max(1, ...catV);
const CATF = /*CATF*/{};
const cats = CATS.map(([name, col, ic], i) => { const v = catV[i] || 0; return { name, amt: this.money(Math.round(v * kf)), path: CP[ic],
  photo: "position: absolute; inset: 0; background: url('" + CATF[ic] + "') center / cover no-repeat, linear-gradient(150deg, " + col + ", #0B1217); animation: dn-kb " + (8 + i) + "s ease-in-out infinite alternate",
  card: 'position: relative; overflow: hidden; height: 112px; display: flex; align-items: flex-end; padding: 10px; border-radius: 18px; border: 1px solid ' + col + '55; box-shadow: 0 14px 26px -16px ' + col + '; animation: gx-pop2 0.6s cubic-bezier(.2,.9,.3,1.2) ' + (0.5 + i * 0.1).toFixed(2) + 's both',
  ico: 'width: 34px; height: 34px; border-radius: 11px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; background: ' + col + '; box-shadow: 0 6px 14px -6px ' + col,
  bar: 'display: block; height: 100%; width: ' + Math.round(v / catTop * 100) + '%; border-radius: 3px; background: ' + col + '; transform-origin: left; animation: dn-growx 0.9s cubic-bezier(.2,.8,.2,1) ' + (0.7 + i * 0.1).toFixed(2) + 's both' }; });
const endTxt = this.money(end);
const added = (st.added || []).map((x, i) => ({ name: x.name, meta: x.meta, amt: '−' + x.amt + ' ' + cur, box: this.artBox(x.uri, x.c1, x.c2, 58),
  card: 'position: relative; display: flex; align-items: center; gap: 12px; padding: 8px 12px 8px 8px; border-radius: 18px; background: linear-gradient(155deg, ' + x.c1 + '22, #141E25 55%); border: 1px solid ' + x.c1 + (i === 0 ? '88' : '33') + '; animation: ' + (i === 0 ? 'ad-enter .7s cubic-bezier(.2,.9,.3,1) both, ad-glow 1.6s ease-in-out .7s 2' : 'none') }));
// Tus últimos gastos de verdad (con la foto de su tipo).
const ROWF = /*ROWF*/{};
const recent = (T ? (T.recent || []) : []).map((x, i) => { const c = AD[x.cat] || AD[8]; const f = ROWF[x.cat]; const c1 = f ? f.c1 : c.c1, c2 = f ? f.c2 : c.c2;
  return { name: x.name, meta: x.meta, amt: '−' + x.amt + ' ' + cur, isNew: !!x.isNew,
  card: 'position: relative; display: flex; align-items: center; gap: 12px; padding: 8px 12px 8px 8px; border-radius: 18px; background: linear-gradient(155deg, ' + c1 + '1A, #141E25 55%); border: 1px solid ' + c1 + '33; animation: dn-slide 0.5s cubic-bezier(.2,.9,.3,1) ' + (0.9 + i * 0.12).toFixed(2) + 's both',
  box: 'position: relative; width: 58px; height: 58px; border-radius: 14px; overflow: hidden; flex-shrink: 0; box-shadow: 0 8px 16px -8px ' + c1 + (x.isNew ? '; animation: dn-new 1.8s ease-in-out 1.6s infinite' : ''),
  photo: 'position: absolute; inset: 0; background: url(\'' + (f ? f.u : c.uri) + '\') center / ' + (f ? 'cover' : '78%') + ' no-repeat, radial-gradient(circle at 30% 25%, #FFFFFF33, transparent 55%), linear-gradient(150deg, ' + c1 + ', ' + c2 + '); animation: dn-kb 9s ease-in-out infinite alternate; ',
  amtStyle: "font-family: 'Bricolage Grotesque', sans-serif; font-size: 17px; font-weight: 800; color: #FF8A65; animation: nq-pop 0.4s ease " + (1.1 + i * 0.12).toFixed(2) + 's both' }; });
const trips = (E.trips || []).map((x, i) => ({ title: x.title, sub: x.sub, pick: () => { this.setState({ tripPick: false }); toApp('trip:' + i); },
  style: 'display: flex; flex-direction: column; align-items: flex-start; gap: 2px; padding: 10px 12px; border-radius: 14px; font-family: inherit; color: #F2F5F3; cursor: pointer; text-align: left; ' + (x.on ? 'border: 2px solid #FFB86B; background: #2A2418' : 'border: 1px solid #26363F; background: #141E25') }));
const allowed = T ? Math.max(0, Math.floor((limit - SPT) / Math.max(1, left + 1))) : 0;
return { ...this.adVals(st), added, recent, pins, trips,
back: () => toApp('back'), map3d: () => toApp('map3d'), locate: () => toApp('locate'),
atmCount: E.atmCount || 0, atmNote: E.atmNote || '', hasAtmNote: !!E.atmNote, atmBtn: E.atmBtn || '', hasAtmBtn: !!E.atmBtn,
dnAddOpen: () => this.adStart([], (T ? T.title + ' · día ' + dayN + ' de ' + daysN + ' · ' : '') + 'se suma a lo que llevas', (it) => { const from = this.state.cnt == null ? this.spentTotal() : this.state.cnt; this.setState({ added: [{ name: it.name, meta: 'Ahora · a mano · ' + AD[it.cat].label, amt: it.amt, cat: it.cat, uri: it.uri, c1: it.c1, c2: it.c2 }].concat(this.state.added || []) }); this.count(from); toApp('add:0:' + pack({ c: it.cat, n: it.name, a: it.amt })); }),
accent, tabs, atms, plans,
isAtm: st.tab === 'atm', isBudget: st.tab === 'budget',
verdict: over > 0 ? 'A este ritmo te pasas ' + this.money(over) + ' el último día. Prueba un plan de abajo y te enseño cómo cambia.' : '¡Bien! Así acabas con ' + this.money(-over) + ' de sobra.',
hasTrip: !!T, noTrip: !T, tripPick: !!st.tripPick, tripOpen: () => this.setState({ tripPick: !st.tripPick }),
tripNew: () => toApp('trip'), tripNone: () => { this.setState({ tripPick: false, fly: false }); toApp('notrip'); },
noTripTxt: E.tripNote || 'Para contar tus gastos necesito saber adónde vas y cuándo. Los saco de tu vuelo o tu reserva, o los pones tú.',
tripName: T ? T.name : 'Sin viaje activo',
tripSrc: T ? T.src : 'Elige un viaje o créalo',
tripNoneStyle: 'display: flex; flex-direction: column; align-items: flex-start; gap: 2px; padding: 10px 12px; border-radius: 14px; font-family: inherit; color: #F2F5F3; cursor: pointer; text-align: left; ' + (!T ? 'border: 2px solid #FFB86B; background: #2A2418' : 'border: 1px solid #26363F; background: #141E25'),
ringHead: T ? T.head : '', limitTxt: 'de ' + this.money(limit), perDayTxt: this.money(allowed),
flyOn: !!st.fly, flyBud: !!st.fly && st.tab === 'budget' && !!T, flyHide: () => this.setState({ fly: false }), flyFree: () => { this.setState({ fly: false }); toApp('free'); },
flyTxt: T ? 'Hoy llevas ' + this.money((T.daily || [0])[dayN - 1] || 0) + ' y tu ritmo para no pasarte es ' + this.money(allowed) + ' al día. ¿Te enseño planes gratis cerca?' : '',
cntTxt: this.money(st.cnt == null ? SPT : st.cnt), days, cats, projDash, spentOff, endTxt, bColor: over > 0 ? '#FFB86B' : accent,
projColor: over > 0 ? '#FF6B6B' : accent
};
}
}
