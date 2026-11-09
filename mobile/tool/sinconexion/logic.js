// La maqueta "SinConexion" con tus ciudades de verdad. La app pone los
// datos en window.ECL (ver lib/features/offline/offline_page.dart) y manda
// lo nuevo con window.ECLin({...}). Lo que tocas se le dice a la app con
// toApp('...'): "q:<texto>" busca, "pick:<aeropuerto>" elige la ciudad,
// "area:<0|1|2>" cuánto de ella, "audio" las voces, "add" descarga,
// "act:<código>" abre / para / sigue, "upd:<código>" actualiza,
// "del:<código>" borra, "wifi" y "auto" los interruptores, "plane" el
// modo avión de prueba y "flyMain" / "flyHide" los botones de Flyra.
// ----
const SEGC = ['#3DDC97', '#6CA8FF', '#FFB86B', '#B69CFF', '#FF8FB1', '#7FE8E0'];
const AREA_BOX = [[129, 52, 100, 70], [74, 22, 210, 128], [14, 6, 330, 158]];
const AREA_ZOOM = [1.6, 1.15, 1];
// Los trocitos del mapa de OpenStreetMap alrededor de la ciudad (cuadro de
// 358 × 170, como el de la maqueta).
function tilesFor(lat, lon) {
if (typeof lat !== 'number' || typeof lon !== 'number') return [];
// Que el cuadro abarque unos 27 km (lo de "Ciudad" ocupa más o menos 16).
const kmPerPx = 27 / 358;
let z = Math.round(Math.log2(40075 * Math.cos(lat * Math.PI / 180) / (256 * kmPerPx)));
z = Math.max(3, Math.min(16, z));
const n = Math.pow(2, z);
const px = (lon + 180) / 360 * n * 256;
const r = lat * Math.PI / 180;
const py = (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n * 256;
const out = [];
for (let tx = Math.floor((px - 179) / 256); tx <= Math.floor((px + 179) / 256); tx++) {
for (let ty = Math.floor((py - 85) / 256); ty <= Math.floor((py + 85) / 256); ty++) {
if (ty < 0 || ty >= n) continue;
const x = ((tx % n) + n) % n;
// Como fondo (no como <img>): si no hay internet no sale el icono de imagen rota.
out.push('position: absolute; width: 256px; height: 256px; background-size: cover; background-image: url(https://tile.openstreetmap.org/' + z + '/' + x + '/' + ty + '.png); left: ' + Math.round(179 + tx * 256 - px) + 'px; top: ' + Math.round(85 + ty * 256 - py) + 'px');
}
}
return out;
}
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { n: 0, confirm: '', burst: '', flyHidden: 0 };
this.burstN = this.E.burstN || 0;
}
componentDidMount() {
window.ECLin = (d) => {
Object.assign(this.E, d || {});
const st = { n: this.state.n + 1 };
// Acaba de terminar una: el estallido de colores (la vibración la pone la app).
if ((this.E.burstN || 0) !== this.burstN) {
this.burstN = this.E.burstN || 0;
st.burst = this.E.burst || '';
clearTimeout(this.bt);
this.bt = setTimeout(() => this.setState({ burst: '' }), 1400);
}
this.setState(st);
};
}
componentWillUnmount() { clearTimeout(this.bt); }
renderVals() {
const st = this.state;
const E = this.E;
const T = E.t || {};
const accent = this.props.accent ?? '#3DDC97';
const plane = !!E.plane;
const items = (E.items || []).map((x, i) => {
const done = x.st === 'done', down = x.st === 'down', paused = x.st === 'paused', queued = x.st === 'queued', upd = x.st === 'updating';
const working = (down || upd) && !plane;
const pr = Math.max(0, Math.min(100, x.pr || 0));
const dCol = plane ? (x.ok ? '#3DDC97' : '#FF9A7A') : x.warn ? '#FFB86B' : '#9FB0B8';
const burst = st.burst === x.id ? Array.from({ length: 10 }, (_, k) => { const a = k / 10 * Math.PI * 2; return 'position: absolute; left: 22px; top: 22px; width: 8px; height: 8px; border-radius: 4px; pointer-events: none; background: ' + SEGC[k % 6] + '; --dx: ' + Math.round(Math.cos(a) * 44) + 'px; --dy: ' + Math.round(Math.sin(a) * 44) + 'px; animation: sc-burst .9s ease-out both'; }) : [];
return {
name: x.name, code: x.code, isDone: done, burst, detail: x.detail,
btnText: x.btnText, actLabel: x.btnText + ' ' + x.name,
detailSt: 'font-size: 12px; font-weight: 700; color: ' + dCol,
card: 'border-radius: 22px; background: #141E25; padding: 14px; display: flex; flex-direction: column; gap: 10px; flex-shrink: 0; transition: border-color .3s, opacity .3s; border: 1px solid ' + (plane ? (x.ok ? '#2E8A5E' : '#4A2E2E') : working ? '#2E5A8A' : '#26363F') + '; opacity: ' + (plane && !x.ok ? '.6' : '1') + '; animation: sc-in .45s ease both',
flag: 'position: absolute; inset: 6px; border-radius: 13px; display: flex; align-items: center; justify-content: center; font-size: 12px; font-weight: 800; background: ' + SEGC[i % 6] + '; color: #0B1217' + (working ? '; animation: sc-blink 1.4s ease-in-out infinite' : ''),
ringCol: done ? accent : paused ? '#FFB86B' : '#6CA8FF',
dash: (144.5 * (1 - pr / 100)).toFixed(1),
showBar: !done && !paused,
bar: 'height: 8px; border-radius: 4px; transition: width .2s linear; width: ' + pr + '%; background: ' + (paused ? '#FFB86B' : 'linear-gradient(90deg, #6CA8FF, #3DDC97)'),
barShine: working ? 'position: absolute; top: 0; bottom: 0; width: 25%; background: linear-gradient(90deg, transparent, rgba(255,255,255,.5), transparent); animation: sc-shine 1.2s linear infinite' : 'display: none',
left: x.left || '', right: x.right || '',
hasUpd: done && !!x.updTxt && !plane, updTxt: x.updTxt || '',
upd: () => toApp('upd:' + x.id),
feats: (x.feats || []).map((t, k) => ({ t: '✓ ' + t, st: 'height: 24px; padding: 0 9px; border-radius: 12px; font-size: 11px; font-weight: 800; display: flex; align-items: center; color: #BFE9D6; background: #12291F; border: 1px solid #23523F; animation: sc-pop .4s ease ' + (k * 0.06).toFixed(2) + 's both' })),
act: () => toApp('act:' + x.id),
btn: 'height: 40px; min-width: 76px; border-radius: 14px; padding: 0 12px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + (done ? 'border: 1px solid #1F4237; background: #10221C; color: ' + accent : (down || upd || queued) ? 'border: 1px solid #33444E; background: transparent; color: #F2F5F3' : 'border: none; background: #FFB86B; color: #1A0B0B'),
confirm: st.confirm === x.id, canDel: !!x.canDel && st.confirm !== x.id && !plane,
askTxt: x.askTxt || '', delTxt: T.del || '', noTxt: T.no || '', delAria: (T.del || '') + ' ' + x.name,
askDel: () => this.setState({ confirm: x.id }), noDel: () => this.setState({ confirm: '' }),
del: () => { this.setState({ confirm: '' }); toApp('del:' + x.id); }
};
});
const sw = (on) => ({ track: 'width: 52px; height: 32px; flex-shrink: 0; border-radius: 16px; border: none; padding: 0; position: relative; cursor: pointer; transition: background .25s; background: ' + (on ? accent : '#33444E'), knob: 'position: absolute; top: 4px; left: ' + (on ? '24px' : '4px') + '; width: 24px; height: 24px; border-radius: 12px; transition: left .25s cubic-bezier(.2,.9,.3,1.2); background: ' + (on ? '#0B1217' : '#DCE5E9') });
const w = sw(!!E.wifi), au = sw(!!E.auto);
const area = Math.max(0, Math.min(2, E.area ?? 1));
const B = AREA_BOX[area];
const fly = E.fly || null;
const flyKey = fly ? fly.key || 1 : 0;
return {
back: () => toApp('back'), backTxt: T.back || '',
title: T.title || '', planeAria: T.planeAria || '', planeH: E.planeH || '',
heroH: T.heroH || '', heroP: T.heroP || '', areaH: T.areaH || '', searchHint: T.searchHint || '',
whatH: T.whatH || '', note: E.note || '', zonesH: T.zonesH || '', noneTxt: T.none || '',
wifiH: T.wifiH || '', wifiP: T.wifiP || '', autoH: T.autoH || '', autoP: T.autoP || '',
spaceH: T.spaceH || '', credits: T.credits || '',
flyOn: !!fly && st.flyHidden !== flyKey,
flyTitle: fly ? fly.title : '', flyText: fly ? fly.text : '',
flyMain: () => { this.setState({ flyHidden: flyKey }); toApp('flyMain'); },
flyMainTxt: fly ? fly.main : '', flyTwo: !!(fly && fly.alt), flyAltTxt: fly ? fly.alt || '' : '',
flyHide: () => { this.setState({ flyHidden: flyKey }); toApp('flyHide'); },
rootSt: 'width: 390px; height: 844px; box-sizing: border-box; font-family: Manrope, system-ui, sans-serif; color: #F2F5F3; position: relative; overflow: hidden; display: flex; flex-direction: column; padding: 18px 16px 0 16px; gap: 12px; transition: background .5s; background: ' + (plane ? 'radial-gradient(120% 40% at 50% 0%, #2A2140, #0B1217 70%)' : 'radial-gradient(120% 40% at 50% 0%, #12302A, #0B1217 70%)'),
subtitle: E.subtitle || '',
plane, planeOn: E.pretend ? 'true' : 'false', togglePlane: () => toApp('plane'),
planeText: E.planeText || '',
planeBtn: 'width: 44px; height: 44px; border-radius: 22px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; cursor: pointer; transition: all .3s; ' + (plane ? 'border: none; background: #B69CFF; color: #120C24; box-shadow: 0 0 0 4px rgba(182,156,255,.25)' : 'border: 1px solid #26363F; background: #141E25; color: #DCE5E9'),
drops: Array.from({ length: 6 }, (_, k) => 'position: absolute; left: ' + (66 + (k % 3) * 12) + 'px; top: 50px; width: 12px; height: 12px; border-radius: 3px; background: ' + SEGC[k] + '; --dx: ' + ((k % 3) * 4 - 4) + 'px; animation: sc-fall 1.8s ease-in ' + (k * 0.3).toFixed(1) + 's infinite' + (plane ? '; display: none' : '')),
search: (e) => toApp('q:' + ((e && e.target && e.target.value) || '')),
cityChips: (E.chips || []).map((c) => ({ t: c.t, on: E.city === c.code ? 'true' : 'false', pick: () => toApp('pick:' + c.code), st: 'height: 34px; padding: 0 14px; border-radius: 17px; flex-shrink: 0; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; white-space: nowrap; transition: all .25s; ' + (E.city === c.code ? 'border: none; background: #F2F5F3; color: #0B1217' : 'border: 1px solid #33444E; background: transparent; color: #DCE5E9') })),
mapImg: 'position: absolute; inset: 0; overflow: hidden; transition: transform .6s ease, filter .4s; transform: scale(' + AREA_ZOOM[area] + '); filter: ' + (plane ? 'grayscale(.8) brightness(.6) ' : '') + 'invert(1) hue-rotate(180deg) brightness(.85) contrast(.9) saturate(.5)',
tiles: tilesFor(E.lat, E.lon),
rx: B[0], ry: B[1], rw: B[2], rh: B[3],
zoneLabel: E.zoneLabel || '', hasEst: !!E.estTxt, estTxt: E.estTxt || '',
areas: (E.areas || []).map((a, i) => ({ t: a.t, s: a.s, on: area === i ? 'true' : 'false', pick: () => toApp('area:' + i), st: 'flex: 1; min-height: 50px; border-radius: 14px; font-family: inherit; cursor: pointer; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 1px; transition: all .25s; ' + (area === i ? 'border: 2px solid #3DDC97; background: #12291F; color: #F2F5F3' : 'border: 1px solid #26363F; background: #10181E; color: #B7C5CC') })),
parts: (E.parts || []).map((p) => ({ t: p.t, mark: p.on ? '✓' : '+', mb: p.mb || '', on: p.on ? 'true' : 'false', pick: () => { if (!p.locked) toApp('audio'); }, st: 'height: 32px; padding: 0 11px; border-radius: 16px; font-family: inherit; font-size: 12px; font-weight: 800; cursor: ' + (p.locked ? 'default' : 'pointer') + '; transition: all .25s; ' + (p.on ? 'border: 1px solid #2E8A5E; background: #12291F; color: #BFE9D6' : 'border: 1px dashed #4A5C66; background: transparent; color: #8FA3AD') })),
addText: E.addText || '',
addBtn: 'position: relative; overflow: hidden; height: 52px; border-radius: 16px; border: none; font-family: inherit; font-size: 14.5px; font-weight: 800; cursor: pointer; ' + (!E.canAdd ? 'background: #26363F; color: #8FA3AD' : 'background: linear-gradient(90deg, #7FF0BF, #3DDC97); color: #0B1217; box-shadow: 0 10px 26px rgba(61,220,151,.35)'),
addZone: () => { if (E.canAdd) toApp('add'); },
items, noItems: items.length === 0, countLabel: E.countLabel || '',
wifiChecked: E.wifi ? 'true' : 'false', toggleWifi: () => toApp('wifi'), wifiTrack: w.track, wifiKnob: w.knob,
autoChecked: E.auto ? 'true' : 'false', toggleAuto: () => toApp('auto'), autoTrack: au.track, autoKnob: au.knob,
usedLabel: E.usedLabel || '',
segs: (E.segs || []).map((p, i) => 'display: block; height: 100%; transition: width .3s; width: ' + p + '%; background: ' + SEGC[i % 6] + (i ? '; border-left: 2px solid #141E25' : '')),
legend: (E.legend || []).map((t, i) => ({ t, dot: 'width: 10px; height: 10px; border-radius: 5px; background: ' + SEGC[i % 6] }))
};
}
}
