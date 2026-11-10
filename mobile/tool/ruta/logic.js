// La maqueta "Ruta" con tu ruta de verdad. La app pone los datos en
// window.ECL (ver lib/features/route/route_page.dart) y manda lo nuevo con
// window.ECLin({...}). Lo que tocas se le dice a la app con toApp('...'):
// "back", "pick" (elegir destino), "fly3d", "more:o" / "more:d" (Wikipedia)
// y "sight:o:<n>" / "sight:d:<n>" (un sitio de "Lo más visitado").
//
// El mapa es el de la maqueta: 1 grado = 1 punto (x = longitud + 180,
// y = 90 − latitud). El camino ([x, y]...) es el círculo máximo de verdad.
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { n: 0, view: 'world', t: 0, follow: false };
this.seq = this.E.arrive || 0;
}
componentDidMount() {
window.ECLin = (d) => {
Object.assign(this.E, d || {});
// Al volver del vuelo en 3D, ya estás en el destino.
if ((this.E.arrive || 0) !== this.seq) { this.seq = this.E.arrive || 0; this.stop(); this.setState({ view: 'dest', t: 1, follow: false, n: this.state.n + 1 }); return; }
// Ruta nueva (otro destino): se vuelve a ver el mundo.
if (d && d.path) { this.stop(); this.setState({ view: 'world', t: 0, follow: false, n: this.state.n + 1 }); return; }
this.setState({ n: this.state.n + 1 });
};
}
componentWillUnmount() { this.stop(); }
stop() { clearInterval(this.tick); clearTimeout(this.wait); }
startFlight() {
if (!this.E.d) return;
this.stop();
this.setState({ view: 'flight', t: 0, follow: false });
this.wait = setTimeout(() => {
this.setState({ follow: true });
this.tick = setInterval(() => {
const t = Math.min(1, this.state.t + 0.008);
if (t >= 1) { clearInterval(this.tick); this.setState({ t: 1, view: 'dest', follow: false }); }
else this.setState({ t });
}, 50);
}, 1100);
}
// El punto del camino a [t] (0 = origen, 1 = destino), por distancia.
along(path, t) {
if (path.length < 2) return { p: path[0] || [180, 90], d: [1, 0] };
if (!this.lens || this.lensFor !== path) {
const L = [0];
for (let i = 1; i < path.length; i++) L.push(L[i - 1] + Math.hypot(path[i][0] - path[i - 1][0], path[i][1] - path[i - 1][1]));
this.lens = L; this.lensFor = path;
}
const L = this.lens, want = t * L[L.length - 1];
let i = 1;
while (i < L.length - 1 && L[i] < want) i++;
const a = path[i - 1], b = path[i];
const seg = (L[i] - L[i - 1]) || 1;
const f = Math.max(0, Math.min(1, (want - L[i - 1]) / seg));
return { p: [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f], d: [b[0] - a[0], b[1] - a[1]] };
}
place(P, key) {
if (!P) return {};
return Object.assign({}, P, {
hasMore: !!P.more,
more: () => toApp('more:' + key),
hasSights: (P.sights || []).length > 0,
sights: (P.sights || []).map((g, i) => ({
name: g.name,
open: () => toApp('sight:' + key + ':' + i),
pic: 'display: block; width: 128px; height: 92px; border-radius: 14px; background: ' + (g.img ? 'url("' + g.img + '") center / cover no-repeat, #1C2A33' : 'linear-gradient(150deg, #1C2A33, #13213A)')
}))
});
}
chip(x, label, color) {
const w = String(label || '').length * 5.8 + 16;
let shift = 0;
if (x - w / 2 < 6) shift = 6 - (x - w / 2);
else if (x + w / 2 > 352) shift = 352 - (x + w / 2);
return 'position: absolute; left: 50%; bottom: 36px; transform: translateX(calc(-50% + ' + shift.toFixed(0) + 'px)); height: 22px; border-radius: 11px; background: ' + color + '; color: #0B1217; font-size: 10px; font-weight: 800; padding: 0 8px; display: flex; align-items: center; white-space: nowrap; transition: transform 0.6s ease';
}
renderVals() {
const E = this.E;
const { view, t, follow } = this.state;
const path = E.path || [];
const O = E.o || { x: 180, y: 90 };
const D = E.d;
const P0 = [O.x, O.y];
const P2 = D ? [D.x, D.y] : P0;
// La vista "Mundo": que quepa la ruta entera con margen.
let minX = P0[0], maxX = P0[0], minY = P0[1], maxY = P0[1];
for (const p of path) { minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]); minY = Math.min(minY, p[1]); maxY = Math.max(maxY, p[1]); }
const wz = Math.max(0.99, Math.min(6, 358 / (maxX - minX + 60), 260 / (maxY - minY + 50)));
let cx, cy, z, dur;
if (view === 'world') { cx = wz <= 1 ? 180 : (minX + maxX) / 2; cy = wz <= 1 ? 90 : (minY + maxY) / 2; z = wz; dur = '1.3s ease'; }
else if (view === 'origin') { cx = P0[0]; cy = P0[1]; z = 6; dur = '1.3s ease'; }
else if (view === 'dest') { cx = P2[0]; cy = P2[1]; z = 6; dur = '1.3s ease'; }
else { const a = this.along(path, t).p; cx = a[0]; cy = a[1]; z = 2.6; dur = follow ? '0.06s linear' : '1.1s ease'; }
const toScreen = (p) => [179 + (p[0] - cx) * z, 130 + (p[1] - cy) * z];
const pos = view === 'dest' ? this.along(path, 1) : view === 'flight' ? this.along(path, t) : this.along(path, 0);
const planeAt = view === 'dest' ? P2 : view === 'flight' ? pos.p : P0;
const angle = Math.atan2(pos.d[1], pos.d[0]) * 180 / Math.PI;
const ps = toScreen(planeAt), ms = toScreen(P0), ts = toScreen(P2);
const btn = (s, show) => 'position: absolute; left: ' + (s[0] - 22) + 'px; top: ' + (s[1] - 22) + 'px; width: 44px; height: 44px; border: none; background: transparent; padding: 0; cursor: pointer; transition: left ' + dur + ', top ' + dur + (show ? '' : '; display: none');
// Por dónde va el avión: el último tramo ya pasado.
let region = '';
for (const r of (E.regions || [])) if (r.at <= t + 1e-9) region = r.label;
const total = E.mins || 0;
const leftMin = Math.round((1 - t) * total);
const shown = view === 'dest' ? 1 : view === 'flight' ? t : 0;
const km = Math.round(t * (E.km || 0));
let kmTxt;
try { kmTxt = km.toLocaleString(E.loc || 'es'); } catch (e) { kmTxt = String(km); }
const P = view === 'dest' ? this.place(E.dp, 'd') : this.place(E.op, 'o');
const go = (v) => () => { this.stop(); this.setState({ view: v, t: v === 'dest' ? 1 : 0, follow: false }); };
return {
back: () => toApp('back'), backTxt: E.backTxt || '',
title: E.title || '', sub: E.sub || '', worldTxt: E.worldLbl || '',
path: path.map((p) => p[0].toFixed(2) + ',' + p[1].toFixed(2)).join(' '),
ox: P0[0], oy: P0[1], dx: P2[0], dy: P2[1], hasDest: !!D,
camStyle: 'transform: translate(179px, 130px) scale(' + z + ') translate(' + (-cx) + 'px, ' + (-cy) + 'px); transition: transform ' + dur,
trail: shown + ' 1',
dotR: (5 / z).toFixed(3),
madridBtn: btn(ms, true), tokyoBtn: btn(ts, !!D),
oLbl: O.lbl || '', dLbl: D ? D.lbl : '', oFlag: O.flag || '', dFlag: D ? (D.flag || '') : '',
hasPass: view === 'world' && !!E.pass,
// La etiqueta con el nombre del aeropuerto no se sale del mapa: si el
// punto está cerca del borde, la etiqueta se corre hacia dentro.
oChip: this.chip(ms[0], O.lbl, '#6CA8FF'), dChip: this.chip(ts[0], D ? D.lbl : '', '#FF8A65'), oAria: O.aria || '', dAria: D ? D.aria : '',
planeStyle: 'position: absolute; left: ' + (ps[0] - 28) + 'px; top: ' + (ps[1] - 28) + 'px; width: 56px; height: 56px; pointer-events: none; transform: rotate(' + angle.toFixed(1) + 'deg) scale(' + (view === 'world' ? 0.55 : 1) + '); filter: drop-shadow(0 12px 6px rgba(0,0,0,0.5)); transition: left ' + dur + ', top ' + dur + ', transform ' + dur + (D ? '' : '; display: none'),
zoomLabel: view === 'world' ? (E.worldLbl || '') : view === 'origin' ? 'Zoom: ' + (O.city || '') : view === 'dest' ? 'Zoom: ' + (D ? D.city : '') : (E.followLbl || ''),
isWorld: view === 'world', isOrigin: view === 'origin', isFlight: view === 'flight', isDest: view === 'dest',
isPlace: view === 'origin' || view === 'dest',
worldH: E.worldH || '', worldP: E.worldP || '', startTxt: E.startTxt || '',
pick: () => toApp('pick'), pickTxt: E.pickTxt || '',
pickSt: D ? 'background: transparent; border: none; color: #9CC4FF; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; padding: 0' : 'width: 100%; height: 50px; border-radius: 16px; border: none; background: #6CA8FF; color: #0B1217; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer',
simTxt: E.simTxt || '', regionLabel: region,
progressStyle: 'height: 10px; border-radius: 5px; background: #6CA8FF; width: ' + Math.round(t * 100) + '%',
doneTxt: E.doneTxt || '', leftTxt: E.leftTxt || '',
kmLabel: kmTxt + ' km',
leftLabel: Math.floor(leftMin / 60) + ' h ' + (leftMin % 60) + ' min',
land: go('dest'), landTxt: E.landTxt || '',
P, whyH: E.whyH || '', moreTxt: E.moreTxt || '', sightsH: E.sightsH || '',
flyTxt: E.flyTxt || '', has3d: !!E.has3d, fly3d: () => toApp('fly3d'), fly3dTxt: E.fly3dTxt || '',
replayTxt: E.replayTxt || '', backOriginTxt: E.backOriginTxt || '',
credits: E.credits || '',
goWorld: go('world'), goOrigin: go('origin'), goDest: () => { if (D) go('dest')(); },
fly: () => this.startFlight(), replayFlight: () => this.startFlight()
};
}
}
