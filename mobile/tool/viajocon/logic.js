// La maqueta "ViajoCon" con los datos de tu perro. La app pone los datos en
// window.ECL (ver lib/features/travel_with/travel_with_page.dart) y manda lo
// nuevo con window.ECLin({...}). Lo que tocas se le dice a la app con
// toApp('...'): "photo" elige la foto, "nophoto" la quita, "name:<nombre>",
// "check:<n>" marca lo del pasaporte, "kind:<tipo>" elige veterinarios,
// parques u hoteles, "spot:<n>:<go|call|web>", "goNear", "retry",
// "bag:<n>" la maleta y "petKg:<kg>" / "carrierKg:<kg>" lo que pesa.
// ----
// El mapa de OpenStreetMap alrededor de ti (cuadro de 358 × 200) con el
// zum justo para que se vean las marcas de los sitios más cercanos.
// Tú no vas en el centro: un poco más abajo, para que quepan las marcas
// (se dibujan hacia arriba) y el rótulo de arriba.
const MAP_W = 358, MAP_H = 200, CX = 179, CY = 130;
function worldPx(lat, lon, z) {
const n = Math.pow(2, z) * 256;
const r = lat * Math.PI / 180;
return [(lon + 180) / 360 * n, (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n];
}
function mapView(me, pins) {
if (!me) return null;
let z = 17;
for (; z > 3; z--) {
const c = worldPx(me.lat, me.lon, z);
const fits = pins.every((p) => { const q = worldPx(p.lat, p.lon, z); const dy = q[1] - c[1]; return Math.abs(q[0] - c[0]) < CX - 34 && dy > 70 - CY && dy < MAP_H - 12 - CY; });
if (fits) break;
}
const c = worldPx(me.lat, me.lon, z);
const n = Math.pow(2, z);
const tiles = [];
for (let tx = Math.floor((c[0] - CX) / 256); tx <= Math.floor((c[0] + MAP_W - CX) / 256); tx++) {
for (let ty = Math.floor((c[1] - CY) / 256); ty <= Math.floor((c[1] + MAP_H - CY) / 256); ty++) {
if (ty < 0 || ty >= n) continue;
const x = ((tx % n) + n) % n;
// Como fondo (no como <img>): si no hay internet no sale el icono de imagen rota.
tiles.push('position: absolute; width: 256px; height: 256px; background-size: cover; background-image: url(https://tile.openstreetmap.org/' + z + '/' + x + '/' + ty + '.png); left: ' + Math.round(CX + tx * 256 - c[0]) + 'px; top: ' + Math.round(CY + ty * 256 - c[1]) + 'px');
}
}
const at = (p) => { const q = worldPx(p.lat, p.lon, z); return [Math.round(CX + q[0] - c[0]), Math.round(CY + q[1] - c[1])]; };
return { tiles, at };
}
const KIND = { vet: ['vet', '#FF6B6B'], dogPark: ['tree', '#3DDC97'], petStay: ['bed', '#B69CFF'] };
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { n: 0, name: this.E.name || '', petKg: this.E.petKg || '', carrierKg: this.E.carrierKg || '', popping: false };
this.popN = this.E.popN || 0;
}
componentDidMount() {
window.ECLin = (d) => {
Object.assign(this.E, d || {});
const st = { n: this.state.n + 1 };
// Foto nueva: las huellas saltan.
if ((this.E.popN || 0) !== this.popN) {
this.popN = this.E.popN || 0;
st.popping = true;
clearTimeout(this.t);
this.t = setTimeout(() => this.setState({ popping: false }), 1600);
}
this.setState(st);
};
}
componentWillUnmount() { clearTimeout(this.t); }
renderVals() {
const st = this.state;
const E = this.E;
const T = E.t || {};
const has = !!E.photo;
const petChecks = (E.checks || []).map((c, i) => ({ label: c.label, sub: c.sub, on: !!c.on, pick: () => toApp('check:' + i),
row: 'display: flex; align-items: center; gap: 12px; min-height: 54px; border-radius: 16px; padding: 8px 10px; font-family: inherit; color: #F2F5F3; cursor: pointer; text-align: left; transition: background .3s, border .3s; background: ' + (c.on ? '#2A2012' : '#10181E') + '; border: 1px solid ' + (c.on ? '#8A6A2A' : '#26363F'),
box: 'width: 36px; height: 36px; border-radius: 12px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; transition: all .3s; ' + (c.on ? 'background: #3A2A12; border: 2px solid #FFB86B' : 'border: 2px dashed #4A5C66') }));
const nd = petChecks.filter((c) => c.on).length;
const view = mapView(E.me, E.pins || []);
const mpins = view ? (E.pins || []).map((p, i) => { const k = KIND[p.k] || KIND.vet; const xy = view.at(p); return { t: p.t, img: IC[k[0]], st: 'position: absolute; left: ' + xy[0] + 'px; top: ' + xy[1] + 'px; display: flex; flex-direction: column; align-items: center; gap: 3px; animation: vc-bob 2.4s ease-in-out ' + (i * 0.4).toFixed(1) + 's infinite',
ring: 'position: absolute; left: 50%; top: 21px; width: 42px; height: 42px; margin: -21px; border-radius: 50%; border: 2px solid ' + k[1] + '; animation: vc-ring 2s ease-out ' + (i * 0.5).toFixed(1) + 's infinite',
bd: 'position: relative; width: 42px; height: 42px; border-radius: 21px; display: flex; align-items: center; justify-content: center; border: 3px solid #fff; box-shadow: 0 6px 14px rgba(0,0,0,.45); background: ' + k[1],
tg: 'font-size: 10px; font-weight: 800; padding: 2px 7px; border-radius: 8px; background: rgba(11,18,23,.85); white-space: nowrap; max-width: 120px; overflow: hidden; text-overflow: ellipsis' }; }) : [];
const mcats = (E.cats || []).map((c, i) => { const k = KIND[c.k] || KIND.vet; const on = E.kind === c.k; return { t: c.t, img: IC[k[0]], on: on ? 'true' : 'false', pick: () => toApp('kind:' + c.k), st: 'flex: 1; height: 34px; border-radius: 12px; display: flex; align-items: center; justify-content: center; gap: 5px; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; transition: background .3s, color .3s; color: ' + (on ? '#0B1217' : '#F2F5F3') + '; background: ' + (on ? k[1] : '#0F1820') + '; border: 1px solid ' + k[1] + '; animation: vc-pop .5s cubic-bezier(.2,.9,.3,1.3) ' + (0.3 + i * 0.1).toFixed(1) + 's both' }; });
const spots = (E.spots || []).map((p, i) => ({ name: p.name, sub: p.sub, hasPhone: !!p.phone, hasWeb: !!p.web,
call: () => toApp('spot:' + i + ':call'), web: () => toApp('spot:' + i + ':web'), go: () => toApp('spot:' + i + ':go'),
callTxt: T.call || '', webTxt: T.web || '', goTxt: T.go || '' }));
const bag = (E.bag || []).map((b, i) => ({ t: b.t, on: !!b.on, mark: b.on ? '✓' : '', pick: () => toApp('bag:' + i),
st: 'display: flex; align-items: center; gap: 8px; min-height: 44px; border-radius: 14px; padding: 6px 10px; font-family: inherit; font-size: 12.5px; font-weight: 700; color: #F2F5F3; text-align: left; cursor: pointer; transition: background .3s, border .3s; background: ' + (b.on ? '#12291F' : '#10181E') + '; border: 1px solid ' + (b.on ? '#2E8A5E' : '#26363F'),
dot: 'width: 22px; height: 22px; border-radius: 11px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 900; color: #0B1217; transition: all .3s; ' + (b.on ? 'background: #3DDC97; animation: vc-pop .4s cubic-bezier(.2,.9,.3,1.3) both' : 'border: 2px solid #4A5C66') }));
const nb = bag.filter((b) => b.on).length;
const v = E.verdict || null;
const vc = v && v.cabin ? '#3DDC97' : '#FFB86B';
return {
back: () => toApp('back'), backTxt: T.back || '', title: T.title || '',
name: st.name,
setName: (e) => { const v = ((e && e.target && e.target.value) || '').slice(0, 30); if (v !== st.name) { this.setState({ name: v }); toApp('name:' + v); } },
nameHint: T.nameHint || '', nameLine: st.name.trim() ? 'transparent' : '#FFB86B',
petH: E.petH || '', bagH: E.bagH || '', bagFullTxt: E.bagFullTxt || '',
petChecks, mpins, mcats, bag, bagDone: nb + ' de ' + bag.length, bagFull: bag.length > 0 && nb === bag.length,
source: T.source || '', outsideEu: T.outsideEu || '',
rootSt: 'width: 390px; height: 844px; box-sizing: border-box; font-family: Manrope, system-ui, sans-serif; color: #F2F5F3; position: relative; overflow: hidden; display: flex; flex-direction: column; padding: 16px 16px 0 16px; gap: 12px; background: radial-gradient(120% 50% at 50% 0%, #3A2A12 0%, #0B1217 60%)',
hasPhoto: has, noPhoto: !has, photo: E.photo || '',
pickPhoto: () => toApp('photo'), photoAria: T.photoAria || '',
removePhoto: () => toApp('nophoto'), removeTxt: T.remove || '',
photoHint: E.photoHint || '',
ringSt: 'position: absolute; inset: -8px; border-radius: 50%; ' + (has ? 'border: 4px solid #FFB86B; animation: vc-glow 2.6s ease-in-out infinite' : 'border: 3px dashed #FFB86B; animation: vc-spin 14s linear infinite'),
photoSt: 'position: absolute; inset: 0; border-radius: 50%; overflow: hidden; cursor: pointer; display: block; background: radial-gradient(circle at 35% 30%, #FFD9A8, #C88A4E); animation: vc-breath 3.2s ease-in-out infinite',
burst: st.popping ? Array.from({ length: 10 }, (_, k) => { const a = k / 10 * Math.PI * 2; const d = 90 + R(k, 40); return 'position: absolute; left: 63px; top: 63px; width: 24px; height: 24px; pointer-events: none; --dx: ' + (Math.cos(a) * d).toFixed(0) + 'px; --dy: ' + (Math.sin(a) * d).toFixed(0) + 'px; --r: ' + (R(k + 3, 90) - 45).toFixed(0) + 'deg; animation: vc-paw 1.1s ease-out ' + R(k + 5, 0.2).toFixed(2) + 's both'; }) : [],
hearts: has ? [0, 1, 2].map((k) => 'position: absolute; left: ' + (30 + k * 40) + 'px; top: 20px; font-size: ' + (14 + k * 4) + 'px; color: #FF7AB6; pointer-events: none; animation: vc-heart 2.6s ease-out ' + (k * 0.8).toFixed(1) + 's infinite') : [],
trail: Array.from({ length: 6 }, (_, k) => 'position: absolute; left: ' + (12 + k * 62) + 'px; top: ' + (k % 2 ? 196 : 210) + 'px; width: 18px; height: 18px; opacity: .15; transform: rotate(80deg); animation: vc-walk 3s ease-in-out ' + (k * 0.35).toFixed(2) + 's infinite'),
chips: (E.chips || []).map((c, i) => ({ t: c.t, st: 'height: 28px; border-radius: 14px; padding: 0 12px; font-size: 12px; font-weight: 800; display: flex; align-items: center; color: #0B1217; background: ' + c.c + '; animation: vc-pop .5s cubic-bezier(.2,.9,.3,1.3) ' + (0.2 + i * 0.1).toFixed(1) + 's both' })),
petDone: nd + ' de ' + petChecks.length, petBar: 'display: block; height: 100%; border-radius: 5px; background: linear-gradient(90deg, #FFB86B, #FF8A65); transition: width .5s cubic-bezier(.2,.9,.3,1.1); width: ' + (petChecks.length ? Math.round(nd / petChecks.length * 100) : 0) + '%',
mapSt: 'position: absolute; inset: 0; overflow: hidden; filter: invert(1) hue-rotate(180deg) brightness(.85) contrast(.9) saturate(.5)',
tiles: view ? view.tiles : [], hasMe: !!view,
meSt: 'position: absolute; left: ' + CX + 'px; top: ' + CY + 'px; width: 16px; height: 16px; border-radius: 8px; background: #6CA8FF; border: 3px solid #fff; transform: translate(-50%,-50%); box-shadow: 0 2px 8px rgba(0,0,0,.5)',
mapLabel: T.mapLabel || '', nearH: T.nearH || '',
hasMsg: !!E.nearMsg, nearMsg: E.nearMsg || '',
canRetry: !!E.canRetry, retry: () => toApp('retry'), retryTxt: T.retry || '',
spots, canGo: !!E.canGo, goNear: () => toApp('goNear'), goNearTxt: T.goNear || '',
hasAttr: !!E.attr, attr: E.attr || '',
planeH: T.planeH || '', planeP: T.planeP || '',
petKgTxt: T.petKg || '', carrierKgTxt: T.carrierKg || '', petKg: st.petKg, carrierKg: st.carrierKg,
setPetKg: (e) => { const v = ((e && e.target && e.target.value) || '').replace(/[^0-9.,]/g, '').slice(0, 5); this.setState({ petKg: v }); toApp('petKg:' + v); },
setCarrierKg: (e) => { const v = ((e && e.target && e.target.value) || '').replace(/[^0-9.,]/g, '').slice(0, 5); this.setState({ carrierKg: v }); toApp('carrierKg:' + v); },
hasVerdict: !!v, verdictH: v ? v.h : '', verdictP: v ? v.p : '',
verdictSt: 'display: flex; flex-direction: column; gap: 3px; border-radius: 14px; padding: 10px 12px; animation: vc-pop .45s cubic-bezier(.2,.9,.3,1.3) both; color: ' + vc + '; background: ' + (v && v.cabin ? '#12291F' : '#2A2012') + '; border: 1px solid ' + vc,
disclaimer: T.disclaimer || ''
};
}
}
