class Component extends DCLogic {
// La maqueta "Qué pasa en tus fechas" con los festivos y eventos de verdad
// (festivos oficiales de Nager.Date y eventos de Ticketmaster). La app pone
// los datos en window.ECL (ver lib/features/events/events_page.dart) y manda
// lo nuevo con window.ECLin({...}).
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { day: '', cat: 'all', saved: (this.E.saved || []).slice(), burst: '', toast: '', el: 0, cnt: 0, sel: '' };
}
componentDidMount() {
window.ECLin = (d) => {
  const was = (this.E.events || []).length;
  Object.assign(this.E, d || {});
  const st = {};
  if (d && d.saved) st.saved = d.saved.slice();
  // Llegan otros eventos (otra ciudad u otras fechas): se empieza de cero.
  if (d && d.events && (this.E.key !== this.key)) { this.key = this.E.key; st.day = ''; st.cat = 'all'; st.sel = ''; st.cnt = 0; this.grow(); }
  this.setState(st);
  if (d && d.toast) this.say(d.toast);
  void was;
};
this.key = this.E.key;
// La cuenta atrás: cada segundo.
this.iv = setInterval(() => { const st = this.state; this.setState({ el: st.el + 1, cnt: Math.min((this.E.events || []).length, st.cnt + 1) }); }, 1000);
this.grow();
}
grow() { clearTimeout(this.t0); this.t0 = setTimeout(() => this.setState({ cnt: (this.E.events || []).length }), 1800); }
componentWillUnmount() { clearInterval(this.iv); clearTimeout(this.t0); clearTimeout(this.t1); clearTimeout(this.t2); }
say(msg) { clearTimeout(this.t2); this.setState({ toast: msg }); this.t2 = setTimeout(() => this.setState({ toast: '' }), 3000); }
renderVals() {
const st = this.state;
const E = this.E;
const EV = E.events || [];
const DAYS = E.days || [];
const days = [{ k: '', n: '★', dow: 'TODOS' }].concat(DAYS).map((d, k) => {
const on = st.day === d.k;
const c = d.k === '' ? EV.length : EV.filter((e) => e.dk === d.k).length;
const dot = (j) => 'width: 5px; height: 5px; border-radius: 3px; background: ' + (j < Math.min(3, c) ? (on ? '#120C24' : '#FF7AB6') : 'transparent') + (j < c && !on ? '; animation: ev-dot 1.8s ease-in-out ' + (j * 0.2 + k * 0.1) + 's infinite' : '');
return { n: d.n, dow: d.dow, on: on ? 'true' : 'false', pick: () => this.setState({ day: d.k, sel: '' }), d0: dot(0), d1: dot(1), d2: dot(2),
st: 'flex: 1; height: 66px; border-radius: 16px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; font-family: inherit; cursor: pointer; transition: transform .25s, background .25s; padding: 0; ' + (on ? 'background: linear-gradient(160deg, #FFD27A, #FF7AB6); color: #120C24; border: none; transform: translateY(-3px); box-shadow: 0 10px 22px rgba(255,122,182,.35)' : 'background: #141E25; color: #F2F5F3; border: 1px solid #26363F') };
});
const cats = CATS.map(([id, label, ik]) => { const on = st.cat === id; return { label, img: ICO[ik][2], on: on ? 'true' : 'false', pick: () => this.setState({ cat: id, sel: '' }),
st: 'height: 40px; border-radius: 20px; display: flex; align-items: center; gap: 7px; padding: 0 12px 0 5px; flex-shrink: 0; font-family: inherit; font-size: 12.5px; font-weight: 800; cursor: pointer; transition: background .25s; ' + (on ? 'background: #F2F5F3; color: #120C24; border: none' : 'background: #141E25; color: #E3DAFF; border: 1px solid #26363F'),
ico: 'width: 30px; height: 30px; border-radius: 15px; display: flex; align-items: center; justify-content: center; background: radial-gradient(120% 100% at 30% 20%, ' + ICO[ik][0] + ', ' + ICO[ik][1] + ')' }; });
const vis = EV.filter((e) => (st.day === '' || e.dk === st.day) && (st.cat === 'all' || e.cat === st.cat) && (st.sel === '' || st.sel === e.id));
const now = Date.now();
const events = vis.map((e, k) => {
const i = e.id;
const saved = st.saved.includes(i);
const planned = (E.planned || []).includes(i);
const ik = e.ik; const [c1, c2] = ICO[ik];
const bst = (j) => { const a = j / 6 * Math.PI * 2; return 'position: absolute; left: 10px; top: 8px; font-size: 11px; color: #FF7AB6; pointer-events: none; --dx: ' + (Math.cos(a) * 26).toFixed(0) + 'px; --dy: ' + (Math.sin(a) * 26).toFixed(0) + 'px; ' + (st.burst === i ? 'display: block; animation: ev-burst .7s ease-out both' : 'display: none'); };
return Object.assign({ name: e.name, when: e.when, price: e.price, priceSt: 'font-size: 11.5px; font-weight: 800; color: ' + (e.free ? '#3DDC97' : '#FFD27A'), src: e.src, img: ICO[ik][2],
dow: e.dow, day: e.day, statusTxt: e.stTxt,
status: 'height: 18px; white-space: nowrap; flex-shrink: 0; border-radius: 9px; font-size: 9.5px; font-weight: 800; letter-spacing: .04em; display: flex; align-items: center; padding: 0 7px; color: #120C24; background: ' + e.stCol,
cd: cdTxt(Math.max(0, Math.round((e.start - now) / 1000))),
go: () => { if (e.url) toApp('open:0:' + pack({ u: e.url })); else toApp('vote'); }, btnTxt: e.url ? 'Entradas' : 'Ver plan',
btn: 'height: 32px; border-radius: 11px; background: linear-gradient(90deg, ' + c1 + ', #FFFFFF); color: #120C24; font-size: 11.5px; font-weight: 800; display: flex; align-items: center; padding: 0 12px; text-decoration: none; cursor: pointer',
planTxt: planned ? '✓ En planes' : '+ Planes',
toPlan: () => { if (!planned) toApp('plan:0:' + pack({ id: i })); },
saved: saved ? 'true' : 'false', fill: saved ? '#FF7AB6' : 'none',
heartSt: st.burst === i ? 'animation: ev-pop .5s ease both' : '',
save: () => { clearTimeout(this.t1); this.setState({ saved: saved ? st.saved.filter((x) => x !== i) : st.saved.concat([i]), burst: saved ? '' : i }); this.t1 = setTimeout(() => this.setState({ burst: '' }), 800); toApp('save:' + (saved ? 0 : 1) + ':' + pack({ id: i })); if (!saved) this.say('Guardado. Flyra te avisa la víspera y 2 horas antes.'); },
card: 'position: relative; overflow: hidden; display: flex; border-radius: 20px; background: linear-gradient(135deg, #1D1636, #141E25); border: 1px solid ' + (st.sel === i ? c1 : '#2E2650') + '; box-shadow: 0 12px 26px -12px ' + c1 + '; animation: ev-in .55s cubic-bezier(.2,.9,.3,1.1) ' + (k * 0.09).toFixed(2) + 's both',
shine: 'position: absolute; top: 0; bottom: 0; left: 0; width: 60px; background: linear-gradient(90deg, transparent, rgba(255,255,255,.10), transparent); pointer-events: none; animation: ev-shine 7s ease-in-out ' + (1 + k * 1.3).toFixed(1) + 's infinite',
left: 'width: 78px; flex-shrink: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; color: #fff; background: radial-gradient(120% 90% at 30% 20%, ' + c1 + ', ' + c2 + ')'
}, { b0: bst(0), b1: bst(1), b2: bst(2), b3: bst(3), b4: bst(4), b5: bst(5) });
});
const pins = (E.pins || []).map((p, i) => { const on = st.sel === p.id; const [c1, c2] = ICO[p.ik]; return { name: p.name, img: ICO[p.ik][2], pick: () => this.setState({ sel: on ? '' : p.id, day: '', cat: 'all' }),
st: 'position: absolute; left: ' + p.x + '%; top: ' + p.y + '%; width: 38px; height: 38px; margin: -19px; padding: 0; border: none; background: none; cursor: pointer; animation: ev-pin .6s cubic-bezier(.2,.9,.3,1.3) ' + (0.3 + i * 0.15).toFixed(2) + 's both',
ring: 'position: absolute; inset: 0; border-radius: 50%; border: 2px solid ' + c1 + '; animation: ev-ring 2.2s ease-out ' + (i * 0.3).toFixed(1) + 's infinite',
ico: 'position: absolute; inset: 0; border-radius: 50%; display: flex; align-items: center; justify-content: center; border: 3px solid #fff; box-shadow: 0 4px 10px rgba(0,0,0,.45); background: radial-gradient(120% 100% at 30% 20%, ' + c1 + ', ' + c2 + ')' + (on ? '; transform: scale(1.25)' : '') }; });
const notes = Array.from({ length: 6 }, (_, k) => 'position: absolute; bottom: 50px; left: ' + (40 + R(k + 3, 300)).toFixed(0) + 'px; font-size: ' + (14 + R(k, 10)).toFixed(0) + 'px; color: ' + ['#FFD27A', '#FF7AB6', '#B69CFF', '#7FE8B9'][k % 4] + '; --dx: ' + (R(k + 7, 60) - 30).toFixed(0) + 'px; --r: ' + (R(k, 60) - 30).toFixed(0) + 'deg; animation: ev-note ' + (3 + R(k + 1, 2)).toFixed(1) + 's ease-out ' + R(k + 5, 3).toFixed(1) + 's infinite');
const hotel = !!E.hotel;
return {
days, cats, events, pins, notes, empty: events.length === 0,
emptyTxt: EV.length ? 'Ese día no hay nada de este tipo. Prueba con otro día o con «Todo».' : (E.emptyTxt || ''),
count: st.cnt, heroSub: st.sel ? 'Filtrando por el pin del mapa · toca otra vez para quitar' : 'Conciertos, fiestas, deporte y teatro, cerca de ti',
srcTxt: E.src || '', srcSt: E.src ? '' : 'display: none',
subTitle: E.sub || '', options: () => toApp('options'), back: () => toApp('back'),
hotelSt: hotel ? '' : 'display: none', setHotel: () => toApp('hotel'),
mapNote: hotel ? 'Toca un pin para ver su evento. El punto azul es tu hotel.' : 'Toca un pin para ver su evento. Toca el mapa para marcar tu hotel.',
hasPins: pins.length > 0,
tip: E.tip || '', vote: () => toApp('vote'),
hasToast: !!st.toast, toast: st.toast
};
}
}
