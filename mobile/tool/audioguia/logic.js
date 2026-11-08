class Component extends DCLogic {
// La maqueta "Audioguía" con tu audioguía. La app pone los datos en
// window.ECL (ver lib/features/audioguide/audioguide_page.dart) y manda por
// dónde va el audio con window.ECLin({...}). Lo que tocas se le dice a la
// app con toApp('...'): ella mueve el audio de verdad.
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { current: this.E.part || 0, playing: !!this.E.playing, pos: this.E.pos || 0, seek: null, dl: false, n: 0 };
}
componentDidMount() {
window.ECLin = (d) => {
  Object.assign(this.E, d || {});
  // Mientras arrastras, manda tu dedo (no lo que diga el audio).
  if (this.wDrag || this.drag) { this.setState({ n: this.state.n + 1 }); return; }
  const st = { n: this.state.n + 1 };
  if (d && d.part !== undefined) st.current = d.part;
  if (d && d.pos !== undefined) st.pos = d.pos;
  if (d && d.playing !== undefined) st.playing = d.playing;
  this.setState(st);
  if (d && d.alertKey && d.alertKey !== this.alertKey) this.alert(d.alertKey);
};
// Entre aviso y aviso de la app, el reloj sigue solo (suave).
this.tick = setInterval(() => {
  if (!this.state.playing || this.state.seek !== null || this.wDrag) return;
  const dur = this.dur(this.state.current);
  const p = this.state.pos + 0.25 * (this.E.speed || 1);
  this.setState({ pos: Math.min(p, Math.max(0, dur - 0.05)) });
}, 250);
if (this.E.alertKey) this.alert(this.E.alertKey);
}
componentWillUnmount() { clearInterval(this.tick); clearTimeout(this.tdl); }
alert(k) { this.alertKey = k; this.setState({ dl: true }); clearTimeout(this.tdl); this.tdl = setTimeout(() => this.setState({ dl: false }), 3500); }
dur(i) { const P = this.E.parts || []; return Math.max(1, (P[i] || {}).dur || 1); }
seekTo(sec) { const cur = this.state.current; const v = Math.max(0, Math.min(this.dur(cur) - 0.5, sec)); this.setState({ pos: v }); toApp('seek:' + Math.round(v * 1000) + ':' + cur); }
goPart(i) { this.setState({ current: i, pos: 0 }); toApp('part:' + i); }
stopsAt(n) {
  // Las paradas, repartidas a lo largo del camino dibujado.
  if (this.pts && this.pts.length === n) return this.pts;
  const D = 'M30 92 C 60 92, 80 38, 120 38 S 190 84, 222 84 S 290 34, 318 34';
  let pts = [];
  try {
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('style', 'position: absolute; width: 0; height: 0');
    const p = document.createElementNS(NS, 'path'); p.setAttribute('d', D); svg.appendChild(p); document.body.appendChild(svg);
    const L = p.getTotalLength();
    for (let i = 0; i < n; i++) { const q = p.getPointAtLength(n === 1 ? 0 : L * i / (n - 1)); pts.push([q.x, q.y]); }
    svg.remove();
  } catch (e) { pts = Array.from({ length: n }, (_, i) => [30 + (n === 1 ? 0 : 288 * i / (n - 1)), 60]); }
  this.pts = pts;
  return pts;
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const E = this.E;
const list = E.parts || [];
const N = Math.max(1, list.length);
const cur = Math.min(this.state.current, N - 1);
const P = list[cur] || { t: '', text: '', dur: 1 };
const dur = this.dur(cur);
const fmt = (v) => Math.floor(v / 60) + ':' + String(Math.floor(v % 60)).padStart(2, '0');
const seek = this.state.seek;
const shown = seek === null ? this.state.pos : Math.max(0, Math.min(dur - 1, this.state.pos + seek));
const clampTo = (v) => Math.max(0, Math.min(dur - 1, v));
const heights = [10, 18, 26, 14, 32, 22, 38, 28, 16, 30, 40, 24, 12, 34, 20, 28, 36, 18, 26, 14, 30, 22, 38, 16, 24, 32, 12, 28, 20, 34, 18, 26, 14, 30, 22, 16, 24, 12, 20, 10];
const frac = Math.max(0, Math.min(1, shown / dur));
const playingNow = this.state.playing && seek === null && !this.wDrag;
const bars = heights.map((h, i) => { const done = i < frac * 40; const near = Math.abs(i - frac * 40) < 4;
  return { style: 'flex: 1; height: ' + h + 'px; border-radius: 2px; transform-origin: center; background: ' + (done ? accent : '#33444E') + '; transition: background 0.25s' + (playingNow && (done || near) ? '; animation: au-eq ' + (0.5 + (i % 5) * 0.12).toFixed(2) + 's ease-in-out ' + ((i % 7) * 0.07).toFixed(2) + 's infinite' : '') }; });
const scrub = this.wDrag ? true : false;
const parts = list.map((p, i) => ({
n: String(i + 1),
label: 'Parte ' + (i + 1),
pick: () => this.goPart(i),
style: 'height: 44px; border-radius: 14px; font-family: inherit; font-size: 15px; font-weight: 800; cursor: pointer; transition: all .3s; ' + (i === cur ? 'border: 2px solid ' + accent + '; color: #F2F5F3; background: linear-gradient(90deg, ' + accent + '66 ' + (frac * 100).toFixed(1) + '%, #141E25 ' + (frac * 100).toFixed(1) + '%)' : i < cur ? 'border: none; background: ' + accent + '; color: #0B1217' : 'border: 1px solid #26363F; background: #141E25; color: #F2F5F3')
}));
// Lo que queda por oír (esta parte y las que faltan).
let left = Math.max(0, dur - shown);
for (let i = cur + 1; i < list.length; i++) left += this.dur(i);
const PTS = this.stopsAt(N);
const done = N === 1 ? frac : (cur + frac) / (N - 1);
return {
accent, bars, parts, dots: [],
back: () => toApp('back'), text: () => toApp('text'), openPhoto: () => { if (E.photo) toApp('photo'); },
zone: E.zone || '', langLbl: E.langLbl || '', nParts: String(N),
hasPhoto: !!E.photo, noPhoto: !E.photo, photo: E.photo || '', credit: E.credit || '',
slideAlt: E.caption || '', slideCaption: E.caption || '',
currentN: String(cur + 1),
currentTitle: E.title || '',
currentLen: fmt(dur),
posLabel: fmt(shown),
rootCls: this.state.dl ? 'au-dl' : '',
speedLbl: E.speedLbl || '1×', speedCycle: () => toApp('speed'),
dl: () => toApp('dl'),
alertT: E.alertT || '', alertS: E.alertS || '',
narrLbl: playingNow ? 'HABLANDO' : 'EN PAUSA',
ring1: 'position: absolute; inset: 0; border-radius: 16px; border: 2px solid ' + accent + '; ' + (playingNow ? 'animation: au-ring 1.4s ease-out infinite' : 'opacity: 0'),
ring2: 'position: absolute; inset: 0; border-radius: 16px; border: 2px solid ' + accent + '; ' + (playingNow ? 'animation: au-ring 1.4s ease-out .7s infinite' : 'opacity: 0'),
words: (() => { const W = (P.text || '').split(' ').filter((w) => w); const lit = frac * W.length; return W.map((t, i) => ({ t, st: 'display: inline-block; border-radius: 6px; padding: 0 2px; margin: 0 -2px; transition: color .3s, background .3s, transform .3s; ' + (i < Math.floor(lit) ? 'color: #F2F5F3' : (i === Math.floor(lit) && E.hasAudio ? 'color: #0B1217; background: ' + accent + '; transform: scale(1.06)' : (E.hasAudio ? 'color: #56666E' : 'color: #DCE5E9'))) })); })(),
curTxt: E.summary || '',
curStyle: 'display: ' + (E.summary && (frac > 0.3 || !E.hasAudio) ? 'flex' : 'none') + '; align-items: flex-start; gap: 12px; border-radius: 20px; padding: 12px 14px; background: linear-gradient(140deg, #2E2410, #141E25 70%); border: 1px solid #FFD27A55; transform-origin: top; animation: ' + (cur % 2 ? 'au-flipA' : 'au-flipB') + ' .7s cubic-bezier(.2,.9,.3,1.2) both',
routeDone: 'stroke-dashoffset: ' + (100 - done * 100).toFixed(1) + '; transition: stroke-dashoffset .4s linear',
routeHead: N + (N === 1 ? ' parte' : ' partes') + ' · quedan ' + Math.max(1, Math.ceil(left / 60)) + ' min',
partsGrid: 'display: grid; grid-template-columns: repeat(' + Math.min(N, 6) + ', minmax(0, 1fr)); gap: 6px',
stops: PTS.map(([x, y], i) => ({ n: String(i + 1), aria: 'Ir a la parte ' + (i + 1), pick: () => this.goPart(i), lbl: i === 0 ? 'Inicio' : i === N - 1 ? 'Fin' : '',
  st: 'position: absolute; left: ' + (x / 350 * 100).toFixed(1) + '%; top: ' + y.toFixed(0) + 'px; transform: translate(-50%, -50%); width: 26px; height: 26px; border-radius: 13px; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; padding: 0; transition: all .3s; ' + (i < cur ? 'border: none; background: ' + accent + '; color: #0B1217' : i === cur ? 'border: 2px solid ' + accent + '; background: #0B1217; color: ' + accent + '; animation: au-stop 1.4s ease-out infinite' : 'border: 2px solid #33444E; background: #0B1217; color: #9FB0B8'),
  lblSt: 'position: absolute; left: ' + (x / 350 * 100).toFixed(1) + '%; top: ' + (y < 60 ? y + 16 : y - 32).toFixed(0) + 'px; transform: translateX(-50%); font-size: 10px; font-weight: 800; white-space: nowrap; pointer-events: none; color: ' + (i === cur ? '#F2F5F3' : '#6F8490') })),
walker: (() => { const a2 = PTS[cur], b2 = PTS[Math.min(N - 1, cur + 1)]; const t = cur === N - 1 ? 0 : frac; const x = a2[0] + (b2[0] - a2[0]) * t, y = a2[1] + (b2[1] - a2[1]) * t - 22; return 'position: absolute; left: ' + (x / 350 * 100).toFixed(1) + '%; top: ' + y.toFixed(0) + 'px; width: 34px; height: 34px; border-radius: 17px; border: 2px solid ' + accent + '; background: #0B1217; overflow: hidden; display: flex; align-items: center; justify-content: center; pointer-events: none; box-shadow: 0 6px 14px rgba(0,0,0,.5); transition: left .25s linear, top .25s linear; ' + (playingNow ? 'animation: au-walk .6s ease-in-out infinite' : 'transform: translate(-50%, -50%)'); })(), durS: String(Math.round(dur)), posS: String(Math.round(shown)),
headLine: 'position: absolute; top: 2px; bottom: 2px; left: calc(' + (frac * 100).toFixed(2) + '% - 1px); width: 2px; border-radius: 1px; background: #F2F5F3; pointer-events: none; transition: left ' + (scrub ? '0s' : '0.25s linear'),
headDot: 'position: absolute; top: 50%; left: ' + (frac * 100).toFixed(2) + '%; width: ' + (scrub ? 22 : 16) + 'px; height: ' + (scrub ? 22 : 16) + 'px; margin: -' + (scrub ? 11 : 8) + 'px 0 0 -' + (scrub ? 11 : 8) + 'px; border-radius: 50%; background: ' + accent + '; border: 3px solid #0B1217; box-sizing: border-box; pointer-events: none; transition: left ' + (scrub ? '0s' : '0.25s linear') + ', width .2s, height .2s, margin .2s; animation: au-dot 1.6s ease-in-out infinite',
seekTip: 'position: absolute; bottom: 100%; left: ' + (frac * 100).toFixed(2) + '%; transform: translate(-50%, -4px); height: 24px; padding: 0 9px; border-radius: 12px; background: #F2F5F3; color: #0B1217; font-size: 12px; font-weight: 800; display: flex; align-items: center; white-space: nowrap; pointer-events: none; transition: opacity .2s; opacity: ' + (scrub ? '1' : '0'),
seekTipTxt: fmt(shown) + ' / ' + fmt(dur),
wDown: (e) => { if (!E.hasAudio) return; const r = e.currentTarget.getBoundingClientRect(); this.wDrag = { r }; try { e.currentTarget.setPointerCapture(e.pointerId); } catch (err) {} const f2 = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)); this.setState({ pos: clampTo(f2 * dur) }); try { if (navigator.vibrate) navigator.vibrate(8); } catch (er) {} },
wMove: (e) => { if (!this.wDrag) return; const r = this.wDrag.r; const f2 = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)); this.setState({ pos: clampTo(f2 * dur) }); },
wUp: () => { if (!this.wDrag) return; this.wDrag = null; this.seekTo(this.state.pos); },
seeking: seek !== null && Math.abs(seek) >= 1,
hintOpacity: seek !== null && Math.abs(seek) >= 1 ? '0' : (E.hasAudio ? '1' : '0'),
seekLabel: (seek > 0 ? '+' : '−') + Math.abs(Math.round(seek || 0)) + ' s · ' + fmt(shown),
ringStyle: 'position: absolute; inset: 0; transition: transform ' + (seek === null ? '0.5s ease' : '0s') + '; transform: rotate(' + ((seek || 0) * 6) + 'deg)',
knobStyle: 'width: 82px; height: 82px; border: none; border-radius: 41px; background: ' + accent + '; display: flex; align-items: center; justify-content: center; cursor: grab; touch-action: none; user-select: none; box-shadow: 0 0 0 ' + (seek === null ? '0' : '8') + 'px rgba(61,220,151,0.18); transition: box-shadow 0.2s' + (E.hasAudio ? '' : '; opacity: .45'),
down: (e) => { this.drag = { x: e.clientX, moved: false }; try { e.currentTarget.setPointerCapture(e.pointerId); } catch (err) { /* nada */ } },
move: (e) => { if (!this.drag) return; const dx = e.clientX - this.drag.x; if (Math.abs(dx) > 6) this.drag.moved = true; if (this.drag.moved) this.setState({ seek: dx / 3 }); },
up: () => { if (!this.drag) return; const moved = this.drag.moved; this.drag = null; if (moved) { this.skipClick = true; this.setState({ seek: null }); this.seekTo(shown); } else this.setState({ seek: null }); },
key: (e) => { if (e.key === 'ArrowLeft') this.seekTo(this.state.pos - 10); if (e.key === 'ArrowRight') this.seekTo(this.state.pos + 10); },
back10: () => this.seekTo(this.state.pos - 10),
playing: this.state.playing,
paused: !this.state.playing,
playLabel: this.state.playing ? 'Pausar' : 'Reproducir',
toggle: () => { if (this.skipClick) { this.skipClick = false; return; } if (!E.hasAudio) { toApp('toggle'); return; } this.setState({ playing: !this.state.playing }); toApp('toggle'); },
prev: () => { if (cur > 0) this.goPart(cur - 1); },
next: () => { if (cur < N - 1) this.goPart(cur + 1); }
};
}
}
