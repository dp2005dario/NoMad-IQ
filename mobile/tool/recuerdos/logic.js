// La maqueta "Recuerdos" con tus recuerdos de verdad. La app pone los datos
// en window.ECL (ver lib/features/memories/memories_page.dart) y manda lo
// nuevo con window.ECLin({...}). Lo que tocas se le dice a la app con
// toApp('...'): "style:<n>", "full" (pantalla completa), "open:<n>",
// "camera", "start", "back", y el vídeo hecho: "video:<para qué>:<tipo>:<datos>".
//
// El vídeo: la historia se dibuja en un lienzo (canvas) de 540 x 960, como
// una historia de Instagram, y el propio móvil lo graba (MediaRecorder).
// Si el móvil no sabe grabar, se avisa a la app con "novideo:<para qué>".
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { n: 0, slide: 0, playing: true, rec: null };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
this.next();
}
componentWillUnmount() { clearTimeout(this.timer); this.gone = true; }
count() { return (this.E.shots || []).length + 2; }
dur() { const d = this.E.durs || [3750, 3750, 1800]; return d[this.E.style || 0] || 3000; }
// Cada escena dura lo de su estilo; al acabar vuelve a empezar.
next() {
clearTimeout(this.timer);
this.timer = setTimeout(() => {
if (this.gone) return;
if (this.state.playing) this.setState({ slide: (this.state.slide + 1) % this.count() });
this.next();
}, this.dur());
}
// ---- El vídeo ----
record(mode) {
const E = this.E;
if (!(E.shots || []).length) { toApp('empty'); return; }
if (this.state.rec !== null) return;
const types = ['video/mp4;codecs=avc1', 'video/mp4', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
let mime = null;
try { if (window.MediaRecorder && MediaRecorder.isTypeSupported) mime = types.find((t) => MediaRecorder.isTypeSupported(t)) || null; } catch (e) { mime = null; }
const cv = document.createElement('canvas');
cv.width = 540; cv.height = 960;
if (!mime || !cv.captureStream) { toApp('novideo:' + mode); return; }
this.setState({ rec: 0 });
const shots = E.shots.slice();
Promise.all(shots.map((p) => new Promise((ok) => { const im = new Image(); im.onload = () => ok(im); im.onerror = () => ok(null); im.src = p.src; }))).then((imgs) => {
let rec;
try {
rec = new MediaRecorder(cv.captureStream(30), { mimeType: mime, videoBitsPerSecond: 2500000 });
} catch (e) { this.setState({ rec: null }); toApp('novideo:' + mode); return; }
const chunks = [];
rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
rec.onstop = () => {
const blob = new Blob(chunks, { type: mime.split(';')[0] });
const fr = new FileReader();
fr.onload = () => {
const d = String(fr.result);
toApp('video:' + mode + ':' + (mime.indexOf('mp4') >= 0 ? 'mp4' : 'webm') + ':' + d.slice(d.indexOf(',') + 1));
this.setState({ rec: null });
};
fr.readAsDataURL(blob);
};
const ctx = cv.getContext('2d');
const dur = this.dur();
const total = (shots.length + 2) * dur;
const t0 = performance.now();
let last = -1;
rec.start(500);
const step = () => {
if (this.gone) { try { rec.stop(); } catch (e) {} return; }
const t = performance.now() - t0;
this.paint(ctx, Math.min(t, total - 1), dur, shots, imgs);
const pct = Math.floor(t / total * 100);
if (pct !== last && pct < 100) { last = pct; this.setState({ rec: pct }); }
if (t >= total) { rec.stop(); return; }
requestAnimationFrame(step);
};
step();
});
}
// Dibuja el momento [t] (ms) de la historia en el lienzo.
paint(c, t, dur, shots, imgs) {
const E = this.E;
const W = 540, H = 960;
const n = shots.length + 2;
const k = Math.min(n - 1, Math.floor(t / dur));
const f = (t - k * dur) / dur;
const ease = (x) => x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2;
const font = (w, px, fam) => w + ' ' + px + 'px ' + (fam || "'Manrope', sans-serif");
const fit = (text, w, px, max, fam) => { let p = px; c.font = font(w, p, fam); while (p > 14 && c.measureText(text).width > max) { p -= 2; c.font = font(w, p, fam); } return p; };
const rr = (x, y, w, h, r) => { c.beginPath(); c.moveTo(x + r, y); c.arcTo(x + w, y, x + w, y + h, r); c.arcTo(x + w, y + h, x, y + h, r); c.arcTo(x, y + h, x, y, r); c.arcTo(x, y, x + w, y, r); c.closePath(); };
c.setTransform(1, 0, 0, 1, 0, 0);
c.globalAlpha = 1;
c.fillStyle = '#0F1A20'; c.fillRect(0, 0, W, H);
const ms = f * dur;
if (k === 0) {
// Portada: el globo, la ruta que se dibuja y el avión que la vuela.
const g = c.createRadialGradient(W / 2, H * 0.45, 0, W / 2, H * 0.45, H * 0.6);
g.addColorStop(0, '#1E3A5C'); g.addColorStop(1, '#070D16');
c.fillStyle = g; c.fillRect(0, 0, W, H);
const s = W / 358; const oy = (H - 470 * s) / 2 - 60;
c.setTransform(s, 0, 0, s, 0, oy);
c.beginPath(); c.arc(179, 250, 150, 0, Math.PI * 2); c.fillStyle = '#12304D'; c.fill(); c.lineWidth = 2; c.strokeStyle = '#2A5A86'; c.stroke();
c.fillStyle = '#2F6E58'; c.fill(new Path2D('M60 220 C 90 200, 120 210, 140 190 C 150 230, 120 260, 80 262 Z M200 140 C 250 130, 300 160, 310 200 C 280 220, 240 200, 210 190 Z M230 250 C 260 250, 300 280, 290 320 C 260 330, 240 300, 228 280 Z'));
const p = ease(Math.min(1, ms / 2200));
if (E.to) {
c.setLineDash([520]); c.lineDashOffset = 520 * (1 - p); c.lineWidth = 4; c.lineCap = 'round'; c.strokeStyle = '#FFB86B';
c.stroke(new Path2D('M90 230 C 150 110, 250 110, 300 210')); c.setLineDash([]);
}
c.fillStyle = '#F2F5F3'; c.beginPath(); c.arc(90, 230, 7, 0, Math.PI * 2); c.fill();
if (E.to) {
c.fillStyle = '#FFB86B'; c.beginPath(); c.arc(300, 210, 7, 0, Math.PI * 2); c.fill();
// El avión: un punto de la curva y hacia dónde mira.
const B = (a, b, cc, d, u) => (1 - u) ** 3 * a + 3 * (1 - u) ** 2 * u * b + 3 * (1 - u) * u * u * cc + u ** 3 * d;
const x = B(90, 150, 250, 300, p), y = B(230, 110, 110, 210, p);
const x2 = B(90, 150, 250, 300, Math.min(1, p + 0.01)), y2 = B(230, 110, 110, 210, Math.min(1, p + 0.01));
c.save(); c.translate(x, y); c.rotate(Math.atan2(y2 - y, x2 - x) || 0.4);
c.fillStyle = '#FFFFFF'; c.fill(new Path2D('M-10 -3 L6 -3 L12 0 L6 3 L-10 3 L-6 0 Z M-2 -3 L-6 -11 L-1 -11 L4 -3 Z M-2 3 L-6 11 L-1 11 L4 3 Z'));
c.restore();
}
c.font = font('800', 14); c.fillStyle = '#F2F5F3'; c.textAlign = 'left'; c.fillText(E.from || '', 70, 258);
c.fillStyle = '#FFB86B'; c.textAlign = 'right'; c.fillText(E.to || '', 318, 238); c.textAlign = 'left';
c.setTransform(1, 0, 0, 1, 0, 0);
const up = Math.min(1, Math.max(0, (ms - 400) / 600));
c.globalAlpha = up;
c.fillStyle = '#FFB86B'; c.font = font('800', 18); c.fillText(E.dates || '', 30, H - 150 + (1 - up) * 30);
c.fillStyle = '#F2F5F3'; fit(E.route || '', '800', 56, W - 60, "'Bricolage Grotesque', sans-serif"); c.fillText(E.route || '', 30, H - 90 + (1 - up) * 30);
c.globalAlpha = 1;
} else if (k <= shots.length) {
// Una foto: zoom lento y su "DÍA N · CIUDAD".
const sh = shots[k - 1]; const im = imgs[k - 1];
const comic = (E.style || 0) === 1;
const box = comic ? { x: 30, y: 110, w: W - 60, h: H - 290 } : { x: 0, y: 0, w: W, h: H };
if (comic) { c.fillStyle = '#0B1217'; c.fillRect(0, 0, W, H); c.fillStyle = '#FFFFFF'; c.fillRect(box.x - 9, box.y - 9, box.w + 18, box.h + 18); }
if (im) {
const z = comic ? 1 : 1 + 0.12 * ease(f);
const sc = Math.max(box.w / im.width, box.h / im.height) * z;
const iw = im.width * sc, ih = im.height * sc;
c.save(); c.beginPath(); c.rect(box.x, box.y, box.w, box.h); c.clip();
c.drawImage(im, box.x + (box.w - iw) / 2 - (comic ? 0 : 8 * f), box.y + (box.h - ih) / 2 - (comic ? 0 : 6 * f), iw, ih);
c.restore();
}
const up = Math.min(1, ms / 600);
c.globalAlpha = up;
c.font = font('800', 16); const w1 = c.measureText(sh.lbl || '').width;
c.font = font('800', 24); const w2 = Math.min(W - 80, c.measureText(sh.sub || '').width);
const bw = Math.max(w1, w2) + 36, by = H - 170 + (1 - up) * 30;
if (comic) { c.fillStyle = '#FFE066'; c.fillRect(30, by, bw, 92); } else { c.fillStyle = 'rgba(11,18,23,0.75)'; rr(27, by, bw, 92, 20); c.fill(); }
c.fillStyle = comic ? '#0B1217' : (sh.color || '#F4A7BF'); c.font = font('800', 16); c.fillText(sh.lbl || '', 45, by + 34);
c.fillStyle = comic ? '#0B1217' : '#F2F5F3'; c.font = font('800', 24); c.fillText(sh.sub || '', 45, by + 70, W - 80);
c.globalAlpha = 1;
} else {
// Las cifras del viaje.
const g = c.createLinearGradient(0, 0, W, H);
g.addColorStop(0, '#1A3A2D'); g.addColorStop(1, '#0B1217');
c.fillStyle = g; c.fillRect(0, 0, W, H);
const st = E.stats || [];
const cw = (W - 27 * 2 - 15) / 2, ch = 170;
const top = (H - (ch * 2 + 15)) / 2;
st.forEach((s, i) => {
const up = Math.min(1, Math.max(0, (ms - 150 * i) / 500));
c.globalAlpha = up;
const x = 27 + (i % 2) * (cw + 15), y = top + Math.floor(i / 2) * (ch + 15) + (1 - up) * 36;
c.fillStyle = 'rgba(255,255,255,0.06)'; rr(x, y, cw, ch, 30); c.fill();
c.strokeStyle = 'rgba(61,220,151,0.25)'; c.lineWidth = 1.5; c.stroke();
c.fillStyle = '#F2F5F3'; fit(String(s.v), '800', 57, cw - 40, "'Bricolage Grotesque', sans-serif"); c.fillText(String(s.v), x + 21, y + 84);
c.fillStyle = '#CFE9DE'; c.font = font('700', 19); c.fillText(s.k || '', x + 21, y + 126, cw - 40);
});
c.globalAlpha = 1;
}
// Las rayitas de arriba.
const gw = (W - 36 - 6 * (n - 1)) / n;
for (let i = 0; i < n; i++) {
const x = 18 + i * (gw + 6);
c.fillStyle = 'rgba(255,255,255,0.3)'; rr(x, 18, gw, 6, 3); c.fill();
const fill = i < k ? 1 : i === k ? f : 0;
if (fill > 0) { c.fillStyle = '#FFFFFF'; rr(x, 18, Math.max(6, gw * fill), 6, 3); c.fill(); }
}
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const E = this.E;
const st = this.state;
const n = this.count();
const slide = st.slide % n;
const sec = (this.dur() / 1000) + 's';
const show = (i) => 'position: absolute; inset: 0; transition: opacity 0.6s ease, transform 0.6s ease; opacity: ' + (slide === i ? 1 : 0) + '; transform: scale(' + (slide === i ? 1 : 1.04) + ')';
const segs = Array.from({ length: n }, (_, i) => ({ style: 'display: block; height: 4px; background: #FFFFFF; ' + (i < slide ? 'width: 100%' : i === slide ? (st.playing ? 'animation: nq-fill ' + sec + ' linear both' : 'width: 50%') : 'width: 0') }));
const comic = (E.style || 0) === 1;
const shots = (E.shots || []).map((p, i) => {
const on = slide === i + 1;
return {
src: p.src, lbl: p.lbl, sub: p.sub,
show: show(i + 1) + (comic ? '; background: #0B1217' : ''),
frame: comic ? 'position: absolute; left: 20px; right: 20px; top: 46px; bottom: 96px; border: 6px solid #FFFFFF; overflow: hidden' : 'position: absolute; inset: 0; overflow: hidden',
img: 'width: 100%; height: 100%; object-fit: cover; display: block; ' + (on && !comic ? 'animation: nq-kb ' + sec + ' ease-out both' : ''),
capBox: comic
? 'position: absolute; left: 20px; bottom: 30px; max-width: 300px; background: #FFE066; padding: 8px 12px; display: flex; flex-direction: column; gap: 1px; ' + (on ? 'animation: nq-up 0.6s ease 0.3s both' : '')
: 'position: absolute; left: 18px; bottom: 22px; max-width: 300px; border-radius: 14px; background: rgba(11,18,23,0.75); padding: 8px 12px; display: flex; flex-direction: column; gap: 1px; ' + (on ? 'animation: nq-up 0.6s ease 0.3s both' : ''),
lblSt: 'font-size: 11px; font-weight: 800; letter-spacing: 0.06em; color: ' + (comic ? '#0B1217' : p.color),
subSt: 'font-size: 16px; font-weight: 800' + (comic ? '; color: #0B1217' : '')
};
});
const stats = (E.stats || []).map((s, i) => ({ v: s.v, k: s.k, style: 'border-radius: 20px; background: rgba(255,255,255,0.06); border: 1px solid rgba(61,220,151,0.25); padding: 16px 14px; display: flex; flex-direction: column; gap: 6px; ' + (slide === n - 1 ? 'animation: nq-up 0.5s ease ' + (0.15 * i) + 's both' : '') }));
const Y = E.styles || ['', '', ''];
const styles = Y.map((label, i) => ({ label, on: (E.style || 0) === i, pick: () => { E.style = i; toApp('style:' + i); this.setState({ slide: 0 }); this.next(); }, style: 'flex: 1; height: 40px; border-radius: 14px; font-family: inherit; font-size: 13px; font-weight: 800; cursor: pointer; ' + ((E.style || 0) === i ? 'border: none; background: ' + accent + '; color: #0B1217' : 'border: 1px solid #26363F; background: #141E25; color: #F2F5F3') }));
const names = E.names || [];
const making = st.rec !== null;
const grid = (E.grid || []).map((m, i) => ({
video: !!m.video, label: m.label,
open: () => toApp('open:' + i),
style: 'aspect-ratio: 1; border-radius: 14px; border: 1px solid #26363F; padding: 0; cursor: pointer; display: flex; align-items: center; justify-content: center; background: ' + (m.thumb ? 'url(' + m.thumb + ') center / cover no-repeat, #141E25' : '#141E25')
}));
return {
accent, segs, stats, styles, shots,
back: () => toApp('back'), backTxt: E.backTxt || '',
title: E.title || '', sub: E.sub || '',
from: E.from || '', to: E.to || '', dates: E.dates || '', route: E.route || '',
drawSt: slide === 0 ? 'animation: nq-draw 2.2s ease both' : '',
flySt: slide === 0 && E.to ? 'animation: nq-fly 2.2s ease both' : 'opacity: 0',
upSt: slide === 0 ? 'animation: nq-up 0.6s ease 0.4s both' : '',
s0: show(0), s3: show(n - 1),
slideAria: (E.sceneTxt || '') + ' ' + (slide + 1) + '/' + n + ': ' + (names[slide] || ''),
full: () => toApp('full'),
playLabel: st.playing ? (E.pauseTxt || '') : (E.playTxt || ''),
playIcon: st.playing ? 'M6 5h4v14H6zM14 5h4v14h-4z' : 'M8 5v14l11-7z',
toggle: (e) => { if (e && e.stopPropagation) e.stopPropagation(); this.setState({ playing: !st.playing }); },
stylesTxt: E.stylesTxt || '',
story: () => this.record('share'),
storyTxt: making ? (E.makingTxt || '') + ' ' + st.rec + ' %' : (E.storyTxt || ''),
storySub: E.storySub || '',
save: () => this.record('save'), saveTxt: E.saveTxt || '',
group: () => this.record('group'), groupTxt: E.groupTxt || '',
listH: E.listH || '', onlyHere: E.onlyHere || '',
camera: () => toApp('camera'), cameraTxt: E.cameraTxt || '',
start: () => toApp('start'), startTxt: E.startTxt || '',
empty: !(E.grid || []).length, emptyTxt: E.emptyTxt || '',
grid
};
}
}
