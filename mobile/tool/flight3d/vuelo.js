import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

/* ---------- datos del vuelo (los pone la app en window.NQ_FLIGHT) ----------
   Sin datos (por ejemplo, al abrir el archivo en un navegador para probarlo)
   se usa la ruta de la maqueta: Madrid → Tokio, en español. */
const DEMO = {
  lang: 'es',
  from: { code: 'MAD', city: 'Madrid', cc: 'ES' },
  to: { code: 'HND', city: 'Tokio', cc: 'JP' },
  km: 10800,
  monuments: ['alcala', 'eiffel', 'bigben', 'coliseo', 'brandeburgo', 'piramides', 'basilio', 'taj', 'muralla', 'fuji', 'tokio'],
  texts: {},
  t: {}
};
const NQ = Object.assign({}, DEMO, window.NQ_FLIGHT || {});
// Textos: los de la app; si falta alguno, el español de la maqueta.
const T = Object.assign({
  loading: 'Preparando el vuelo 3D…', noWebgl: 'Este móvil no puede mostrar gráficos 3D (WebGL).',
  sceneLabel: 'Animación 3D del vuelo', overflying: 'Sobrevolando', landingIn: 'Aterrizando en', arrivedIn: 'Ya en',
  kmOf: '{km} de {total} km', day: 'De día', dusk: 'Atardecer', nightfall: 'Anochece', night: 'De noche', dawn: 'Amanece',
  camFront: 'Frente', camSide: 'Lateral', camBehind: 'Detrás', camTop: 'Arriba', camCine: 'Cine', speed: 'Velocidad',
  pause: 'Pausa', resume: 'Seguir', land: 'Aterrizar', theme: 'Tema: {name}', themeNormal: 'Normal', themeHalloween: 'Halloween',
  themeXmas: 'Navidad', happyHalloween: '¡Feliz Halloween!', merryXmas: '¡Feliz Navidad!', controls: 'Cámara y reproducción',
  welcome: '¡Bienvenido a {city}!', boardingPass: 'Tarjeta de embarque', passenger: 'Pasajero', flight: 'Vuelo', seat: 'Asiento', landed: 'Aterrizaje en {to} tras {km} km desde {from}.', again: 'Repetir vuelo', done: 'Continuar'
}, NQ.t || {});
const fmt = (s, v) => s.replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
const num = (n) => { try { return Math.round(n).toLocaleString(NQ.lang); } catch (e) { return String(Math.round(n)); } };
// Bandera: dos "letras regionales" (ES → 🇪🇸). Sin imágenes que descargar.
const flagOf = (cc) => /^[A-Z]{2}$/.test(cc || '') ? String.fromCodePoint(...[...cc].map((c) => 0x1F1A5 + c.charCodeAt(0))) : '🏳️';
const FLAG = (cc) => `<span class="flag">${flagOf(cc)}</span>`;
// El país en el idioma del usuario (lo sabe el propio navegador del móvil).
let regionNames = null;
try { regionNames = new Intl.DisplayNames([NQ.lang, 'en'], { type: 'region' }); } catch (e) { regionNames = null; }
const countryName = (cc) => { try { return (regionNames && regionNames.of(cc)) || cc; } catch (e) { return cc; } };
// Avisos a la app (aterrizado, cerrar): por el canal "NomadIQ" si existe.
const tellApp = (msg) => { try { if (window.NomadIQ) window.NomadIQ.postMessage(msg); } catch (e) { /* en un navegador normal, nada */ } };
const esc = (x) => String(x).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ---------- renderer, scene, camera ---------- */
const canvas = document.getElementById('scene');
let renderer;
try {
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
} catch (e) {
  document.getElementById('loading').textContent = T.noWebgl;
  throw e;
}
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(50, 1, 0.1, 4000);
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

/* seeded random so the world is the same every visit */
let seed = 20261022;
const rand = () => { seed |= 0; seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const pick = (a) => a[Math.floor(rand() * a.length)];
const v3 = (x, y, z) => new THREE.Vector3(x, y, z);

/* every lit material we create, so day/night can dim reflections and switch floodlights */
const litMaterials = [];
function std(color, roughness = 0.7, metalness = 0, extra = {}) {
  const m = new THREE.MeshStandardMaterial({ color, roughness, metalness, ...extra });
  m.userData.env = extra.envMapIntensity ?? 0.5;
  litMaterials.push(m);
  return m;
}
const monumentMaterials = [];
function mstd(color, roughness = 0.7, metalness = 0, extra = {}) {
  const m = std(color, roughness, metalness, extra);
  m.userData.flood = new THREE.Color(color).multiplyScalar(0.22);
  monumentMaterials.push(m);
  return m;
}
function canvasTex(w, h, draw, opts = {}) {
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  draw(c.getContext('2d'), w, h);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = opts.data ? THREE.NoColorSpace : THREE.SRGBColorSpace;
  t.anisotropy = renderer.capabilities.getMaxAnisotropy();
  if (opts.repeat) { t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(opts.repeat[0], opts.repeat[1]); }
  return t;
}

/* ---------- the Earth ---------- */
const R = 600;          // planet radius (scene units)
const ALT = 9;          // plane altitude above the ground
const earth = new THREE.Group();
earth.position.set(0, -R, 0);
scene.add(earth);

/* the ground texture comes in three palettes: normal fields, autumn (Halloween) and snow (Navidad) */
const mkRand = (sd) => () => { sd |= 0; sd = (sd + 0x6D2B79F5) | 0; let t = Math.imul(sd ^ (sd >>> 15), 1 | sd); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const TERRAIN = {
  normal: { base: '#5E7F3D', fields: ['#6B8F45', '#7D9A4C', '#8FA859', '#5D7D3A', '#A3A85E', '#B9A866', '#C8B273', '#6F8A3F', '#55733A', '#94A05A'], forest: '58,92,44', lake: '#2F5F86', road: 'rgba(205,195,170,0.55)' },
  halloween: { base: '#8A6F38', fields: ['#B9873F', '#C99A4A', '#A8763A', '#8E8A44', '#C4A15A', '#D2B06A', '#9C6B35', '#7F8A40', '#B07A3C', '#C8A866'], forest: '150,72,30', lake: '#2F5F86', road: 'rgba(230,210,175,0.55)' },
  navidad: { base: '#E4EAF0', fields: ['#F4F7FA', '#E2E8EE', '#D7DFE7', '#EEF2F6', '#FFFFFF', '#DCE4EA', '#CFD9E2'], forest: '110,135,150', lake: '#A9CBE0', road: 'rgba(150,140,130,0.45)' }
};
function makeTerrain(pal, rnd) {
  const pk = (a) => a[Math.floor(rnd() * a.length)];
  return canvasTex(1024, 1024, (g, W, H) => {
    g.fillStyle = pal.base; g.fillRect(0, 0, W, H);
    const wrapDraw = (fn) => { for (const dx of [-W, 0, W]) for (const dy of [-H, 0, H]) { g.save(); g.translate(dx, dy); fn(); g.restore(); } };
    for (let i = 0; i < 1100; i++) {
      const x = rnd() * W, y = rnd() * H, w = 18 + rnd() * 70, h = 12 + rnd() * 46, a = (rnd() < 0.5 ? 0 : Math.PI / 2) + (rnd() - 0.5) * 0.5, col = pk(pal.fields);
      wrapDraw(() => { g.save(); g.translate(x, y); g.rotate(a); g.fillStyle = col; g.fillRect(-w / 2, -h / 2, w, h); g.restore(); });
    }
    for (let i = 0; i < 90; i++) {
      const x = rnd() * W, y = rnd() * H, r = 8 + rnd() * 22;
      wrapDraw(() => { const gr = g.createRadialGradient(x, y, 0, x, y, r); gr.addColorStop(0, `rgba(${pal.forest},0.55)`); gr.addColorStop(0.7, `rgba(${pal.forest},0.3)`); gr.addColorStop(1, `rgba(${pal.forest},0)`); g.fillStyle = gr; g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill(); });
    }
    for (let i = 0; i < 9; i++) {
      const x = rnd() * W, y = rnd() * H, r = 14 + rnd() * 26;
      wrapDraw(() => { g.fillStyle = pal.lake; g.beginPath(); g.ellipse(x, y, r, r * 0.6, rnd() * 3, 0, Math.PI * 2); g.fill(); g.strokeStyle = 'rgba(200,220,200,0.4)'; g.lineWidth = 2; g.stroke(); });
    }
    g.strokeStyle = pal.road; g.lineWidth = 2.2;
    for (let i = 0; i < 14; i++) {
      const x = rnd() * W, y = rnd() * H, a = rnd() * Math.PI, l = 300 + rnd() * 500;
      wrapDraw(() => { g.beginPath(); g.moveTo(x, y); g.quadraticCurveTo(x + Math.cos(a) * l * 0.5 + 60, y + Math.sin(a) * l * 0.5 - 40, x + Math.cos(a) * l, y + Math.sin(a) * l); g.stroke(); });
    }
  }, { repeat: [32, 16] });
}
const terrainTex = makeTerrain(TERRAIN.normal, rand);
const earthGeo = new THREE.SphereGeometry(R, 512, 256);
earthGeo.rotateZ(Math.PI / 2); // put the sphere's poles on the X axis so the flight path runs along its equator
const earthMat = std('#FFFFFF', 0.95, 0, { map: terrainTex, envMapIntensity: 0.12 });
const earthMesh = new THREE.Mesh(earthGeo, earthMat);
earthMesh.receiveShadow = true;
earth.add(earthMesh);

/* place things on the curved surface: phi = angle along the route, x = sideways offset */
function surfacePoint(phi, x, lift = 0) {
  const r = Math.sqrt(R * R - x * x) + lift;
  return v3(x, r * Math.cos(phi), r * Math.sin(phi));
}
function place(obj, phi, x, yaw = 0, lift = 0) {
  obj.position.copy(surfacePoint(phi, x, lift));
  obj.rotation.set(phi, yaw, 0);
  earth.add(obj);
  return obj;
}
const dummy = new THREE.Object3D();
function instanceAt(mesh, i, phi, x, lift, scale, yaw = 0) {
  dummy.position.copy(surfacePoint(phi, x, lift));
  dummy.rotation.set(phi, yaw, 0);
  dummy.scale.setScalar(scale);
  dummy.updateMatrix();
  mesh.setMatrixAt(i, dummy.matrix);
}
/* bend a flat piece of ground so it follows the planet's curve */
function conform(geo) {
  const p = geo.attributes.position;
  for (let i = 0; i < p.count; i++) p.setY(i, p.getY(i) - (p.getX(i) ** 2 + p.getZ(i) ** 2) / (2 * R));
  geo.computeVertexNormals();
  return geo;
}

/* ---------- monuments ---------- */
const latticeTex = canvasTex(128, 128, (g, W, H) => {
  g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
  g.strokeStyle = '#FFF'; g.lineWidth = 11; g.strokeRect(0, 0, W, H);
  g.lineWidth = 7; g.beginPath(); g.moveTo(0, 0); g.lineTo(W, H); g.moveTo(W, 0); g.lineTo(0, H); g.stroke();
}, { data: true });
function latticeMat(color, rx, ry) {
  const t = latticeTex.clone(); t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(rx, ry); t.needsUpdate = true;
  return mstd(color, 0.55, 0.55, { alphaMap: t, alphaTest: 0.5, side: THREE.DoubleSide });
}
function beam(a, b, rBottom, rTop, mat) {
  const dir = new THREE.Vector3().subVectors(b, a); const len = dir.length();
  const geo = new THREE.CylinderGeometry(rTop, rBottom, len, 4, 1, true); geo.rotateY(Math.PI / 4);
  const m = new THREE.Mesh(geo, mat);
  m.position.copy(a).addScaledVector(dir, 0.5);
  m.quaternion.setFromUnitVectors(v3(0, 1, 0), dir.normalize());
  return m;
}
const box = (w, h, d, mat, x = 0, y = 0, z = 0) => { const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat); m.position.set(x, y, z); return m; };
const cyl = (rt, rb, h, seg, mat, x = 0, y = 0, z = 0, open = false) => { const m = new THREE.Mesh(new THREE.CylinderGeometry(rt, rb, h, seg, 1, open), mat); m.position.set(x, y, z); return m; };
function shadowAll(g) { g.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } }); return g; }
function onionGeo(scale) {
  const pts = [[0, 0], [1, 0], [1.25, 0.45], [1.22, 1.0], [0.95, 1.5], [0.5, 1.95], [0.18, 2.35], [0.06, 2.7], [0, 2.8]].map(([r, y]) => new THREE.Vector2(r * scale, y * scale));
  return new THREE.LatheGeometry(pts, 32);
}
function stripeTex(a, b) {
  return canvasTex(256, 256, (g, W, H) => {
    g.fillStyle = a; g.fillRect(0, 0, W, H); g.fillStyle = b;
    for (let i = -W; i < W * 2; i += 64) { g.beginPath(); g.moveTo(i, H); g.lineTo(i + 32, H); g.lineTo(i + 32 + 120, 0); g.lineTo(i + 120, 0); g.fill(); }
  }, { repeat: [2, 1] });
}

function puertaAlcala() {
  const g = new THREE.Group();
  const granite = mstd('#DDD0B6', 0.85);
  const s = new THREE.Shape(); s.moveTo(-7, 0); s.lineTo(7, 0); s.lineTo(7, 7); s.lineTo(-7, 7); s.closePath();
  const arch = (cx, w, h) => { const p = new THREE.Path(); p.moveTo(cx - w / 2, 0.01); p.lineTo(cx + w / 2, 0.01); p.lineTo(cx + w / 2, h - w / 2); p.absarc(cx, h - w / 2, w / 2, 0, Math.PI, false); p.lineTo(cx - w / 2, 0.01); return p; };
  const rect = (cx, w, h) => { const p = new THREE.Path(); p.moveTo(cx - w / 2, 0.01); p.lineTo(cx + w / 2, 0.01); p.lineTo(cx + w / 2, h); p.lineTo(cx - w / 2, h); p.lineTo(cx - w / 2, 0.01); return p; };
  s.holes.push(arch(-3.2, 1.9, 4.6), arch(0, 2.2, 5.2), arch(3.2, 1.9, 4.6), rect(-5.6, 1.1, 3.2), rect(5.6, 1.1, 3.2));
  const body = new THREE.Mesh(new THREE.ExtrudeGeometry(s, { depth: 2.4, bevelEnabled: true, bevelSize: 0.06, bevelThickness: 0.06, bevelSegments: 1 }), granite);
  body.position.z = -1.2; g.add(body);
  for (const x of [-4.6, -1.65, 1.65, 4.6]) for (const z of [1.35, -1.35]) g.add(cyl(0.28, 0.3, 5.6, 16, granite, x, 3.0, z));
  g.add(box(14.4, 0.6, 2.9, granite, 0, 7.3, 0));
  g.add(box(6.2, 1.5, 2.4, granite, 0, 8.35, 0));
  const ped = new THREE.Shape(); ped.moveTo(-3.4, 0); ped.lineTo(3.4, 0); ped.lineTo(0, 1.5); ped.closePath();
  const pm = new THREE.Mesh(new THREE.ExtrudeGeometry(ped, { depth: 2.2, bevelEnabled: false }), granite); pm.position.set(0, 9.1, -1.1); g.add(pm);
  const bronze = mstd('#6E6656', 0.5, 0.6);
  for (const x of [-6.2, -2.5, 2.5, 6.2]) { g.add(cyl(0.35, 0.45, 0.9, 10, bronze, x, 8.05, 0)); g.add(new THREE.Mesh(new THREE.SphereGeometry(0.36, 12, 8), bronze).translateX(x).translateY(8.7)); }
  return shadowAll(g);
}

function eiffelLike(colorMain, tokyo = false) {
  const g = new THREE.Group();
  const lat = latticeMat(colorMain, 3, 6);
  const latUp = latticeMat(colorMain, 4, 16);
  const solid = mstd(colorMain, 0.55, 0.5);
  const white = mstd('#F4F4F2', 0.5, 0.3);
  for (const [sx, sz] of [[1, 1], [1, -1], [-1, 1], [-1, -1]]) {
    g.add(beam(v3(sx * 5, 0, sz * 5), v3(sx * 2.7, 6.3, sz * 2.7), 1.15, 0.75, lat));
    g.add(beam(v3(sx * 2.55, 6.6, sz * 2.55), v3(sx * 1.35, 11.6, sz * 1.35), 0.68, 0.48, lat));
  }
  for (let i = 0; i < 4; i++) {
    const a = new THREE.Mesh(new THREE.TorusGeometry(3.85, 0.2, 6, 28, Math.PI), solid);
    const ang = (i * Math.PI) / 2; a.rotation.y = ang; a.position.set(Math.sin(ang) * 4.1, 1.2, Math.cos(ang) * 4.1); a.scale.y = 0.82; g.add(a);
  }
  g.add(box(7.4, 0.7, 7.4, tokyo ? white : solid, 0, 6.45, 0));
  g.add(box(3.7, 0.45, 3.7, solid, 0, 11.75, 0));
  const up = new THREE.Mesh(new THREE.CylinderGeometry(0.34, 1.55, 11.6, 4, 1, true), latUp); up.rotation.y = Math.PI / 4; up.position.y = 17.75; g.add(up);
  if (tokyo) {
    g.add(box(4.6, 1.5, 4.6, white, 0, 12.6, 0));
    g.add(box(2.2, 1.0, 2.2, white, 0, 19.0, 0));
    for (const y of [3.4, 9.0, 15.0, 21.4]) { const b = new THREE.Mesh(new THREE.CylinderGeometry(1.6 - y * 0.06, 1.65 - y * 0.06, 0.7, 4, 1, true), white); b.rotation.y = Math.PI / 4; b.position.y = y; b.scale.setScalar(y < 6 ? 2.6 : y < 12 ? 1.25 : 1); g.add(b); }
  }
  g.add(box(0.9, 1.2, 0.9, solid, 0, 24.0, 0));
  g.add(cyl(0.06, 0.1, 2.4, 6, tokyo ? white : solid, 0, 25.8, 0));
  if (!tokyo) {
    const lawn = new THREE.Mesh(conform(new THREE.PlaneGeometry(9, 16).rotateX(-Math.PI / 2).translate(0, 0.05, 15)), mstd('#5F9A45', 0.95)); g.add(lawn);
    const sp = [];
    for (let i = 0; i < 90; i++) {
      const y = 0.8 + rand() * 23, w = y < 6.3 ? 5 - 2.3 * y / 6.3 : y < 11.6 ? 2.6 - 1.25 * (y - 6.6) / 5 : 1.55 - 1.2 * (y - 11.8) / 11.6;
      const side = Math.floor(rand() * 4), t = (rand() * 2 - 1) * w;
      sp.push(side < 2 ? t : (side === 2 ? w : -w), y, side < 2 ? (side === 0 ? w : -w) : t);
    }
    const sg = new THREE.BufferGeometry(); sg.setAttribute('position', new THREE.Float32BufferAttribute(sp, 3));
    const sparkle = new THREE.Points(sg, new THREE.PointsMaterial({ color: new THREE.Color(4, 4, 3.6), size: 0.35, transparent: true, opacity: 0, depthWrite: false }));
    g.add(sparkle); g.userData.sparkle = sparkle;
  }
  return shadowAll(g);
}

function bigBen() {
  const g = new THREE.Group();
  const grooves = canvasTex(256, 512, (c, W, H) => { c.fillStyle = '#D2BA82'; c.fillRect(0, 0, W, H); c.fillStyle = 'rgba(90,70,40,0.35)'; for (let x = 10; x < W; x += 42) c.fillRect(x, 0, 6, H); c.fillStyle = 'rgba(60,50,40,0.55)'; for (let y = 30; y < H; y += 70) for (let x = 20; x < W; x += 42) c.fillRect(x, y, 16, 30); });
  const stone = mstd('#FFFFFF', 0.8, 0, { map: grooves });
  const plain = mstd('#CDB57E', 0.8);
  const slate = mstd('#33414C', 0.6, 0.3);
  const gold = mstd('#D4A93C', 0.35, 0.8);
  g.add(box(2.8, 11, 2.8, stone, 0, 5.5, 0));
  g.add(box(3.3, 3.4, 3.3, plain, 0, 12.7, 0));
  const face = canvasTex(256, 256, (c, W) => {
    c.fillStyle = '#F2EBD6'; c.beginPath(); c.arc(W / 2, W / 2, W / 2 - 4, 0, Math.PI * 2); c.fill();
    c.strokeStyle = '#1D1D1D'; c.lineWidth = 8; c.stroke();
    for (let i = 0; i < 12; i++) { const a = (i / 12) * Math.PI * 2; c.lineWidth = 6; c.beginPath(); c.moveTo(W / 2 + Math.sin(a) * 98, W / 2 - Math.cos(a) * 98); c.lineTo(W / 2 + Math.sin(a) * 116, W / 2 - Math.cos(a) * 116); c.stroke(); }
    c.lineWidth = 9; c.beginPath(); c.moveTo(W / 2, W / 2); c.lineTo(W / 2 + 40, W / 2 - 40); c.stroke();
    c.lineWidth = 6; c.beginPath(); c.moveTo(W / 2, W / 2); c.lineTo(W / 2 - 10, W / 2 - 92); c.stroke();
  });
  const faceMat = mstd('#FFFFFF', 0.4, 0, { map: face });
  for (let i = 0; i < 4; i++) { const f = new THREE.Mesh(new THREE.CircleGeometry(1.25, 40), faceMat); const a = (i * Math.PI) / 2; f.rotation.y = a; f.position.set(Math.sin(a) * 1.66, 12.7, Math.cos(a) * 1.66); g.add(f); }
  g.add(box(2.9, 2.3, 2.9, stone, 0, 15.55, 0));
  const spire = new THREE.Mesh(new THREE.ConeGeometry(2.3, 5.8, 4), slate); spire.rotation.y = Math.PI / 4; spire.position.y = 19.6; g.add(spire);
  for (const [x, z] of [[1.4, 1.4], [1.4, -1.4], [-1.4, 1.4], [-1.4, -1.4]]) g.add(new THREE.Mesh(new THREE.ConeGeometry(0.22, 1.5, 6), gold).translateX(x).translateY(17.4).translateZ(z));
  g.add(new THREE.Mesh(new THREE.ConeGeometry(0.14, 2.0, 6), gold).translateY(23.4));
  const facade = canvasTex(1024, 256, (c, W, H) => { c.fillStyle = '#D2BA82'; c.fillRect(0, 0, W, H); for (let x = 8; x < W; x += 24) { c.fillStyle = 'rgba(90,70,40,0.35)'; c.fillRect(x, 0, 4, H); c.fillStyle = 'rgba(45,40,40,0.7)'; c.fillRect(x + 8, 40, 9, 64); c.fillRect(x + 8, 150, 9, 64); } }, { repeat: [1, 1] });
  const wallM = mstd('#FFFFFF', 0.85, 0, { map: facade });
  g.add(box(22, 6.5, 5, wallM, 12.4, 3.25, 0));
  const roofShape = new THREE.Shape(); roofShape.moveTo(-2.6, 0); roofShape.lineTo(2.6, 0); roofShape.lineTo(0, 1.8); roofShape.closePath();
  const roofGeo = new THREE.ExtrudeGeometry(roofShape, { depth: 22, bevelEnabled: false }); roofGeo.rotateY(Math.PI / 2);
  const wroof = new THREE.Mesh(roofGeo, slate); wroof.position.set(1.4, 6.5, 0); g.add(wroof);
  for (let x = 2; x < 23.5; x += 1.6) for (const z of [2.45, -2.45]) g.add(new THREE.Mesh(new THREE.ConeGeometry(0.13, 1.1, 4), plain).translateX(x).translateY(7.0).translateZ(z));
  g.add(box(4.2, 15, 4.2, stone, 23.4, 7.5, 0));
  for (const [x, z] of [[1.9, 1.9], [1.9, -1.9], [-1.9, 1.9], [-1.9, -1.9]]) g.add(new THREE.Mesh(new THREE.ConeGeometry(0.28, 2.2, 6), gold).translateX(23.4 + x).translateY(16.1).translateZ(z));
  g.add(cyl(0.04, 0.04, 3, 6, plain, 23.4, 16.5, 0));
  return shadowAll(g);
}

function coliseo() {
  const g = new THREE.Group();
  const arcade = (rows) => canvasTex(1024, 256, (c, W, H) => {
    c.fillStyle = '#D9C6A0'; c.fillRect(0, 0, W, H);
    const rh = H / rows;
    for (let r = 0; r < rows; r++) {
      c.fillStyle = 'rgba(120,100,70,0.5)'; c.fillRect(0, r * rh, W, 5);
      for (let x = 0; x < W; x += 32) {
        c.fillStyle = '#3A2F22';
        if (r === 0 && rows === 4) { c.fillRect(x + 12, r * rh + 18, 9, 16); continue; }
        c.beginPath(); c.moveTo(x + 7, (r + 1) * rh); c.lineTo(x + 7, r * rh + rh * 0.45); c.arc(x + 16, r * rh + rh * 0.45, 9, Math.PI, 0); c.lineTo(x + 25, (r + 1) * rh); c.fill();
      }
    }
  }, { repeat: [3, 1] });
  const outerMat = mstd('#FFFFFF', 0.9, 0, { map: arcade(4), side: THREE.DoubleSide });
  const innerMat = mstd('#FFFFFF', 0.9, 0, { map: arcade(2), side: THREE.DoubleSide });
  const low = new THREE.Mesh(new THREE.CylinderGeometry(8, 8, 5, 72, 1, true, 0, Math.PI * 2), outerMat); low.position.y = 2.5;
  const high = new THREE.Mesh(new THREE.CylinderGeometry(8, 8, 1.9, 72, 1, true, -0.3, Math.PI * 1.45), outerMat); high.position.y = 5.95;
  const inner = new THREE.Mesh(new THREE.CylinderGeometry(5.6, 5.6, 3.2, 60, 1, true), innerMat); inner.position.y = 1.6;
  const cavea = new THREE.Mesh(new THREE.CylinderGeometry(7.9, 5.6, 2.6, 60, 1, true), mstd('#B9A27C', 0.95, 0, { side: THREE.DoubleSide })); cavea.position.y = 4.4;
  const floor = new THREE.Mesh(new THREE.CircleGeometry(5.6, 48), mstd('#CDB48A', 1)); floor.rotation.x = -Math.PI / 2; floor.position.y = 0.4;
  const ring = new THREE.Group(); ring.add(low, high, inner, cavea, floor); ring.scale.set(1.3, 1, 1); g.add(ring);
  return shadowAll(g);
}

function brandeburgo() {
  const g = new THREE.Group();
  const sand = mstd('#DCCDAA', 0.85);
  const verdigris = mstd('#4E7A68', 0.5, 0.6);
  g.add(box(13.4, 0.6, 3.6, sand, 0, 0.3, 0));
  for (const x of [-5.6, -3.4, -1.15, 1.15, 3.4, 5.6]) for (const z of [1.1, -1.1]) g.add(cyl(0.38, 0.44, 6, 18, sand, x, 3.6, z));
  g.add(box(13.4, 1.3, 3.6, sand, 0, 7.25, 0));
  g.add(box(5.6, 1.6, 2.8, sand, 0, 8.7, 0));
  const q = new THREE.Group(); q.position.y = 9.5;
  for (let i = 0; i < 4; i++) { const horse = box(0.42, 0.9, 1.6, verdigris, -0.9 + i * 0.6, 0.45, 0.2); horse.rotation.x = -0.25; q.add(horse); q.add(box(0.3, 0.5, 0.5, verdigris, -0.9 + i * 0.6, 1.05, 0.95)); }
  q.add(box(1.8, 0.6, 0.8, verdigris, 0, 0.3, -0.8));
  q.add(cyl(0.18, 0.28, 1.4, 8, verdigris, 0, 1.3, -0.8));
  q.add(new THREE.Mesh(new THREE.SphereGeometry(0.17, 10, 8), verdigris).translateY(2.1).translateZ(-0.8));
  q.add(cyl(0.03, 0.03, 1.6, 6, verdigris, 0.35, 2.1, -0.8));
  g.add(q);
  return shadowAll(g);
}

function piramides() {
  const g = new THREE.Group();
  const steps = canvasTex(256, 256, (c, W, H) => { c.fillStyle = '#D8B47A'; c.fillRect(0, 0, W, H); for (let y = 0; y < H; y += 8) { c.fillStyle = 'rgba(120,85,45,0.35)'; c.fillRect(0, y, W, 2); } for (let i = 0; i < 400; i++) { c.fillStyle = `rgba(255,240,210,${rand() * 0.25})`; c.fillRect(rand() * W, rand() * H, 3, 2); } }, { repeat: [3, 3] });
  const stone = mstd('#FFFFFF', 0.95, 0, { map: steps });
  const sand = new THREE.Mesh(conform(new THREE.CircleGeometry(26, 48).rotateX(-Math.PI / 2)), mstd('#D9BC8A', 1)); sand.position.y = 0.06; g.add(sand);
  for (const [r, h, x, z] of [[9, 8.1, 0, 0], [8.2, 7.6, -11, -9], [4.6, 4.2, 9, -14]]) { const p = new THREE.Mesh(new THREE.ConeGeometry(r, h, 4), stone); p.rotation.y = Math.PI / 4; p.position.set(x, h / 2 - 0.05, z); g.add(p); }
  const sph = mstd('#CFA56A', 0.95);
  const sphinx = new THREE.Group();
  sphinx.add(box(1.7, 1.1, 4.8, sph, 0, 0.55, 0), box(1.6, 0.45, 1.8, sph, 0, 0.23, 3.1), box(1.05, 1.15, 1.05, sph, 0, 1.5, 1.7));
  const nemes = new THREE.Mesh(new THREE.ConeGeometry(0.95, 1.2, 4), sph); nemes.rotation.y = Math.PI / 4; nemes.position.set(0, 1.75, 1.5); sphinx.add(nemes);
  sphinx.position.set(5, 0, 13); g.add(sphinx);
  const palmLeaf = mstd('#3F7A3A', 0.8), palmTrunk = mstd('#8A6A45', 0.9);
  for (const [x, z] of [[-8, 15], [-6, 17.5], [-9.5, 18], [12, 9], [13.5, 11.5]]) {
    g.add(cyl(0.12, 0.18, 3.2, 6, palmTrunk, x, 1.6, z));
    for (let k = 0; k < 6; k++) { const leaf = new THREE.Mesh(new THREE.ConeGeometry(0.28, 1.8, 4), palmLeaf); const a = (k / 6) * Math.PI * 2; leaf.position.set(x + Math.cos(a) * 0.7, 3.2, z + Math.sin(a) * 0.7); leaf.rotation.set(Math.sin(a) * 1.2, 0, -Math.cos(a) * 1.2); g.add(leaf); }
  }
  return shadowAll(g);
}

function sanBasilio() {
  const g = new THREE.Group();
  const brick = mstd('#A9402C', 0.85);
  const trim = mstd('#EDE3CC', 0.8);
  const gold = mstd('#D8AF45', 0.3, 0.85);
  g.add(box(10, 2.4, 10, brick, 0, 1.2, 0));
  g.add(box(10.3, 0.3, 10.3, trim, 0, 2.45, 0));
  g.add(cyl(1.6, 1.9, 5, 8, brick, 0, 4.9, 0));
  const tent = new THREE.Mesh(new THREE.ConeGeometry(1.75, 6.2, 8), mstd('#FFFFFF', 0.7, 0, { map: stripeTex('#C9A257', '#2F8F57') })); tent.position.y = 10.5; g.add(tent);
  const top = new THREE.Mesh(onionGeo(0.35), gold); top.position.y = 13.4; g.add(top);
  const pairs = [['#2F8F57', '#F2E6C8'], ['#C8322B', '#F2E6C8'], ['#2A63B8', '#F2E6C8'], ['#E3B23C', '#2F8F57'], ['#2F8F57', '#E3B23C'], ['#D9622B', '#2F8F57'], ['#2A63B8', '#E3B23C'], ['#C8322B', '#2F8F57']];
  for (let i = 0; i < 8; i++) {
    const a = (i / 8) * Math.PI * 2, big = i % 2 === 0, d = big ? 3.5 : 3.6, r = big ? 0.95 : 0.7, h = big ? 3.6 : 2.6;
    const x = Math.cos(a) * d, z = Math.sin(a) * d;
    g.add(cyl(r, r * 1.08, h, 12, brick, x, 2.4 + h / 2, z));
    g.add(box(r * 2.3, 0.22, r * 2.3, trim, x, 2.4 + h, z));
    const dome = new THREE.Mesh(onionGeo(r * 1.05), mstd('#FFFFFF', 0.55, 0.1, { map: stripeTex(pairs[i][0], pairs[i][1]) }));
    dome.position.set(x, 2.5 + h, z); g.add(dome);
    g.add(new THREE.Mesh(new THREE.ConeGeometry(0.06, 0.9, 6), gold).translateX(x).translateY(2.5 + h + r * 3).translateZ(z));
  }
  const kred = mstd('#9E3426', 0.85);
  g.add(box(34, 3.2, 1.2, kred, 0, 1.6, -9));
  for (let x = -16.5; x <= 16.5; x += 1.1) g.add(box(0.55, 0.6, 1.2, kred, x, 3.5, -9));
  g.add(box(3, 9, 3, kred, 10, 4.5, -9));
  g.add(box(2.2, 2.2, 2.2, kred, 10, 10.1, -9));
  const kclock = new THREE.Mesh(new THREE.CircleGeometry(0.8, 24), mstd('#2A3A5A', 0.4, 0.4)); kclock.position.set(10, 7.4, -7.45); g.add(kclock);
  const ktent = new THREE.Mesh(new THREE.ConeGeometry(1.5, 4.4, 8), mstd('#2F7A54', 0.6)); ktent.position.set(10, 13.4, -9); g.add(ktent);
  const kstar = new THREE.Mesh(new THREE.OctahedronGeometry(0.42), new THREE.MeshBasicMaterial({ color: new THREE.Color(3, 0.35, 0.3) })); kstar.position.set(10, 16, -9); kstar.scale.set(1, 1.3, 0.4); g.add(kstar);
  return shadowAll(g);
}

function tajMahal() {
  const g = new THREE.Group();
  const marble = mstd('#F5F1E9', 0.32, 0, { envMapIntensity: 0.7 });
  const iwan = canvasTex(512, 256, (c, W, H) => {
    c.fillStyle = '#F5F1E9'; c.fillRect(0, 0, W, H);
    for (let i = 0; i < 4; i++) { const x = i * 128 + 64; c.fillStyle = '#CFC6B5'; c.beginPath(); c.moveTo(x - 34, H - 12); c.lineTo(x - 34, 110); c.quadraticCurveTo(x - 34, 52, x, 30); c.quadraticCurveTo(x + 34, 52, x + 34, 110); c.lineTo(x + 34, H - 12); c.fill(); c.strokeStyle = '#B6AA92'; c.lineWidth = 4; c.strokeRect(x - 52, 14, 104, H - 20); }
  }, { repeat: [2, 1] });
  const body = mstd('#FFFFFF', 0.35, 0, { map: iwan, envMapIntensity: 0.7 });
  g.add(box(15.5, 1, 15.5, marble, 0, 0.5, 0));
  const main = new THREE.Mesh(new THREE.CylinderGeometry(5.3, 5.3, 6.4, 8), body); main.rotation.y = Math.PI / 8; main.position.y = 4.2; g.add(main);
  g.add(cyl(2.3, 2.3, 1.6, 32, marble, 0, 8.2, 0));
  const domePts = [[0, 0], [2.5, 0], [2.95, 0.9], [2.9, 2.0], [2.4, 3.0], [1.4, 3.9], [0.5, 4.5], [0.12, 5.0], [0, 5.2]].map(([r, y]) => new THREE.Vector2(r, y));
  const dome = new THREE.Mesh(new THREE.LatheGeometry(domePts, 48), marble); dome.position.y = 9.0; g.add(dome);
  g.add(new THREE.Mesh(new THREE.ConeGeometry(0.12, 1.4, 8), mstd('#D8AF45', 0.3, 0.85)).translateY(14.8));
  for (const [x, z] of [[3.1, 3.1], [3.1, -3.1], [-3.1, 3.1], [-3.1, -3.1]]) { g.add(cyl(0.8, 0.8, 1.0, 8, marble, x, 7.9, z)); const d = new THREE.Mesh(onionGeo(0.62), marble); d.position.set(x, 8.4, z); g.add(d); }
  for (const [x, z] of [[6.9, 6.9], [6.9, -6.9], [-6.9, 6.9], [-6.9, -6.9]]) {
    g.add(cyl(0.38, 0.52, 10.4, 16, marble, x, 6.2, z));
    for (const y of [4.2, 7.6, 10.8]) g.add(cyl(0.78, 0.78, 0.26, 16, marble, x, y, z));
    const d = new THREE.Mesh(onionGeo(0.45), marble); d.position.set(x, 11.4, z); g.add(d);
  }
  g.add(box(3.4, 0.06, 17, mstd('#E8E1D3', 0.6), 0, 0.03, 17.5));
  const water = new THREE.Mesh(new THREE.BoxGeometry(2.2, 0.08, 16), std('#3E7FB3', 0.05, 0.3, { envMapIntensity: 1.2 })); water.position.set(0, 0.07, 17.5); g.add(water);
  const cypress = mstd('#2E5A33', 0.85);
  for (let z = 10; z <= 25; z += 2.5) for (const x of [-2.7, 2.7]) { const c2 = new THREE.Mesh(new THREE.ConeGeometry(0.45, 2.8, 8), cypress); c2.position.set(x, 1.4, z); g.add(c2); }
  return shadowAll(g);
}

function granMuralla() {
  const g = new THREE.Group();
  const hill = (x, z) => 2.4 * (Math.sin(x * 0.14) + 1.2) * (0.6 + 0.4 * Math.cos(z * 0.18));
  const pathZ = (x) => 4 * Math.sin(x * 0.11);
  const geo = new THREE.PlaneGeometry(70, 36, 70, 36); geo.rotateX(-Math.PI / 2);
  const p = geo.attributes.position;
  for (let i = 0; i < p.count; i++) { const x = p.getX(i), z = p.getZ(i), edge = Math.min(1, (35 - Math.abs(x)) / 8, (18 - Math.abs(z)) / 6); p.setY(i, hill(x, z) * Math.max(0, edge) - 0.3); }
  conform(geo);
  g.add(new THREE.Mesh(geo, mstd('#56783F', 0.95)));
  const stone = mstd('#BEA77F', 0.9);
  const segGeo = new THREE.BoxGeometry(1.15, 1.6, 1.3), cren = new THREE.BoxGeometry(0.4, 0.45, 0.25);
  for (let x = -30; x <= 30; x += 1) {
    const z = pathZ(x), y = hill(x, z) * Math.min(1, (35 - Math.abs(x)) / 8, (18 - Math.abs(z)) / 6) - 0.3 - (x * x + z * z) / (2 * R);
    const s = new THREE.Mesh(segGeo, stone); s.position.set(x, y + 0.6, z); s.rotation.y = -Math.atan(0.44 * Math.cos(x * 0.11)); g.add(s);
    if (x % 2 === 0) for (const side of [-0.55, 0.55]) { const c = new THREE.Mesh(cren, stone); c.position.set(x, y + 1.6, z + side); c.rotation.y = s.rotation.y; g.add(c); }
    if (x % 12 === 0) { g.add(box(2.3, 3.4, 2.3, stone, x, y + 1.4, z)); g.add(box(2.6, 0.4, 2.6, stone, x, y + 3.2, z)); }
  }
  return shadowAll(g);
}

function fuji() {
  const g = new THREE.Group();
  const geo = new THREE.ConeGeometry(30, 20, 128, 16, true);
  const p = geo.attributes.position, colors = [];
  const snow = new THREE.Color('#FFFFFF'), rock = new THREE.Color('#5E6F90'), base = new THREE.Color('#4D6B48');
  for (let i = 0; i < p.count; i++) {
    const x = p.getX(i), y = p.getY(i), z = p.getZ(i), a = Math.atan2(z, x);
    const k = 1 + 0.05 * Math.sin(a * 11 + y * 0.6) * (1 - (y + 10) / 20);
    p.setX(i, x * k); p.setZ(i, z * k);
    const h = (y + 10) / 20, line = 0.64 + 0.06 * Math.sin(a * 9) + 0.03 * Math.sin(a * 23);
    const col = h > line ? snow : h < 0.18 ? base.clone().lerp(rock, h / 0.18) : rock;
    colors.push(col.r, col.g, col.b);
  }
  geo.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3)); geo.computeVertexNormals();
  const m = new THREE.Mesh(geo, mstd('#FFFFFF', 0.9, 0, { vertexColors: true })); m.position.y = 9.4; g.add(m);
  return shadowAll(g);
}
function pagoda() {
  const g = new THREE.Group();
  const red = mstd('#C43B2B', 0.7), roof = mstd('#3B302C', 0.6, 0.2), gold = mstd('#D8AF45', 0.3, 0.85);
  let y = 0;
  for (let i = 0; i < 5; i++) {
    const w = 3.0 - i * 0.38;
    g.add(box(w, 1.25, w, red, 0, y + 0.62, 0));
    const r = new THREE.Mesh(new THREE.ConeGeometry(w * 1.05, 0.9, 4), roof); r.rotation.y = Math.PI / 4; r.position.y = y + 1.6; g.add(r);
    y += 1.6;
  }
  g.add(cyl(0.07, 0.1, 2.4, 6, gold, 0, y + 1.0, 0));
  const blossom = mstd('#F6B7CF', 0.8), bark = mstd('#5A4034', 0.9);
  for (let i = 0; i < 10; i++) { const a = rand() * Math.PI * 2, d = 4 + rand() * 4.5, x = Math.cos(a) * d, z = Math.sin(a) * d; g.add(cyl(0.1, 0.14, 1.4, 6, bark, x, 0.7, z)); const crown = new THREE.Mesh(new THREE.IcosahedronGeometry(1.1 + rand() * 0.5, 1), blossom); crown.position.set(x, 2.0, z); crown.scale.y = 0.75; g.add(crown); }
  return shadowAll(g);
}

const CATALOG = [
  { key: 'alcala', build: puertaAlcala, x: 15, country: 'España', code: 'ES', name: 'Puerta de Alcalá', place: 'Madrid · España', fact: 'Puerta neoclásica que Carlos III mandó levantar; se inauguró en 1778.' },
  { key: 'eiffel', build: () => eiffelLike('#6E5A47'), x: -14, country: 'Francia', code: 'FR', name: 'Torre Eiffel', place: 'París · Francia', fact: '330 metros de hierro, construida para la Exposición Universal de 1889.' },
  { key: 'bigben', build: bigBen, x: 13, country: 'Reino Unido', code: 'GB', name: 'Big Ben', place: 'Londres · Reino Unido', fact: 'La torre se llama Elizabeth Tower; Big Ben es el nombre de su gran campana.' },
  { key: 'coliseo', build: coliseo, x: -22, country: 'Italia', code: 'IT', name: 'Coliseo', place: 'Roma · Italia', fact: 'Anfiteatro inaugurado en el año 80 en el que cabían unos 50.000 espectadores.' },
  { key: 'brandeburgo', build: brandeburgo, x: 16, country: 'Alemania', code: 'DE', name: 'Puerta de Brandeburgo', place: 'Berlín · Alemania', fact: 'Terminada en 1791, hoy es el gran símbolo de la reunificación alemana.' },
  { key: 'piramides', build: piramides, x: -30, country: 'Egipto', code: 'EG', name: 'Pirámides de Guiza', place: 'Guiza · Egipto', fact: 'La Gran Pirámide tiene unos 4.500 años y llegó a medir 146 metros.' },
  { key: 'basilio', build: sanBasilio, x: 16, country: 'Rusia', code: 'RU', name: 'Catedral de San Basilio', place: 'Moscú · Rusia', fact: 'Levantada entre 1555 y 1561 en la Plaza Roja, con sus cúpulas de colores.' },
  { key: 'taj', build: tajMahal, x: -20, country: 'India', code: 'IN', name: 'Taj Mahal', place: 'Agra · India', fact: 'Mausoleo de mármol blanco que el emperador Shah Jahan mandó construir para su esposa en el siglo XVII.' },
  { key: 'muralla', build: granMuralla, x: 30, country: 'China', code: 'CN', name: 'Gran Muralla', place: 'Pekín · China', fact: 'Miles de kilómetros de muralla levantada a lo largo de más de 2.000 años.' },
  { key: 'fuji', build: fuji, x: -60, country: 'Japón', code: 'JP', name: 'Monte Fuji', place: 'Honshu · Japón', fact: 'Volcán de 3.776 metros, la montaña más alta de Japón.' },
  { key: 'tokio', build: () => eiffelLike('#E8432E', true), x: 18, country: 'Japón', code: 'JP', name: 'Torre de Tokio', place: 'Tokio · Japón', fact: '333 metros, inaugurada en 1958 y pintada de blanco y naranja por seguridad aérea.' }
];
// Solo los monumentos que la app eligió (los que quedan cerca de TU ruta),
// en el orden en que se pasa por ellos. Los textos vienen en tu idioma.
const ROUTE = (NQ.monuments || []).map((k) => CATALOG.find((m) => m.key === k)).filter(Boolean).map((m) => {
  const tx = (NQ.texts || {})[m.key] || {};
  const country = countryName(m.code);
  return { ...m, name: tx.name || m.name, country, place: tx.city ? `${tx.city} · ${country}` : m.place, fact: tx.fact || m.fact };
});
const PHI0 = 0.05, STEP = 0.045;
// Aunque haya pocos monumentos, el vuelo dura lo mismo que con 6.
const THETA_END = PHI0 + STEP * Math.max(ROUTE.length - 1, 5) + 0.03;
ROUTE.forEach((m, i) => {
  m.phi = PHI0 + STEP * i;
  m.obj = m.build();
  m.lb = new THREE.Box3().setFromObject(m.obj); // footprint before placing, used later for decorations
  if (!['fuji', 'muralla', 'piramides'].includes(m.key)) {
    const lb = m.lb, rad = Math.max(lb.max.x - lb.min.x, lb.max.z - lb.min.z) * 0.5 + 3;
    const plaza = new THREE.Mesh(conform(new THREE.CircleGeometry(Math.min(rad, 16), 48).rotateX(-Math.PI / 2)), mstd('#BDB4A3', 0.95));
    plaza.position.set((lb.max.x + lb.min.x) / 2, 0.04, (lb.max.z + lb.min.z) / 2); plaza.receiveShadow = true; m.obj.add(plaza);
  }
  place(m.obj, m.phi, m.x, m.x > 0 ? -Math.PI / 2 : Math.PI / 2);
  m.obj.updateMatrix();
  m.height = Math.min(m.lb.max.y - m.lb.min.y, 28);
});
{ const fuji = ROUTE.find((m) => m.key === 'fuji'); if (fuji) { const p = pagoda(); place(p, fuji.phi - 0.006, -16, Math.PI / 2); } }

/* ---------- landing timeline (seconds after the final approach starts) ---------- */
const SPEED = 0.012; // radians of planet per second while cruising
const smooth = (x) => { x = THREE.MathUtils.clamp(x, 0, 1); return x * x * (3 - 2 * x); };
const LAND = { touch: 8.2, stop: 14 };
const GROUND_Y = 2.6; // plane height when its wheels are on the runway
const LAND_RATE = 2;  // the whole landing (approach, taxi, passengers) runs twice as fast as the cruise
const landSpeed = (t) => t < LAND.touch ? 1 - 0.45 * smooth(t / LAND.touch) : 0.55 * (1 - smooth((t - LAND.touch) / (LAND.stop - LAND.touch)));
const LAND_DT = 0.02, landTable = [0];
for (let t = 0; t < 80; t += LAND_DT) landTable.push(landTable[landTable.length - 1] + landSpeed(t + LAND_DT / 2) * SPEED * LAND_DT);
const landDist = (t) => { const f = Math.max(0, t) / LAND_DT, i = Math.min(Math.floor(f), landTable.length - 2); return landTable[i] + (landTable[i + 1] - landTable[i]) * Math.min(1, f - i); };
const THETA_TOUCH = THETA_END + landDist(LAND.touch);
const RWY_LEN = 80, RWY_W = 20;
const RWY_START = THETA_TOUCH - 12 / R; // runway threshold, a little before the touchdown point
const inAirport = (phi, x) => phi > RWY_START - 50 / R && phi < RWY_START + 115 / R && Math.abs(x) < 78;

/* ---------- trees, villages, lights at night ---------- */
const nearMonument = (phi, x, pad) => inAirport(phi, x) || ROUTE.some((m) => Math.abs((phi - m.phi) * R) < pad + (m.key === 'muralla' ? 20 : 0) && Math.abs(x - m.x) < pad + (m.key === 'fuji' ? 26 : m.key === 'piramides' ? 18 : m.key === 'muralla' ? 26 : 0));
const treeGeo = new THREE.ConeGeometry(0.75, 2.2, 7); treeGeo.translate(0, 1.1, 0);
const TREE_N = 4200;
const trees = new THREE.InstancedMesh(treeGeo, std('#FFFFFF', 0.9, 0, { envMapIntensity: 0.1 }), TREE_N);
const treeVar = new Float32Array(TREE_N * 2);
trees.castShadow = true; trees.receiveShadow = true;
{
  let n = 0;
  while (n < TREE_N) {
    const cphi = -0.12 + rand() * (THETA_END + 0.3), cx = (rand() - 0.5) * 260;
    const count = 15 + Math.floor(rand() * 50);
    for (let k = 0; k < count && n < TREE_N; k++) {
      const phi = cphi + (rand() - 0.5) * 0.025, x = cx + (rand() - 0.5) * 16;
      if (nearMonument(phi, x, 12)) continue;
      instanceAt(trees, n, phi, x, -0.1, 0.7 + rand() * 0.8, rand() * 6);
      treeVar[n * 2] = rand(); treeVar[n * 2 + 1] = rand(); n++;
    }
  }
}
earth.add(trees);
function colorTrees(name) {
  const tc = new THREE.Color();
  for (let i = 0; i < TREE_N; i++) {
    const a = treeVar[i * 2], b = treeVar[i * 2 + 1];
    if (name === 'halloween') { if (a < 0.22) tc.setHSL(0.27 + b * 0.05, 0.4, 0.17 + b * 0.08); else tc.setHSL(0.015 + a * 0.11, 0.78, 0.3 + b * 0.16); }
    else if (name === 'navidad') { if (a < 0.55) tc.setHSL(0.37, 0.35, 0.15 + b * 0.08); else tc.setHSL(0.56, 0.18 + b * 0.1, 0.74 + (a - 0.55) * 0.3); }
    else tc.setHSL(0.27 + a * 0.06, 0.45, 0.16 + b * 0.1);
    trees.setColorAt(i, tc);
  }
  trees.instanceColor.needsUpdate = true;
}

const HOUSE_N = 1400;
const walls = new THREE.InstancedMesh(new THREE.BoxGeometry(1.1, 0.9, 1.4).translate(0, 0.45, 0), std('#E9E1D2', 0.85, 0, { envMapIntensity: 0.1 }), HOUSE_N);
const roofGeo = new THREE.ConeGeometry(1.0, 0.7, 4); roofGeo.rotateY(Math.PI / 4); roofGeo.scale(1, 1, 1.27); roofGeo.translate(0, 1.25, 0);
const roofs = new THREE.InstancedMesh(roofGeo, std('#FFFFFF', 0.8, 0, { envMapIntensity: 0.1 }), HOUSE_N);
const roofCols = [];
const lights = new THREE.InstancedMesh(new THREE.SphereGeometry(0.16, 6, 4), new THREE.MeshBasicMaterial({ color: new THREE.Color(3.2, 2.2, 1.0), transparent: true, opacity: 0, depthWrite: false }), HOUSE_N);
walls.castShadow = roofs.castShadow = true; walls.receiveShadow = roofs.receiveShadow = true;
{
  let n = 0;
  const towns = [];
  ROUTE.forEach((m) => { for (let k = 0; k < 3; k++) towns.push([m.phi + (rand() - 0.5) * 0.05, m.x + (m.x > 0 ? 1 : -1) * (24 + rand() * 30)]); });
  for (let k = 0; k < 26; k++) towns.push([-0.1 + rand() * (THETA_END + 0.25), (rand() - 0.5) * 220]);
  for (const [tphi, tx] of towns) {
    const count = 20 + Math.floor(rand() * 30);
    for (let k = 0; k < count && n < HOUSE_N; k++) {
      const phi = tphi + (rand() - 0.5) * 0.03, x = tx + (rand() - 0.5) * 22;
      if (nearMonument(phi, x, 11) || Math.abs(x) > 140) continue;
      const s = 0.8 + rand() * 0.6, yaw = Math.floor(rand() * 4) * Math.PI / 2 + (rand() - 0.5) * 0.3;
      instanceAt(walls, n, phi, x, 0, s, yaw); instanceAt(roofs, n, phi, x, 0, s, yaw); instanceAt(lights, n, phi, x + 0.7, 1.0, 1, 0);
      roofCols[n] = pick(['#B4553D', '#A64B35', '#8E3F2F', '#5B6168', '#C06A45']); n++;
    }
  }
  walls.count = roofs.count = lights.count = n;
}
earth.add(walls, roofs, lights);
function colorRoofs(name) {
  const rc = new THREE.Color();
  for (let i = 0; i < roofCols.length; i++) { rc.set(name === 'navidad' ? '#F1F5F8' : roofCols[i]); roofs.setColorAt(i, rc); }
  roofs.instanceColor.needsUpdate = true;
}

/* clouds: soft clusters of spheres, some above and some below the plane */
const CLOUD_N = 560;
const clouds = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(1, 2), std('#FFFFFF', 1, 0, { envMapIntensity: 0.3 }), CLOUD_N);
{
  let n = 0;
  while (n < CLOUD_N) {
    const phi = -0.12 + rand() * (THETA_END + 0.3), x = (rand() - 0.5) * 320;
    const below = rand() < 0.3;
    const lift = below ? 3 + rand() * 2.5 : 19 + rand() * 12;
    if (!below && Math.abs(x) < 22 && lift < 24) continue;
    if (below && (Math.abs(x) < 14 || inAirport(phi, x))) continue;
    const puffs = 5 + Math.floor(rand() * 5), size = below ? 1.2 + rand() * 1.4 : 2 + rand() * 3;
    for (let k = 0; k < puffs && n < CLOUD_N; k++) {
      dummy.position.copy(surfacePoint(phi + (rand() - 0.5) * size * 2.4 / R, x + (rand() - 0.5) * size * 2.6, lift + (rand() - 0.3) * size * 0.5));
      dummy.rotation.set(phi, 0, 0);
      const s = size * (0.6 + rand() * 0.6); dummy.scale.set(s * 1.3, s * 0.75, s);
      dummy.updateMatrix(); clouds.setMatrixAt(n++, dummy.matrix);
    }
  }
}
earth.add(clouds);

/* ---------- the airliner ---------- */
/* holiday themes: livery colours, fin art and the decorations each one switches on */
const THEMES = {
  normal: { label: T.themeNormal, top: null, belly: null, stripe2: null, name: '#1C3F94', title: null, fin: ['#173A8C', '#5A93F0', '#3DDC97'], nacelle: '#E8EDF1', band: '#3DDC97', flood: null, grass: '#6F8F4C' },
  halloween: { label: T.themeHalloween, top: '#4B2580', belly: '#1A0E24', stripe2: '#FF7A1A', name: '#FFB347', title: T.happyHalloween, titleColor: '#FF8C1A', fin: ['#1E0B33', '#5B2A8C', '#FF7A1A'], nacelle: '#FF7A1A', band: '#1A0E24', flood: '#FF6A10', grass: '#9A8448' },
  navidad: { label: T.themeXmas, top: '#FFFFFF', belly: '#C8102E', stripe2: '#1E7A3C', name: '#B0102A', title: T.merryXmas, titleColor: '#FFFFFF', fin: ['#7A0A1C', '#D6283F', '#1E7A3C'], nacelle: '#C8102E', band: '#F4F4F4', flood: '#FFE7B0', grass: '#E8EEF2' }
};
const THEME_ORDER = ['normal', 'halloween', 'navidad'];
function themeForDate(d) {
  const m = d.getMonth() + 1, day = d.getDate();
  if ((m === 10 && day >= 15) || (m === 11 && day <= 2)) return 'halloween';
  if (m === 12 || (m === 1 && day <= 6)) return 'navidad';
  return 'normal';
}
function liveryTexture(th) {
  return canvasTex(2048, 2048, (g, W, H) => {
    const Y = (v) => (1 - v) * H;
    // u runs around the fuselage (0/1 = belly, 0.5 = top), v along it (0 = tail, 1 = nose).
    // stamp() draws a shape upright on the side, squeezing it along the body so it is not stretched on the 3D model
    const stamp = (u, v, sc, fn) => { g.save(); g.translate(u * W, Y(v)); g.rotate(u < 0.5 ? Math.PI / 2 : -Math.PI / 2); g.scale(0.35 * sc, sc); fn(); g.restore(); };
    if (!th.top) {
      const grad = g.createLinearGradient(0, 0, W, 0);
      grad.addColorStop(0, '#A7B2BB'); grad.addColorStop(0.14, '#E4E9ED'); grad.addColorStop(0.3, '#FFFFFF'); grad.addColorStop(0.7, '#FFFFFF'); grad.addColorStop(0.86, '#E4E9ED'); grad.addColorStop(1, '#A7B2BB');
      g.fillStyle = grad; g.fillRect(0, 0, W, H);
      for (const u of [0.205, 0.795]) {
        g.fillStyle = '#2A4FA8'; g.fillRect(u * W - 18, Y(0.975), 36, Y(0.11) - Y(0.975));
        g.fillStyle = '#3DDC97'; g.fillRect(u * W + (u < 0.5 ? 22 : -32), Y(0.96), 10, Y(0.13) - Y(0.96));
      }
    } else {
      g.fillStyle = th.top; g.fillRect(0, 0, W, H);
      g.fillStyle = th.belly; g.fillRect(0, 0, 0.245 * W, H); g.fillRect(0.755 * W, 0, 0.245 * W, H);
      const sh = g.createLinearGradient(0, 0, W, 0);
      sh.addColorStop(0, 'rgba(0,0,0,0.28)'); sh.addColorStop(0.16, 'rgba(0,0,0,0)'); sh.addColorStop(0.84, 'rgba(0,0,0,0)'); sh.addColorStop(1, 'rgba(0,0,0,0.28)');
      g.fillStyle = sh; g.fillRect(0, 0, W, H);
      g.fillStyle = th.stripe2;
      for (const u of [0.245, 0.755]) g.fillRect(u * W - 9, Y(0.975), 18, Y(0.11) - Y(0.975));
    }
    if (th === THEMES.halloween) {
      // bats along the purple roof, pumpkins along the black belly
      g.fillStyle = 'rgba(255,214,150,0.55)';
      for (let i = 0; i < 260; i++) { g.beginPath(); g.arc((0.34 + ((i * 0.6180339) % 1) * 0.32) * W, Y(0.1 + ((i * 0.7548776) % 1) * 0.84), 2.5, 0, Math.PI * 2); g.fill(); }
      const bat = () => {
        g.fillStyle = '#0E0614'; g.beginPath(); g.moveTo(0, -6); g.quadraticCurveTo(14, -22, 40, -16); g.quadraticCurveTo(34, -6, 36, 4); g.quadraticCurveTo(26, -2, 20, 6); g.quadraticCurveTo(12, 0, 6, 8); g.lineTo(0, 12);
        g.lineTo(-6, 8); g.quadraticCurveTo(-12, 0, -20, 6); g.quadraticCurveTo(-26, -2, -36, 4); g.quadraticCurveTo(-34, -6, -40, -16); g.quadraticCurveTo(-14, -22, 0, -6); g.fill();
        g.beginPath(); g.moveTo(-5, -5); g.lineTo(-7, -15); g.lineTo(-1, -7); g.moveTo(5, -5); g.lineTo(7, -15); g.lineTo(1, -7); g.fill();
      };
      let k = 0;
      for (let v = 0.16; v < 0.9; v += 0.075) for (const u of [0.45, 0.55]) stamp(u + (k++ % 3 - 1) * 0.012, v + (k % 2) * 0.03, 1.5, bat);
      const pumpkin = () => {
        g.fillStyle = '#FF8C1A';
        for (const [dx, rx] of [[-24, 20], [24, 20], [-11, 22], [11, 22], [0, 22]]) { g.beginPath(); g.ellipse(dx, 0, rx, 30, 0, 0, Math.PI * 2); g.fill(); }
        g.fillStyle = '#3E7A2E'; g.fillRect(-4, -40, 8, 13);
        g.fillStyle = '#2A1000';
        g.beginPath(); g.moveTo(-20, -6); g.lineTo(-8, -6); g.lineTo(-14, -17); g.fill();
        g.beginPath(); g.moveTo(20, -6); g.lineTo(8, -6); g.lineTo(14, -17); g.fill();
        g.beginPath(); g.moveTo(-24, 6); g.lineTo(-14, 12); g.lineTo(-8, 7); g.lineTo(0, 14); g.lineTo(8, 7); g.lineTo(14, 12); g.lineTo(24, 6); g.quadraticCurveTo(0, 30, -24, 6); g.fill();
      };
      for (let v = 0.2; v < 0.9; v += 0.11) for (const u of [0.12, 0.88]) stamp(u, v, 1.6, pumpkin);
    }
    if (th === THEMES.navidad) {
      const flake = (col) => () => {
        g.strokeStyle = col; g.lineWidth = 5; g.lineCap = 'round';
        for (let i = 0; i < 6; i++) { g.save(); g.rotate((i * Math.PI) / 3); g.beginPath(); g.moveTo(0, 0); g.lineTo(0, -34); g.moveTo(0, -20); g.lineTo(-9, -29); g.moveTo(0, -20); g.lineTo(9, -29); g.stroke(); g.restore(); }
      };
      for (let v = 0.18; v < 0.9; v += 0.09) for (const u of [0.11, 0.89]) stamp(u + ((v * 13) % 1 - 0.5) * 0.04, v, 1.4, flake('rgba(255,255,255,0.9)'));
      for (let v = 0.2; v < 0.9; v += 0.12) for (const u of [0.45, 0.55]) stamp(u, v + (u < 0.5 ? 0 : 0.06), 1.1, flake('rgba(200,16,46,0.35)'));
    }
    for (const u of [0.292, 0.708]) {
      for (let v = 0.31; v < 0.86; v += 0.0125) {
        if (Math.abs(v - 0.585) < 0.012) continue;
        g.fillStyle = '#1C2733'; const x = u * W, y = Y(v);
        g.beginPath(); g.roundRect(x - 26, y - 13, 52, 26, 10); g.fill();
        g.fillStyle = 'rgba(140,180,210,0.35)'; g.fillRect(x - 18, y - 9, 10, 18);
      }
      g.strokeStyle = '#9AA6AF'; g.lineWidth = 4;
      for (const v of [0.885, 0.585, 0.29]) g.strokeRect(u * W - 34, Y(v) - 30, 68, 60);
    }
    g.fillStyle = '#152230';
    const cock = (u0, u1) => { g.beginPath(); g.moveTo(u0 * W, Y(0.952)); g.lineTo(u1 * W, Y(0.955)); g.lineTo(u1 * W, Y(0.968)); g.lineTo(u0 * W + (u1 - u0) * W * 0.2, Y(0.972)); g.closePath(); g.fill(); };
    cock(0.4, 0.475); cock(0.6, 0.525); cock(0.33, 0.39); cock(0.67, 0.61);
    g.fillStyle = th.name; g.font = '800 150px Manrope, Arial, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.save(); g.translate(0.375 * W, Y(0.62)); g.rotate(Math.PI / 2); g.fillText('NomadIQ', 0, 0); g.restore();
    g.save(); g.translate(0.625 * W, Y(0.62)); g.rotate(-Math.PI / 2); g.fillText('NomadIQ', 0, 0); g.restore();
    if (th.title) {
      g.font = '800 104px Manrope, Arial, sans-serif'; g.lineWidth = 10; g.strokeStyle = 'rgba(0,0,0,0.55)'; g.fillStyle = th.titleColor;
      for (const u of [0.2, 0.8]) { g.save(); g.translate(u * W, Y(0.3)); g.rotate(u < 0.5 ? Math.PI / 2 : -Math.PI / 2); g.scale(0.62, 1); g.strokeText(th.title, 0, 0); g.fillText(th.title, 0, 0); g.restore(); }
    }
    g.strokeStyle = 'rgba(120,135,148,0.35)'; g.lineWidth = 2;
    for (let v = 0.12; v < 0.95; v += 0.06) { g.beginPath(); g.moveTo(0, Y(v)); g.lineTo(W, Y(v)); g.stroke(); }
  });
}
/* cabin windows that light up warm at night (an emissive map with the same layout as the livery) */
function windowGlowTexture() {
  return canvasTex(1024, 1024, (g, W, H) => {
    const Y = (v) => (1 - v) * H;
    g.fillStyle = '#000000'; g.fillRect(0, 0, W, H); g.fillStyle = '#FFFFFF';
    for (const u of [0.292, 0.708]) for (let v = 0.31; v < 0.86; v += 0.0125) { if (Math.abs(v - 0.585) < 0.012) continue; g.beginPath(); g.roundRect(u * W - 11, Y(v) - 5, 22, 10, 4); g.fill(); }
  });
}
function finTexture(th) {
  const t = canvasTex(512, 512, (g, W, H) => {
    const [c0, c1, c2] = th.fin;
    const gr = g.createLinearGradient(0, H, W, 0); gr.addColorStop(0, c0); gr.addColorStop(1, c1);
    g.fillStyle = gr; g.fillRect(0, 0, W, H);
    g.fillStyle = c2; g.beginPath(); g.moveTo(W * 0.15, H); g.lineTo(W * 0.42, H); g.lineTo(W * 0.95, 0); g.lineTo(W * 0.7, 0); g.fill();
    const cx = W * 0.5, cy = H * 0.52;
    if (th === THEMES.halloween) {
      g.fillStyle = '#FFB13B'; g.beginPath(); g.arc(cx, cy, 96, 0, Math.PI * 2); g.fill();
      g.fillStyle = '#1A0E24'; g.save(); g.translate(cx, cy + 6); g.scale(2.2, 2.2);
      g.beginPath(); g.moveTo(0, -6); g.quadraticCurveTo(14, -22, 40, -16); g.quadraticCurveTo(34, -6, 36, 4); g.quadraticCurveTo(26, -2, 20, 6); g.quadraticCurveTo(12, 0, 6, 8); g.lineTo(0, 12);
      g.lineTo(-6, 8); g.quadraticCurveTo(-12, 0, -20, 6); g.quadraticCurveTo(-26, -2, -36, 4); g.quadraticCurveTo(-34, -6, -40, -16); g.quadraticCurveTo(-14, -22, 0, -6); g.fill(); g.restore();
    } else if (th === THEMES.navidad) {
      g.fillStyle = '#FFFFFF'; g.beginPath(); g.arc(cx, cy, 92, 0, Math.PI * 2); g.fill();
      g.strokeStyle = '#C8102E'; g.lineWidth = 9; g.lineCap = 'round';
      for (let i = 0; i < 6; i++) { g.save(); g.translate(cx, cy); g.rotate((i * Math.PI) / 3); g.beginPath(); g.moveTo(0, 0); g.lineTo(0, -70); g.moveTo(0, -42); g.lineTo(-18, -60); g.moveTo(0, -42); g.lineTo(18, -60); g.stroke(); g.restore(); }
    } else {
      g.fillStyle = '#FFFFFF'; g.beginPath(); g.arc(cx, cy, 92, 0, Math.PI * 2); g.fill();
      g.fillStyle = '#2A4FA8'; g.beginPath(); g.moveTo(cx, cy - 60); g.lineTo(cx + 42, cy); g.lineTo(cx, cy + 60); g.lineTo(cx - 42, cy); g.fill();
    }
  });
  t.repeat.set(1 / 3.85, 1 / 4.3); t.offset.set(9.25 / 3.85, -0.6 / 4.3);
  return t;
}
const textureCache = {};
const cached = (key, make) => textureCache[key] || (textureCache[key] = make());

/* hats for the tail fin (and a tiny one for our passenger) */
function witchHat() {
  const g = new THREE.Group();
  const felt = std('#2A1440', 0.8, 0, { envMapIntensity: 0.4 });
  g.add(new THREE.Mesh(new THREE.CylinderGeometry(0.95, 1.0, 0.07, 32), felt));
  const cone = new THREE.ConeGeometry(0.5, 1.8, 24, 8); cone.translate(0, 0.9, 0);
  { const p = cone.attributes.position; for (let i = 0; i < p.count; i++) { const y = p.getY(i) / 1.8; p.setZ(i, p.getZ(i) - 0.45 * y * y * y); } cone.computeVertexNormals(); }
  g.add(new THREE.Mesh(cone, felt));
  g.add(cyl(0.5, 0.52, 0.2, 24, std('#FF7A1A', 0.5), 0, 0.14, 0));
  g.add(box(0.18, 0.18, 0.05, std('#E8C04A', 0.3, 0.8), 0, 0.14, 0.5));
  return shadowAll(g);
}
function santaHat() {
  const g = new THREE.Group();
  const red = std('#D0142C', 0.7, 0, { envMapIntensity: 0.4 }), fur = std('#FFFFFF', 0.95, 0, { envMapIntensity: 0.3 });
  const cone = new THREE.ConeGeometry(0.55, 1.6, 24, 8); cone.translate(0, 0.8, 0);
  { const p = cone.attributes.position; for (let i = 0; i < p.count; i++) { const y = p.getY(i) / 1.6; p.setZ(i, p.getZ(i) - 0.6 * y * y); p.setY(i, p.getY(i) * (1 - 0.15 * y)); } cone.computeVertexNormals(); }
  g.add(new THREE.Mesh(cone, red));
  const rim = new THREE.Mesh(new THREE.TorusGeometry(0.55, 0.15, 10, 28), fur); rim.rotation.x = Math.PI / 2; rim.position.y = 0.05; g.add(rim);
  g.add(new THREE.Mesh(new THREE.SphereGeometry(0.17, 14, 10), fur).translateY(1.36).translateZ(-0.6));
  return shadowAll(g);
}
const fanTex = canvasTex(256, 256, (g, W) => {
  g.fillStyle = '#20262C'; g.beginPath(); g.arc(W / 2, W / 2, W / 2, 0, Math.PI * 2); g.fill();
  g.fillStyle = '#8E99A3';
  for (let i = 0; i < 22; i++) { g.save(); g.translate(W / 2, W / 2); g.rotate((i / 22) * Math.PI * 2); g.beginPath(); g.moveTo(10, -4); g.quadraticCurveTo(70, -14, 124, -8); g.lineTo(124, 6); g.quadraticCurveTo(70, 4, 10, 6); g.fill(); g.restore(); }
});

function buildPlane() {
  const plane = new THREE.Group();
  const paint = std('#FFFFFF', 0.36, 0.25, { map: cached('livery-normal', () => liveryTexture(THEMES.normal)), envMapIntensity: 1.0, emissive: new THREE.Color('#FFD49A'), emissiveMap: windowGlowTexture(), emissiveIntensity: 0 });
  paint.userData.env = 1.0;
  const nacMat = std('#E8EDF1', 0.3, 0.4, { side: THREE.DoubleSide, envMapIntensity: 1 });
  const bandMat = std('#3DDC97', 0.35, 0.3, { envMapIntensity: 1 });
  const metal = std('#C9D2DA', 0.3, 0.8, { envMapIntensity: 1.0 });
  const wingMat = std('#DCE3E8', 0.35, 0.45, { envMapIntensity: 0.9 });
  const darkMetal = std('#2A3138', 0.4, 0.8);

  // fuselage: a lathe profile with a rounded nose and a tapering, upswept tail
  const pts = [];
  const N = 90;
  for (let i = 0; i <= N; i++) {
    const y = -9 + (18 * i) / N;
    let r;
    if (y > 6) r = Math.pow(Math.max(0, 1 - ((y - 6) / 3) ** 2), 0.6);
    else if (y < -4.5) { const t = (-4.5 - y) / 4.5; r = 1 - 0.86 * Math.pow(t, 1.25); }
    else r = 1;
    pts.push(new THREE.Vector2(Math.max(r, i === 0 || i === N ? 0 : 0.02), y));
  }
  const fus = new THREE.LatheGeometry(pts, 64);
  fus.rotateX(Math.PI / 2);
  { const p = fus.attributes.position; for (let i = 0; i < p.count; i++) { const z = p.getZ(i); if (z < -4) { const t = (-4 - z) / 5; p.setY(i, p.getY(i) + 0.8 * Math.pow(t, 1.6)); } } fus.computeVertexNormals(); }
  const body = new THREE.Mesh(fus, paint);
  plane.add(body);

  const wingGeo = (side, rootX, rootLead, rootTrail, tipX, tipLead, tipTrail, thick) => {
    const s = new THREE.Shape();
    s.moveTo(side * rootX, rootLead); s.lineTo(side * tipX, tipLead); s.lineTo(side * tipX, tipTrail); s.lineTo(side * rootX, rootTrail); s.closePath();
    const geo = new THREE.ExtrudeGeometry(s, { depth: thick, bevelEnabled: true, bevelThickness: thick * 0.4, bevelSize: thick * 0.4, bevelSegments: 4, steps: 1 });
    geo.rotateX(Math.PI / 2); geo.translate(0, thick / 2, 0);
    return geo;
  };
  const navs = [], strobes = [];
  for (const side of [1, -1]) {
    const w = new THREE.Mesh(wingGeo(side, 0.6, 2.4, -2.0, 9.0, -2.4, -3.4, 0.24), wingMat);
    w.position.y = -0.45; w.rotation.z = side * 0.07; plane.add(w);
    const wl = new THREE.Shape(); wl.moveTo(-2.4, 0); wl.lineTo(-3.25, 1.4); wl.lineTo(-3.65, 1.4); wl.lineTo(-3.45, 0); wl.closePath();
    const wlg = new THREE.ExtrudeGeometry(wl, { depth: 0.1, bevelEnabled: false }); wlg.rotateY(-Math.PI / 2);
    const winglet = new THREE.Mesh(wlg, std('#2F5FC8', 0.3, 0.3, { envMapIntensity: 1 }));
    winglet.position.set(side * 9.0 + (side > 0 ? 0.05 : 0.05), -0.45 + 9.0 * 0.07 + 0.05, 0); winglet.rotation.z = -side * 0.12; plane.add(winglet);
    const h = new THREE.Mesh(wingGeo(side, 0.3, -6.5, -8.2, 3.6, -8.3, -9.0, 0.15), wingMat);
    h.position.y = 0.42; h.rotation.z = side * 0.12; plane.add(h);
    // engine
    const eng = new THREE.Group();
    const nacPts = [[0.56, 1.25], [0.66, 1.52], [0.79, 1.46], [0.85, 1.05], [0.86, 0.3], [0.8, -0.6], [0.66, -1.25], [0.55, -1.45]].map(([r, y]) => new THREE.Vector2(r, y));
    const nacGeo = new THREE.LatheGeometry(nacPts, 48); nacGeo.rotateX(Math.PI / 2);
    eng.add(new THREE.Mesh(nacGeo, nacMat));
    const band = new THREE.Mesh(new THREE.CylinderGeometry(0.875, 0.875, 0.34, 48, 1, true).rotateX(Math.PI / 2), bandMat); band.position.z = 0.62; eng.add(band);
    const fan = new THREE.Mesh(new THREE.CircleGeometry(0.58, 40), std('#FFFFFF', 0.35, 0.7, { map: fanTex, envMapIntensity: 0.8 }));
    fan.position.z = 1.15; eng.add(fan); eng.userData.fan = fan;
    const spinner = new THREE.Mesh(new THREE.ConeGeometry(0.17, 0.42, 24), metal); spinner.rotation.x = Math.PI / 2; spinner.position.z = 1.36; eng.add(spinner);
    const nozzle = new THREE.Mesh(new THREE.ConeGeometry(0.44, 0.95, 24, 1, true), darkMetal); nozzle.rotation.x = -Math.PI / 2; nozzle.position.z = -1.85; eng.add(nozzle);
    eng.add(box(0.2, 0.55, 2.4, wingMat, 0, 0.75, -0.5));
    eng.position.set(side * 3.6, -1.18, 1.3);
    plane.add(eng);
    navs.push(eng);
    // navigation lights: red on the left wing (+X when the nose points +Z), green on the right
    const navColor = side > 0 ? new THREE.Color(4, 0.3, 0.3) : new THREE.Color(0.3, 4, 0.8);
    const nav = new THREE.Mesh(new THREE.SphereGeometry(0.12, 12, 8), new THREE.MeshBasicMaterial({ color: navColor }));
    nav.position.set(side * 9.05, -0.45 + 9.05 * 0.07 + 0.02, -2.6); plane.add(nav);
    const strobe = new THREE.Mesh(new THREE.SphereGeometry(0.1, 10, 6), new THREE.MeshBasicMaterial({ color: new THREE.Color(6, 6, 6) }));
    strobe.position.set(side * 9.05, -0.45 + 9.05 * 0.07 + 0.02, -3.3); plane.add(strobe); strobes.push(strobe);
  }
  // vertical fin with the NomadIQ livery
  const finShape = new THREE.Shape(); finShape.moveTo(-5.4, 0.6); finShape.lineTo(-8.0, 4.9); finShape.lineTo(-9.25, 4.9); finShape.lineTo(-9.0, 0.8); finShape.closePath();
  const finGeo = new THREE.ExtrudeGeometry(finShape, { depth: 0.22, bevelEnabled: true, bevelThickness: 0.06, bevelSize: 0.06, bevelSegments: 3 });
  finGeo.rotateY(-Math.PI / 2); finGeo.translate(0.11, 0, 0);
  const finMat = std('#FFFFFF', 0.25, 0.3, { map: cached('fin-normal', () => finTexture(THEMES.normal)), envMapIntensity: 1 });
  plane.add(new THREE.Mesh(finGeo, finMat));
  // holiday extras: a hat on top of the fin and a glowing red nose for Christmas
  const hatH = witchHat(); hatH.name = 'hat-halloween'; hatH.position.set(0, 4.98, -8.62); hatH.scale.setScalar(1.15); hatH.visible = false; plane.add(hatH);
  const hatN = santaHat(); hatN.name = 'hat-navidad'; hatN.position.set(0, 4.98, -8.62); hatN.scale.setScalar(1.15); hatN.visible = false; plane.add(hatN);
  const nose = new THREE.Mesh(new THREE.SphereGeometry(0.34, 20, 14), new THREE.MeshStandardMaterial({ color: '#E0101E', emissive: '#FF1A1A', emissiveIntensity: 2.2, roughness: 0.3 }));
  nose.name = 'rudolph'; nose.position.set(0, -0.02, 8.95); nose.visible = false; plane.add(nose);

  // front passenger door (left side, +X): a curved panel that follows the fuselage and swings forward to open
  const fusR = (z) => z > 6 ? Math.pow(Math.max(0, 1 - ((z - 6) / 3) ** 2), 0.6) : 1;
  const doorPatch = (lift) => {
    const geo = new THREE.CylinderGeometry(1, 1, 0.8, 12, 4, true, Math.PI / 2 - 0.55, 1.1); geo.rotateX(Math.PI / 2);
    const p = geo.attributes.position;
    for (let i = 0; i < p.count; i++) { const z = p.getZ(i) + 6.75, a = Math.atan2(p.getY(i), p.getX(i)), r = fusR(z) + lift; p.setXYZ(i, Math.cos(a) * r, Math.sin(a) * r, z); }
    geo.computeVertexNormals(); return geo;
  };
  const doorTex = canvasTex(256, 128, (g, W, H) => {
    g.fillStyle = '#FFFFFF'; g.fillRect(0, 0, W, H);
    g.strokeStyle = '#8E9AA4'; g.lineWidth = 6; g.strokeRect(6, 6, W - 12, H - 12);
    g.fillStyle = '#1C2733'; g.beginPath(); g.roundRect(W * 0.66, H * 0.36, 34, 34, 12); g.fill();
    g.fillStyle = '#5E6A74'; g.fillRect(W * 0.42, H * 0.2, 30, 10);
  });
  const doorway = new THREE.Mesh(doorPatch(0.006), new THREE.MeshBasicMaterial({ color: '#0C1116', side: THREE.DoubleSide })); plane.add(doorway);
  const doorMat = std('#FFFFFF', 0.3, 0.25, { map: doorTex, side: THREE.DoubleSide, envMapIntensity: 1 });
  const door = new THREE.Group(); door.name = 'door'; door.position.set(fusR(7.15), 0, 7.15); plane.add(door);
  const doorMesh = new THREE.Mesh(doorPatch(0.022), doorMat); doorMesh.position.set(-fusR(7.15), 0, -7.15); door.add(doorMesh);

  // landing gear: two main bogies under the wings and a nose leg; hidden (retracted) while cruising
  const gear = new THREE.Group(); gear.name = 'gear'; gear.position.y = -0.85; gear.visible = false;
  const tire = std('#1B1F24', 0.85, 0, { envMapIntensity: 0.2 });
  const wheelGeo = new THREE.CylinderGeometry(0.3, 0.3, 0.22, 20).rotateZ(Math.PI / 2);
  const noseWheelGeo = new THREE.CylinderGeometry(0.22, 0.22, 0.14, 18).rotateZ(Math.PI / 2);
  for (const side of [1, -1]) {
    const leg = new THREE.Group(); leg.position.set(side * 2.3, 0, -0.9);
    leg.add(cyl(0.09, 0.09, 1.45, 10, metal, 0, -0.72, 0));
    leg.add(box(0.14, 0.12, 1.1, darkMetal, 0, -1.45, 0));
    for (const dz of [0.38, -0.38]) for (const dx of [0.17, -0.17]) leg.add(new THREE.Mesh(wheelGeo, tire).translateX(dx).translateY(-1.45).translateZ(dz));
    gear.add(leg);
  }
  const noseLeg = new THREE.Group(); noseLeg.position.set(0, 0, 6.3);
  noseLeg.add(cyl(0.07, 0.07, 1.52, 10, metal, 0, -0.76, 0));
  for (const dx of [0.13, -0.13]) noseLeg.add(new THREE.Mesh(noseWheelGeo, tire).translateX(dx).translateY(-1.53));
  gear.add(noseLeg);
  plane.add(gear);
  const beacon = new THREE.Mesh(new THREE.SphereGeometry(0.1, 10, 6), new THREE.MeshBasicMaterial({ color: new THREE.Color(5, 0.4, 0.4) }));
  beacon.position.set(0, 1.02, 0.5); plane.add(beacon);
  const tailStrobe = new THREE.Mesh(new THREE.SphereGeometry(0.1, 10, 6), new THREE.MeshBasicMaterial({ color: new THREE.Color(6, 6, 6) }));
  tailStrobe.position.set(0, 0.85, -9.05); plane.add(tailStrobe); strobes.push(tailStrobe);

  // contrails behind each engine
  const trailTex = canvasTex(8, 256, (g, W, H) => { const gr = g.createLinearGradient(0, 0, 0, H); gr.addColorStop(0, 'rgba(255,255,255,0)'); gr.addColorStop(0.12, 'rgba(255,255,255,0.12)'); gr.addColorStop(0.3, 'rgba(255,255,255,0.5)'); gr.addColorStop(0.6, 'rgba(255,255,255,0.3)'); gr.addColorStop(1, 'rgba(255,255,255,0)'); g.fillStyle = gr; g.fillRect(0, 0, W, H); }, { data: true });
  const trailMat = new THREE.MeshBasicMaterial({ color: '#FFFFFF', alphaMap: trailTex, transparent: true, depthWrite: false, side: THREE.DoubleSide, opacity: 0.8 });
  const trails = [];
  for (const side of [1, -1]) {
    const tg = new THREE.CylinderGeometry(0.16, 0.6, 20, 20, 1, true); tg.rotateX(Math.PI / 2);
    const t = new THREE.Mesh(tg, trailMat); t.name = 'trail'; t.position.set(side * 3.6, -1.18, -2.6 - 10); plane.add(t); trails.push(t);
  }

  plane.traverse((o) => { if (o.isMesh && o.material !== trailMat && !o.material.isMeshBasicMaterial) { o.castShadow = true; o.receiveShadow = true; } });
  plane.userData = { engines: navs, strobes, beacon, trailMat, paint, finMat, nacMat, bandMat, doorMat, hats: { halloween: hatH, navidad: hatN }, nose, gear, door };
  return plane;
}
const plane = buildPlane();
/* a copy of the airliner (sharing its geometry) to park at the airport, wheels down and without extras */
const parkedProto = (() => {
  const ud = plane.userData; plane.userData = {};
  const c = plane.clone(); plane.userData = ud;
  for (const n of ['trail', 'hat-halloween', 'hat-navidad', 'rudolph']) { let o; while ((o = c.getObjectByName(n))) o.parent.remove(o); }
  c.getObjectByName('gear').visible = true;
  return c;
})();
plane.position.set(0, ALT, 0);
scene.add(plane);
const landing = new THREE.SpotLight('#FFF3D8', 0, 120, 0.35, 0.6, 1.2);
landing.position.set(0, -1.2, 3); plane.add(landing);
landing.target.position.set(0, -10, 45); plane.add(landing.target);
const planeFill = new THREE.PointLight('#B9CCFF', 0, 40, 1.6); planeFill.position.set(0, 7, -12); plane.add(planeFill);
const planeFill2 = new THREE.PointLight('#FFE2B8', 0, 30, 1.6); planeFill2.position.set(4, 3, 14); plane.add(planeFill2);

/* ---------- holiday decorations around the monuments ---------- */
const decoGroups = { halloween: [], navidad: [] };
const groundDrop = (x, z) => -(x * x + z * z) / (2 * R); // how far the curved ground falls below a monument's base plane
const CITY = ['alcala', 'eiffel', 'bigben', 'coliseo', 'brandeburgo', 'basilio', 'taj', 'tokio'];

// carved pumpkins: ribbed sphere, stem and a face that glows at night
const pumpkinGeo = new THREE.SphereGeometry(1, 24, 16);
const faceGeo = new THREE.SphereGeometry(1.012, 20, 14, Math.PI / 2 - 0.85, 1.7, Math.PI / 2 - 0.62, 1.24);
for (const geo of [pumpkinGeo, faceGeo]) {
  const p = geo.attributes.position;
  for (let i = 0; i < p.count; i++) { const x = p.getX(i), y = p.getY(i), z = p.getZ(i), k = 1 + 0.06 * Math.cos(Math.atan2(z, x) * 10); p.setXYZ(i, x * k, y * 0.74, z * k); }
  geo.computeVertexNormals();
}
const faceTex = canvasTex(256, 192, (g, W, H) => {
  g.fillStyle = '#000'; g.fillRect(0, 0, W, H); g.fillStyle = '#FFF';
  g.beginPath(); g.moveTo(52, 92); g.lineTo(108, 92); g.lineTo(80, 40); g.fill();
  g.beginPath(); g.moveTo(148, 92); g.lineTo(204, 92); g.lineTo(176, 40); g.fill();
  g.beginPath(); g.moveTo(118, 112); g.lineTo(138, 112); g.lineTo(128, 96); g.fill();
  g.beginPath(); g.moveTo(40, 120); g.lineTo(70, 136); g.lineTo(88, 124); g.lineTo(108, 142); g.lineTo(128, 128); g.lineTo(148, 142); g.lineTo(168, 124); g.lineTo(186, 136); g.lineTo(216, 120); g.quadraticCurveTo(128, 200, 40, 120); g.fill();
}, { data: true });
const pumpkinMat = std('#F07A12', 0.55, 0, { envMapIntensity: 0.4 });
const pumpkinFaceMat = std('#2A1200', 0.8, 0, { alphaMap: faceTex, alphaTest: 0.5, emissive: new THREE.Color('#FF8A1A'), emissiveMap: faceTex, emissiveIntensity: 1 });
const stemMat = std('#4E6B2A', 0.8);
function pumpkin(sc) {
  const g = new THREE.Group();
  g.add(new THREE.Mesh(pumpkinGeo, pumpkinMat), new THREE.Mesh(faceGeo, pumpkinFaceMat));
  const stem = cyl(0.07, 0.12, 0.35, 6, stemMat, 0, 0.82, 0); stem.rotation.z = 0.25; g.add(stem);
  g.scale.setScalar(sc); g.position.y = 0.72 * sc;
  return shadowAll(g);
}
// bats: a body and two scalloped wings that flap; they circle the tall monuments
const wingShape = new THREE.Shape();
[[0, 0.12], [0.3, 0.2], [0.7, 0.24], [0.98, 0.08], [0.82, -0.08], [0.66, 0.0], [0.5, -0.12], [0.33, -0.03], [0.16, -0.1], [0, -0.04]].forEach(([x, y], i) => i ? wingShape.lineTo(x, y) : wingShape.moveTo(x, y));
const wingGeoR = new THREE.ShapeGeometry(wingShape).rotateX(Math.PI / 2), wingGeoL = wingGeoR.clone().scale(-1, 1, 1);
const batMat = std('#16101C', 0.7, 0, { side: THREE.DoubleSide, envMapIntensity: 0.2 });
const bats = [];
function bat() {
  const g = new THREE.Group();
  const body = new THREE.Mesh(new THREE.SphereGeometry(0.12, 8, 6), batMat); body.scale.set(0.8, 0.8, 1.5); g.add(body);
  g.add(new THREE.Mesh(new THREE.SphereGeometry(0.08, 8, 6), batMat).translateZ(0.17).translateY(0.03));
  const wl = new THREE.Mesh(wingGeoL, batMat), wr = new THREE.Mesh(wingGeoR, batMat); g.add(wl, wr);
  g.userData = { wl, wr }; g.scale.setScalar(1.7);
  return g;
}
// a decorated Christmas tree
const xmasGreen = std('#1F6B3A', 0.8, 0, { envMapIntensity: 0.3 }), trunkMat = std('#5A4034', 0.9);
const BULBS = [new THREE.Color(3, 0.35, 0.35), new THREE.Color(3, 2.3, 0.5), new THREE.Color(0.5, 1.4, 3), new THREE.Color(2.6, 2.6, 2.6)];
const bulbMats = BULBS.map((c) => new THREE.MeshBasicMaterial({ color: c }));
const starMat = new THREE.MeshBasicMaterial({ color: new THREE.Color(3.2, 2.5, 0.7) });
function xmasTree(sc) {
  const g = new THREE.Group();
  g.add(cyl(0.25, 0.3, 1, 8, trunkMat, 0, 0.5, 0));
  [[2.2, 2.6, 1.9], [1.7, 2.2, 3.1], [1.1, 1.9, 4.2]].forEach(([r, h, y]) => g.add(new THREE.Mesh(new THREE.ConeGeometry(r, h, 12), xmasGreen).translateY(y)));
  for (let i = 0; i < 18; i++) { const t = i / 18, y = 1.2 + t * 3.6, r = 2.1 * (1 - t * 0.78) * 0.92, a = i * 2.4; g.add(new THREE.Mesh(new THREE.SphereGeometry(0.13, 8, 6), bulbMats[i % 4]).translateX(Math.cos(a) * r).translateY(y).translateZ(Math.sin(a) * r)); }
  const star = new THREE.Mesh(new THREE.OctahedronGeometry(0.42), starMat); star.position.y = 5.45; star.scale.set(1, 1.2, 0.45); g.add(star);
  g.scale.setScalar(sc);
  return shadowAll(g);
}
// string lights hugging each city monument (local coordinates, turned into planet coordinates below)
function festivePoints(key) {
  const pts = [], add = (x, y, z) => pts.push(v3(x, y, z));
  const helix = (cx, cz, y0, y1, rFn, turns, step = 0.55) => {
    let a = 0; const top = turns * Math.PI * 2;
    while (a <= top) { const t = a / top, y = y0 + (y1 - y0) * t, r = rFn(y); add(cx + Math.cos(a) * r, y, cz + Math.sin(a) * r); a += step / Math.max(r, 0.3); }
  };
  const garland = (ax, ay, az, bx, by, bz, sag, step = 0.5) => { const d = Math.hypot(bx - ax, by - ay, bz - az), n = Math.max(2, Math.ceil(d / step)); for (let i = 0; i <= n; i++) { const t = i / n; add(ax + (bx - ax) * t, ay + (by - ay) * t - sag * Math.sin(Math.PI * t), az + (bz - az) * t); } };
  const scallops = (x0, x1, y, z, sag, seg = 2.4) => { const n = Math.max(1, Math.round((x1 - x0) / seg)), w = (x1 - x0) / n; for (let i = 0; i < n; i++) garland(x0 + i * w, y, z, x0 + (i + 1) * w, y, z, sag); };
  const loopRect = (hx, hz, y, sag) => { scallops(-hx, hx, y, hz, sag); scallops(-hx, hx, y, -hz, sag); for (const sx of [-hx, hx]) { const n = Math.max(1, Math.round(2 * hz / 2.4)), w = 2 * hz / n; for (let i = 0; i < n; i++) garland(sx, y, -hz + i * w, sx, y, -hz + (i + 1) * w, sag); } };
  const lerpTable = (tab) => (y) => { let i = 0; while (i < tab.length - 2 && y > tab[i + 1][0]) i++; const [y0, r0] = tab[i], [y1, r1] = tab[i + 1]; return r0 + (r1 - r0) * THREE.MathUtils.clamp((y - y0) / (y1 - y0), 0, 1); };
  switch (key) {
    case 'eiffel': case 'tokio': helix(0, 0, 0.8, 23.6, lerpTable([[0, 5.6], [6.3, 3.3], [6.8, 2.75], [11.6, 1.75], [12, 1.75], [23.6, 0.55]]), 11, 0.6); break;
    case 'bigben': helix(0, 0, 0.6, 17.2, () => 2.05, 7); garland(1.4, 8.45, 0, 23, 8.45, 0, 0, 0.5); scallops(1.6, 21.4, 6.6, 2.6, 0.3); helix(23.4, 0, 0.6, 15, () => 2.25, 6); break;
    case 'alcala': scallops(-7.2, 7.2, 7.65, 1.5, 0.35); scallops(-7.2, 7.2, 7.65, -1.5, 0.35); garland(-3.4, 9.15, 1.2, 0, 10.65, 1.2, 0, 0.45); garland(0, 10.65, 1.2, 3.4, 9.15, 1.2, 0, 0.45); break;
    case 'coliseo': for (const y of [2.55, 5.05]) { const n = 150; for (let i = 0; i < n; i++) { const a = (i / n) * Math.PI * 2; add(Math.cos(a) * 10.55, y - 0.28 * Math.abs(Math.sin(a * 14)), Math.sin(a) * 8.12); } } break;
    case 'brandeburgo': scallops(-6.7, 6.7, 7.95, 1.85, 0.4); scallops(-6.7, 6.7, 7.95, -1.85, 0.4); for (const x of [-5.6, -3.4, -1.15, 1.15, 3.4, 5.6]) for (const z of [1.1, -1.1]) helix(x, z, 0.7, 6.5, () => 0.5, 3); break;
    case 'basilio': helix(0, 0, 2.6, 13.2, lerpTable([[2.6, 2.05], [7.4, 2.05], [7.5, 1.9], [13.2, 0.3]]), 8); loopRect(5.2, 5.2, 2.65, 0.35); helix(10, -9, 0.5, 9, () => 1.7, 4); garland(-16.5, 3.9, -8.3, 16.5, 3.9, -8.3, 0, 0.5); break;
    case 'taj': for (const x of [6.9, -6.9]) for (const z of [6.9, -6.9]) helix(x, z, 1.1, 10.9, () => 0.62, 5); loopRect(7.85, 7.85, 1.06, 0); break;
    case 'piramides': for (const sx of [1, -1]) for (const sz of [1, -1]) garland(0, 8.1, 0, sx * 6.5, 0.1, sz * 6.5, 0, 0.5); break;
    default: break;
  }
  return pts;
}
const festive = [];
ROUTE.forEach((m) => {
  const lb = m.lb, cx = (lb.min.x + lb.max.x) / 2, cz = (lb.min.z + lb.max.z) / 2;
  if (m.key !== 'fuji') {
    const hg = new THREE.Group();
    const n = THREE.MathUtils.clamp(Math.round((lb.max.x - lb.min.x) / 4), 3, 7), fz = Math.min(lb.max.z + 1.4, 24);
    for (let i = 0; i < n; i++) {
      const x = lb.min.x + 1 + ((lb.max.x - lb.min.x - 2) * (i + 0.5)) / n, z = fz + (rand() - 0.5) * 1.2, sc = 0.9 + rand() * 0.8;
      const pk = pumpkin(sc); pk.position.x = x; pk.position.z = z; pk.position.y += groundDrop(x, z); pk.rotation.y = (rand() - 0.5) * 0.8; hg.add(pk);
    }
    if (m.height > 8) {
      for (let i = 0; i < 6; i++) {
        const b = bat(); hg.add(b);
        bats.push({ b, m, cx, cz, r: Math.max(lb.max.x - lb.min.x, lb.max.z - lb.min.z) * 0.32 + 3 + rand() * 3, h: Math.min(m.height, 22) * (0.55 + rand() * 0.4), a0: rand() * Math.PI * 2, sp: (0.7 + rand() * 0.6) * (rand() < 0.5 ? 1 : -1) });
      }
    }
    m.obj.add(hg); decoGroups.halloween.push(hg);
  }
  if (CITY.includes(m.key)) {
    const ng = new THREE.Group();
    for (const x of [lb.min.x - 2.6, lb.max.x + 2.6]) { const z = lb.max.z - 1.5, t = xmasTree(0.95); t.position.set(x, groundDrop(x, z), z); ng.add(t); }
    m.obj.add(ng); decoGroups.navidad.push(ng);
  }
  for (const p of festivePoints(m.key)) festive.push(p.applyMatrix4(m.obj.matrix));
});
const festiveLights = new THREE.InstancedMesh(new THREE.SphereGeometry(0.15, 6, 4), new THREE.MeshBasicMaterial({ color: '#FFFFFF' }), festive.length);
festive.forEach((p, i) => { dummy.position.copy(p); dummy.rotation.set(0, 0, 0); dummy.scale.setScalar(1); dummy.updateMatrix(); festiveLights.setMatrixAt(i, dummy.matrix); festiveLights.setColorAt(i, BULBS[i % 4]); });
earth.add(festiveLights);
const LIGHT_PALETTE = {
  halloween: [new THREE.Color(3.2, 1.2, 0.1), new THREE.Color(1.6, 0.35, 3.2), new THREE.Color(3.2, 1.9, 0.3)],
  navidad: BULBS
};
function blinkLights(step) {
  const pal = LIGHT_PALETTE[theme]; if (!pal) return;
  for (let i = 0; i < festive.length; i++) festiveLights.setColorAt(i, pal[(i + step) % pal.length]);
  festiveLights.instanceColor.needsUpdate = true;
}
// falling snow that follows the camera (Navidad only)
const SNOW_N = 2200, snowPos = new Float32Array(SNOW_N * 3);
for (let i = 0; i < SNOW_N; i++) { snowPos[i * 3] = (rand() - 0.5) * 90; snowPos[i * 3 + 1] = rand() * 40 - 6; snowPos[i * 3 + 2] = (rand() - 0.5) * 90; }
const snowGeo = new THREE.BufferGeometry(); snowGeo.setAttribute('position', new THREE.BufferAttribute(snowPos, 3));
const dotTex = canvasTex(32, 32, (g, W) => { const gr = g.createRadialGradient(W / 2, W / 2, 0, W / 2, W / 2, W / 2); gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.5, 'rgba(255,255,255,0.8)'); gr.addColorStop(1, 'rgba(255,255,255,0)'); g.fillStyle = gr; g.fillRect(0, 0, W, W); });
const snow = new THREE.Points(snowGeo, new THREE.PointsMaterial({ color: '#FFFFFF', map: dotTex, size: 0.32, transparent: true, depthWrite: false, opacity: 0.95 }));
snow.visible = false; snow.frustumCulled = false; scene.add(snow);

/* ---------- the airport in Tokyo (Haneda) ---------- */
const airGrass = std(THEMES.normal.grass, 0.95, 0, { envMapIntensity: 0.1 });
{
  const base = new THREE.Mesh(conform(new THREE.PlaneGeometry(156, 170, 39, 34).rotateX(-Math.PI / 2)), airGrass); base.receiveShadow = true;
  place(base, RWY_START + 32 / R, 0, 0, 0.03);
  const rwyTex = canvasTex(256, 1024, (g, W, H) => {
    g.fillStyle = '#3B4047'; g.fillRect(0, 0, W, H);
    const rr = mkRand(34);
    for (let i = 0; i < 2600; i++) { g.fillStyle = `rgba(${rr() < 0.5 ? '255,255,255' : '0,0,0'},${rr() * 0.07})`; g.fillRect(rr() * W, rr() * H, 2 + rr() * 5, 2 + rr() * 5); }
    for (let i = 0; i < 40; i++) { g.fillStyle = 'rgba(15,15,18,0.22)'; g.fillRect(W / 2 + (rr() - 0.5) * 70, 140 + rr() * 260, 3 + rr() * 4, 30 + rr() * 90); }
    g.fillStyle = '#ECEFF1';
    g.fillRect(8, 0, 5, H); g.fillRect(W - 13, 0, 5, H);
    for (let y = 150; y < H - 150; y += 40) g.fillRect(W / 2 - 2, y, 4, 22);
    for (const y0 of [10, H - 62]) for (let i = 0; i < 8; i++) g.fillRect(22 + i * 27 + (i >= 4 ? 8 : 0), y0, 13, 52);
    for (const [y, flip] of [[260, false], [H - 260, true]]) {
      for (const k of [0, 1, 2]) { const yy = flip ? y - 40 - k * 46 : y + 40 + k * 46; g.fillRect(44, yy, 8, 24); g.fillRect(58, yy, 8, 24); g.fillRect(W - 52, yy, 8, 24); g.fillRect(W - 66, yy, 8, 24); }
      g.fillRect(70, flip ? y - 330 : y + 230, 24, 80); g.fillRect(W - 94, flip ? y - 330 : y + 230, 24, 80);
    }
    g.font = '800 62px Manrope, Arial, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.save(); g.translate(W / 2, 112); g.rotate(Math.PI); g.fillText('34R', 0, 0); g.restore();
    g.fillText('16L', W / 2, H - 112);
  });
  const rwy = new THREE.Group();
  const rwyMesh = new THREE.Mesh(conform(new THREE.PlaneGeometry(RWY_W, RWY_LEN, 4, 40).rotateX(-Math.PI / 2)), std('#FFFFFF', 0.9, 0, { map: rwyTex, envMapIntensity: 0.1 }));
  rwyMesh.receiveShadow = true; rwy.add(rwyMesh);
  // edge, threshold and end lights
  const lightPts = [];
  for (let z = -40; z <= 40; z += 5) for (const x of [-RWY_W / 2 - 0.4, RWY_W / 2 + 0.4]) lightPts.push([x, z, 0]);
  for (let x = -9; x <= 9; x += 1.5) { lightPts.push([x, -40.6, 1]); lightPts.push([x, 40.6, 2]); }
  const rl = new THREE.InstancedMesh(new THREE.SphereGeometry(0.13, 6, 4), new THREE.MeshBasicMaterial({ color: '#FFFFFF' }), lightPts.length);
  const RCOL = [new THREE.Color(2.6, 2.3, 1.7), new THREE.Color(0.3, 2.8, 0.7), new THREE.Color(2.8, 0.3, 0.3)];
  lightPts.forEach(([x, z, c], i) => { dummy.position.set(x, 0.12 + groundDrop(x, z), z); dummy.rotation.set(0, 0, 0); dummy.updateMatrix(); rl.setMatrixAt(i, dummy.matrix); rl.setColorAt(i, RCOL[c]); });
  rwy.add(rl);
  place(rwy, RWY_START + RWY_LEN / 2 / R, 0, 0, 0.06);
  // apron, terminal with glass facade, jet bridges, parked planes and the control tower (all on the far side, -X)
  const concrete = std('#B7B9B6', 0.9, 0, { envMapIntensity: 0.1 });
  const apron = new THREE.Mesh(conform(new THREE.PlaneGeometry(26, 70, 6, 14).rotateX(-Math.PI / 2)), concrete); apron.receiveShadow = true;
  place(apron, RWY_START + 60 / R, -31, 0, 0.05);
  const taxi = new THREE.Mesh(conform(new THREE.PlaneGeometry(14, 8, 4, 2).rotateX(-Math.PI / 2)), concrete); place(taxi, RWY_START + 36 / R, -15, 0, 0.045);
  const glassTex = canvasTex(512, 128, (g, W, H) => { g.fillStyle = '#7FA6C2'; g.fillRect(0, 0, W, H); const gr = g.createLinearGradient(0, 0, 0, H); gr.addColorStop(0, 'rgba(255,255,255,0.35)'); gr.addColorStop(1, 'rgba(20,40,60,0.35)'); g.fillStyle = gr; g.fillRect(0, 0, W, H); g.fillStyle = '#E4E8EB'; for (let x = 0; x < W; x += 32) g.fillRect(x, 0, 3, H); g.fillRect(0, H * 0.48, W, 4); }, { repeat: [6, 1] });
  const term = new THREE.Group();
  term.add(box(12, 5, 52, std('#FFFFFF', 0.15, 0.4, { map: glassTex, envMapIntensity: 0.8 }), 0, 2.5, 0));
  const roofT = box(15, 0.6, 55, std('#DDE2E6', 0.4, 0.5), 0.8, 5.3, 0); term.add(roofT);
  term.add(box(10, 1.2, 4, std('#E8ECEF', 0.5, 0.2), 0, 6.2, 0));
  const sign = canvasTex(512, 96, (g, W, H) => { g.fillStyle = '#123A6B'; g.fillRect(0, 0, W, H); g.fillStyle = '#FFFFFF'; g.font = '800 54px Manrope, Arial, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(`${NQ.to.city} ${NQ.to.code}`.toUpperCase().slice(0, 18), W / 2, H / 2 + 2); });
  const signM = new THREE.Mesh(new THREE.PlaneGeometry(9, 1.7), std('#FFFFFF', 0.5, 0, { map: sign })); signM.position.set(6.4, 6.6, 0); signM.rotation.y = Math.PI / 2; term.add(signM);
  const bridgeMat = std('#C9CED2', 0.5, 0.4);
  for (const z of [-11, 11]) { const jb = box(6.5, 1.3, 1.4, bridgeMat, 9.2, 2.6, z); term.add(jb); term.add(cyl(0.18, 0.18, 2.2, 8, bridgeMat, 11.5, 1.1, z)); }
  shadowAll(term);
  place(term, RWY_START + 60 / R, -52, 0, 0);
  for (const [dz, x] of [[-11, -34.5], [11, -34.5]]) { const pp = dz < 0 ? parkedProto : parkedProto.clone(); place(pp, RWY_START + (60 + dz) / R, x, -Math.PI / 2, GROUND_Y); }
  const tower = new THREE.Group();
  tower.add(cyl(0.9, 1.3, 15, 16, std('#E6E8E9', 0.6), 0, 7.5, 0));
  tower.add(cyl(2.1, 1.5, 1.2, 16, std('#E6E8E9', 0.6), 0, 15.4, 0));
  tower.add(cyl(2.2, 2.0, 2.0, 16, std('#2C4A60', 0.1, 0.7, { envMapIntensity: 1 }), 0, 17, 0));
  tower.add(cyl(2.5, 2.4, 0.4, 16, std('#E6E8E9', 0.6), 0, 18.2, 0));
  tower.add(cyl(0.05, 0.05, 3, 6, std('#C8102E', 0.5), 0, 19.9, 0));
  shadowAll(tower);
  place(tower, RWY_START + 98 / R, -26, 0, 0);
}

/* ---------- air stairs, apron bus, passengers and confetti (world coordinates around the stopped plane) ---------- */
const DOOR_Z = 6.75;
function stairTruck() {
  const g = new THREE.Group();
  const yellow = std('#F2C230', 0.5, 0.2), grey = std('#8C969E', 0.6, 0.5), tireM = std('#1B1F24', 0.85), glass = std('#2C4A60', 0.1, 0.6, { envMapIntensity: 1 });
  g.add(box(2.9, 0.3, 1.3, yellow, 2.75, 0.45, DOOR_Z));
  g.add(box(1.1, 0.75, 1.25, yellow, 2.0, 0.95, DOOR_Z), box(0.06, 0.4, 1.0, glass, 1.44, 1.05, DOOR_Z));
  const wg = new THREE.CylinderGeometry(0.26, 0.26, 0.18, 16).rotateX(Math.PI / 2);
  for (const x of [1.9, 3.8]) for (const dz of [0.66, -0.66]) g.add(new THREE.Mesh(wg, tireM).translateX(x).translateY(0.26).translateZ(DOOR_Z + dz));
  g.add(box(0.98, 0.08, 1.05, grey, 1.47, 2.01, DOOR_Z));
  const N = 12;
  for (let i = 0; i < N; i++) { const t = (i + 0.5) / N; g.add(box(0.3, 0.05, 0.92, grey, 1.95 + 3.3 * t, 2.05 - 2.0 * t - 0.03, DOOR_Z)); }
  for (const dz of [-0.5, 0.5]) {
    g.add(beam(v3(1.95, 1.98, DOOR_Z + dz), v3(5.25, -0.02, DOOR_Z + dz), 0.07, 0.07, yellow));
    g.add(beam(v3(1.95, 2.58, DOOR_Z + dz), v3(5.25, 0.58, DOOR_Z + dz), 0.025, 0.025, grey));
    for (let k = 0; k <= 3; k++) { const t = k / 3, x = 1.95 + 3.3 * t, y = 2.05 - 2 * t; g.add(beam(v3(x, y, DOOR_Z + dz), v3(x, y + 0.56, DOOR_Z + dz), 0.02, 0.02, grey)); }
    g.add(beam(v3(1.0, 2.6, DOOR_Z + dz), v3(1.95, 2.6, DOOR_Z + dz), 0.025, 0.025, grey));
    g.add(beam(v3(1.05, 2.05, DOOR_Z + dz), v3(1.05, 2.6, DOOR_Z + dz), 0.02, 0.02, grey));
  }
  g.add(beam(v3(3.0, 0.6, DOOR_Z), v3(2.6, 1.6, DOOR_Z), 0.08, 0.08, grey));
  return shadowAll(g);
}
const stairs = stairTruck(); stairs.visible = false; scene.add(stairs);
const bus = (() => {
  const g = new THREE.Group();
  const win = canvasTex(512, 128, (c, W, H) => { c.fillStyle = '#F4F6F8'; c.fillRect(0, 0, W, H); c.fillStyle = '#2B3A48'; c.fillRect(0, 18, W, 54); c.fillStyle = '#3DDC97'; c.fillRect(0, 96, W, 14); c.fillStyle = '#1C3F94'; c.font = '800 22px Manrope, Arial'; c.fillText('NomadIQ · APRON', 16, 92); for (let x = 0; x < W; x += 64) { c.fillStyle = '#F4F6F8'; c.fillRect(x, 18, 5, 54); } });
  const bodyM = std('#FFFFFF', 0.4, 0.2, { map: win });
  g.add(box(1.5, 1.5, 7, bodyM, 0, 0.95, 0), box(1.45, 0.08, 6.9, std('#D5DADE', 0.5), 0, 1.74, 0));
  g.add(box(0.04, 1.05, 1.0, std('#22303C', 0.2, 0.5), -0.76, 0.85, -1.2));
  const wg = new THREE.CylinderGeometry(0.28, 0.28, 0.2, 16).rotateZ(Math.PI / 2);
  for (const z of [-2.4, 2.4]) for (const x of [0.7, -0.7]) g.add(new THREE.Mesh(wg, std('#1B1F24', 0.85)).translateX(x).translateY(0.28).translateZ(z));
  g.position.set(13.6, 0, 9.6); return shadowAll(g);
})();
bus.visible = false; scene.add(bus);

const boardingPass = canvasTex(512, 230, (g, W, H) => {
  g.fillStyle = '#FFFFFF'; g.beginPath(); g.roundRect(0, 0, W, H, 22); g.fill();
  const gr = g.createLinearGradient(0, 0, W, 0); gr.addColorStop(0, '#1C3F94'); gr.addColorStop(1, '#3DDC97');
  g.fillStyle = gr; g.beginPath(); g.roundRect(0, 0, W, 58, [22, 22, 0, 0]); g.fill();
  g.fillStyle = '#FFFFFF'; g.font = '800 30px Manrope, Arial'; g.textBaseline = 'middle'; g.fillText('NomadIQ', 22, 30);
  g.font = '700 16px Manrope, Arial'; g.textAlign = 'right'; g.fillText(T.boardingPass.toUpperCase(), W - 22, 31); g.textAlign = 'left';
  g.fillStyle = '#0B1217'; g.font = '800 64px Manrope, Arial'; g.fillText(NQ.from.code, 22, 112); g.fillText(NQ.to.code, 250, 112);
  g.strokeStyle = '#1C3F94'; g.lineWidth = 5; g.beginPath(); g.moveTo(170, 112); g.lineTo(232, 112); g.moveTo(218, 100); g.lineTo(234, 112); g.lineTo(218, 124); g.stroke();
  g.fillStyle = '#5A6872'; g.font = '700 18px Manrope, Arial'; g.fillText(T.passenger.toUpperCase(), 22, 164); g.fillText(T.flight.toUpperCase(), 190, 164); g.fillText(T.seat.toUpperCase(), 290, 164);
  g.fillStyle = '#0B1217'; g.font = '800 24px Manrope, Arial'; g.fillText(String(NQ.passenger || 'NomadIQ').toUpperCase().slice(0, 14), 22, 196); g.fillText('NQ 2026', 190, 196); g.fillText('12A', 290, 196);
  g.setLineDash([8, 8]); g.strokeStyle = '#C3CCD2'; g.lineWidth = 3; g.beginPath(); g.moveTo(392, 66); g.lineTo(392, H - 8); g.stroke(); g.setLineDash([]);
  for (let x = 410, i = 0; x < W - 16; x += 4 + (i % 3), i++) { g.fillStyle = '#0B1217'; g.fillRect(x, 80, (i * 7) % 3 + 1, 120); }
});
const WALK = 1.3;
const PAX = [
  { shirt: '#2F6FD6', pants: '#2B2F3A', skin: '#E8B894', hair: '#3A2A1E', bag: 'roll' },
  { shirt: '#E2574C', pants: '#3B3F4A', skin: '#C68B62', hair: '#1E1A17', bag: 'back' },
  { shirt: '#3DDC97', pants: '#2E3A5A', skin: '#F0C8A6', hair: '#6B3E1F', bag: 'none', hero: true },
  { shirt: '#F2C230', pants: '#4A4F5A', skin: '#8D5A3B', hair: '#151210', bag: 'roll' },
  { shirt: '#9A6BD8', pants: '#2B2F3A', skin: '#E8B894', hair: '#B8B2A8', bag: 'back' },
  { shirt: '#F4F4F2', pants: '#1F3A5F', skin: '#D9A07A', hair: '#2A1E16', bag: 'roll' }
];
function person(o) {
  const g = new THREE.Group();
  const M = (c) => std(c, 0.75, 0, { envMapIntensity: 0.4 });
  const shirt = M(o.shirt), pants = M(o.pants), skin = M(o.skin), hair = M(o.hair), shoe = M('#1E2226');
  const legs = [-1, 1].map((sd) => { const hip = new THREE.Group(); hip.position.set(sd * 0.07, 0.46, 0); const leg = new THREE.Mesh(new THREE.CapsuleGeometry(0.055, 0.34, 4, 8), pants); leg.position.y = -0.21; hip.add(leg, box(0.09, 0.05, 0.16, shoe, 0, -0.44, 0.03)); g.add(hip); return hip; });
  const torso = new THREE.Mesh(new THREE.CapsuleGeometry(0.13, 0.26, 4, 12), shirt); torso.position.y = 0.64; torso.scale.set(1, 1, 0.72); g.add(torso);
  g.add(new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.045, 0.06, 8), skin).translateY(0.83));
  const head = new THREE.Group(); head.position.y = 0.94; g.add(head);
  head.add(new THREE.Mesh(new THREE.SphereGeometry(0.11, 18, 14), skin));
  head.add(new THREE.Mesh(new THREE.SphereGeometry(0.118, 18, 10, 0, Math.PI * 2, 0, Math.PI * 0.52), hair).translateY(0.012).translateZ(-0.008));
  const arms = [-1, 1].map((sd) => { const sh = new THREE.Group(); sh.position.set(sd * 0.175, 0.78, 0); const arm = new THREE.Mesh(new THREE.CapsuleGeometry(0.04, 0.3, 4, 8), shirt); arm.position.y = -0.17; sh.add(arm, new THREE.Mesh(new THREE.SphereGeometry(0.045, 10, 8), skin).translateY(-0.37)); g.add(sh); return sh; });
  if (o.bag === 'back') g.add(box(0.24, 0.3, 0.12, M('#3A4654'), 0, 0.66, -0.14));
  if (o.bag === 'roll') { const sb = new THREE.Group(); sb.add(box(0.22, 0.32, 0.12, M(o.shirt === '#F4F4F2' ? '#C8102E' : '#2B3A48'), 0, 0.2, 0), cyl(0.012, 0.012, 0.32, 6, M('#9AA4AC'), 0, 0.52, 0)); sb.position.set(-0.24, 0, -0.26); sb.rotation.x = -0.35; g.add(sb); }
  const P = { g, legs, arms, head, o };
  if (o.hero) {
    // Noelia: long hair, a big happy face and her boarding pass
    head.add(new THREE.Mesh(new THREE.CapsuleGeometry(0.075, 0.16, 4, 10), hair).translateY(-0.08).translateZ(-0.07));
    const black = new THREE.MeshBasicMaterial({ color: '#1A1412' });
    for (const sd of [-1, 1]) {
      head.add(new THREE.Mesh(new THREE.SphereGeometry(0.016, 8, 6), black).translateX(sd * 0.04).translateY(0.012).translateZ(0.1));
      head.add(new THREE.Mesh(new THREE.SphereGeometry(0.02, 8, 6), new THREE.MeshBasicMaterial({ color: '#F28C8C', transparent: true, opacity: 0.8 })).translateX(sd * 0.065).translateY(-0.025).translateZ(0.085));
    }
    const smile = new THREE.Mesh(new THREE.TorusGeometry(0.04, 0.01, 6, 14, Math.PI), black); smile.rotation.z = Math.PI; smile.position.set(0, -0.025, 0.1); head.add(smile);
    const ticket = new THREE.Group(); ticket.position.set(0, -0.42, 0.03);
    ticket.add(new THREE.Mesh(new THREE.PlaneGeometry(0.38, 0.17), new THREE.MeshStandardMaterial({ map: boardingPass, roughness: 0.6, side: THREE.DoubleSide, transparent: true, alphaTest: 0.1 })).translateY(-0.06));
    arms[0].add(ticket); P.ticket = ticket;
    const hh = witchHat(); hh.scale.setScalar(0.13); hh.position.y = 0.09; hh.rotation.x = -0.15; hh.visible = false; head.add(hh);
    const hn = santaHat(); hn.scale.setScalar(0.17); hn.position.y = 0.07; hn.rotation.x = -0.15; hn.visible = false; head.add(hn);
    P.hats = { halloween: hh, navidad: hn };
  }
  g.scale.setScalar(0.85);
  shadowAll(g);
  g.visible = false; scene.add(g);
  return P;
}
const pax = PAX.map((o, i) => {
  const P = person(o);
  const zOff = [0, 0.55, 0, 1.1, 0.25, -0.5][i];
  P.path = [v3(0.3, 2.05, DOOR_Z), v3(1.95, 2.05, DOOR_Z), v3(5.25, 0.03, DOOR_Z), v3(6.6, 0, 7.2), o.hero ? v3(8.6, 0, 9.6) : v3(12.6, 0, 7.6 + zOff)];
  P.cum = [0]; for (let k = 1; k < P.path.length; k++) P.cum.push(P.cum[k - 1] + P.path[k].distanceTo(P.path[k - 1]));
  P.len = P.cum[P.cum.length - 1];
  P.start = 16.8 + 1.1 * i;
  P.tArrive = P.start + P.len / WALK;
  return P;
});
const hero = pax.find((P) => P.o.hero);
const HERO_BOTTOM = hero.start + hero.cum[2] / WALK; // when Noelia steps off the stairs
const HERO_CAM = v3(1.0, 0.95, 1.7);
const HERO_YAW = Math.atan2(HERO_CAM.x, HERO_CAM.z);
const heroLight = new THREE.PointLight('#FFF1E0', 0, 9, 1.4); scene.add(heroLight);
const CONF_N = 240;
const confetti = new THREE.InstancedMesh(new THREE.PlaneGeometry(0.035, 0.055), new THREE.MeshBasicMaterial({ side: THREE.DoubleSide }), CONF_N);
const confData = [];
{ const cc = [new THREE.Color('#3DDC97'), new THREE.Color('#6CA8FF'), new THREE.Color('#FF8A65'), new THREE.Color('#F2C230'), new THREE.Color('#FF5C8A'), new THREE.Color('#FFFFFF')];
  for (let i = 0; i < CONF_N; i++) { confData.push([(rand() - 0.5) * 3.4, -1.8 + rand() * 2.2, rand(), 0.45 + rand() * 0.45, rand() * 6, rand() * 6]); confetti.setColorAt(i, cc[i % cc.length].clone().multiplyScalar(1.15)); } }
confetti.visible = false; confetti.frustumCulled = false; scene.add(confetti);

const tmpP = new THREE.Vector3(), tmpD = new THREE.Vector3();
function pathAt(P, s) {
  let i = 0; while (i < P.cum.length - 2 && s > P.cum[i + 1]) i++;
  const a = P.path[i], b = P.path[i + 1], f = THREE.MathUtils.clamp((s - P.cum[i]) / (P.cum[i + 1] - P.cum[i]), 0, 1);
  return { pos: tmpP.copy(a).lerp(b, f), dir: tmpD.subVectors(b, a) };
}
let endShown = false;
/* everything after touchdown is a pure function of L (seconds since the approach began), so any moment can be previewed */
function updateLanding(L) {
  const on = L >= 0, ud = plane.userData;
  ud.gear.visible = on && L > 2;
  if (ud.gear.visible) ud.gear.scale.set(1, Math.max(0.05, smooth((L - 2) / 2)), 1);
  ud.door.rotation.y = on ? -1.9 * smooth((L - 15.5) / 1) : 0;
  stairs.visible = on && L > 13.2;
  stairs.position.x = 12 * (1 - smooth((L - 13.5) / 2.5));
  bus.visible = on && L > 12;
  let heroU = -1;
  for (const P of pax) {
    const s = (L - P.start) * WALK;
    if (!on || s < 0 || (!P.o.hero && s >= P.len)) { P.g.visible = false; continue; }
    P.g.visible = true;
    const st = pathAt(P, Math.min(s, P.len));
    P.g.position.copy(st.pos);
    let yaw = Math.atan2(st.dir.x, st.dir.z);
    const ph = s * 5.2, sw = Math.sin(ph);
    P.legs[0].rotation.set(sw * 0.55, 0, 0); P.legs[1].rotation.set(-sw * 0.55, 0, 0);
    P.arms[0].rotation.set(P.o.bag === 'roll' ? 0.3 : -sw * 0.4, 0, 0); P.arms[1].rotation.set(sw * 0.4, 0, 0);
    P.g.position.y += Math.abs(sw) * 0.02;
    if (P.o.hero && s >= P.len) {
      const u = L - P.tArrive; heroU = u;
      P.legs[0].rotation.set(0, 0, 0); P.legs[1].rotation.set(0, 0, 0);
      yaw = yaw + (HERO_YAW - yaw) * smooth(u / 0.6);
      const up = smooth((u - 0.3) / 0.5);
      P.arms[0].rotation.set(-2.9 * up, 0, -0.15 * up);
      P.ticket.rotation.x = Math.PI * up;
      P.arms[1].rotation.set(0, 0, 2.5 * smooth((u - 0.5) / 0.5) + 0.3 * Math.sin(time * 10) * smooth((u - 1) / 0.3));
      const w = (u - 1) % 3.5, hop = u > 1 && w < 1.6 ? 0.2 * Math.abs(Math.sin((w * Math.PI) / 0.8)) : 0;
      P.g.position.y = hop; P.legs[0].rotation.z = -hop * 1.2; P.legs[1].rotation.z = hop * 1.2;
    } else if (P.o.hero && P.ticket) P.ticket.rotation.x = 0;
    P.g.rotation.y = yaw;
  }
  confetti.visible = heroU >= 0.8;
  if (confetti.visible) {
    const t = heroU - 0.8, hx = hero.g.position.x, hz = hero.g.position.z;
    confData.forEach(([bx, bz, ph, v, s1, s2], i) => {
      const y = 3.0 - ((t * v + ph * 3) % 3);
      dummy.position.set(hx + bx + Math.sin(t * 1.3 + s1) * 0.25, y, hz + bz);
      dummy.rotation.set(t * s1, t * s2, 0); dummy.scale.setScalar(1); dummy.updateMatrix(); confetti.setMatrixAt(i, dummy.matrix);
    });
    confetti.instanceMatrix.needsUpdate = true;
  }
  if (heroU >= 1.2 && !endShown) { endShown = true; $('arrive').hidden = false; document.body.classList.add('ending'); tellApp('landed'); }
  return heroU;
}
/* camera during the landing: keyframes relative to the plane, then a close-up of Noelia */
const LAND_CAM = [
  [0, v3(-20, 2, 16), v3(0, -1, 2)],
  [7, v3(-13, -1.9, 15), v3(0, -1.2, 1)],
  [13.5, v3(13, 0.6, 15), v3(0.95, 0, DOOR_Z)],
  [18, v3(10, -1.2, 13), v3(3.5, -1.2, 6.5)]
];
const lcPos = new THREE.Vector3(), lcLook = new THREE.Vector3(), hcPos = new THREE.Vector3(), hcLook = new THREE.Vector3();
function landingCamera(L, portrait) {
  let i = 0; while (i < LAND_CAM.length - 2 && L > LAND_CAM[i + 1][0]) i++;
  const [t0, p0, l0] = LAND_CAM[i], [t1, p1, l1] = LAND_CAM[i + 1], f = smooth((L - t0) / (t1 - t0));
  lcPos.copy(p0).lerp(p1, f).multiplyScalar(portrait ? 1.4 : 1); lcLook.copy(l0).lerp(l1, f);
  if (L > HERO_BOTTOM - 0.5) {
    const k = smooth((L - HERO_BOTTOM + 0.5) / 1.5), close = smooth((L - HERO_BOTTOM) / (hero.tArrive - HERO_BOTTOM + 0.6));
    const base = pathAt(hero, Math.min((L - hero.start) * WALK, hero.len)).pos;
    hcPos.set(2.4, 1.3, 3.4).lerp(HERO_CAM, close).multiplyScalar(portrait ? 1.35 : 1).add(base).sub(plane.position);
    hcLook.set(base.x, base.y + 0.72, base.z).sub(plane.position);
    lcPos.lerp(hcPos, k); lcLook.lerp(hcLook, k);
  }
  return [lcPos, lcLook];
}

/* ---------- sky, sun, moon, stars ---------- */
const skyUniforms = { top: { value: new THREE.Color() }, horizon: { value: new THREE.Color() }, sunDir: { value: new THREE.Vector3(0, 1, 0) }, sunColor: { value: new THREE.Color() }, glow: { value: 1 } };
const sky = new THREE.Mesh(new THREE.SphereGeometry(1800, 48, 24), new THREE.ShaderMaterial({
  uniforms: skyUniforms, side: THREE.BackSide, depthWrite: false, fog: false,
  vertexShader: 'varying vec3 vPos; void main(){ vPos = position; vec4 p = projectionMatrix * modelViewMatrix * vec4(position,1.0); gl_Position = p.xyww; }',
  fragmentShader: `uniform vec3 top; uniform vec3 horizon; uniform vec3 sunDir; uniform vec3 sunColor; uniform float glow; varying vec3 vPos;
    void main(){ vec3 d = normalize(vPos); float h = clamp(d.y * 1.6 + 0.03, 0.0, 1.0);
      vec3 col = mix(horizon, top, pow(h, 0.5));
      float s = max(dot(d, normalize(sunDir)), 0.0);
      col += sunColor * (pow(s, 900.0) * 14.0 + pow(s, 14.0) * 0.45 * glow + pow(s, 3.0) * 0.12 * glow);
      gl_FragColor = vec4(col, 1.0);
      #include <tonemapping_fragment>
      #include <colorspace_fragment>
    }`
}));
sky.renderOrder = -1;
scene.add(sky);
const starGeo = new THREE.BufferGeometry();
{ const a = []; for (let i = 0; i < 1800; i++) { const u = rand() * 2 - 1, t = rand() * Math.PI * 2, s = Math.sqrt(1 - u * u); if (u < 0.02) continue; a.push(s * Math.cos(t) * 1700, u * 1700, s * Math.sin(t) * 1700); } starGeo.setAttribute('position', new THREE.Float32BufferAttribute(a, 3)); }
const stars = new THREE.Points(starGeo, new THREE.PointsMaterial({ color: '#FFFFFF', size: 1.6, sizeAttenuation: false, transparent: true, opacity: 0, fog: false, depthWrite: false }));
scene.add(stars);
const moon = new THREE.Mesh(new THREE.SphereGeometry(26, 32, 16), new THREE.MeshBasicMaterial({ color: new THREE.Color(1.6, 1.6, 1.5), fog: false, transparent: true, opacity: 0 }));
scene.add(moon);

const hemi = new THREE.HemisphereLight('#CFE6FF', '#4A5A3A', 1);
scene.add(hemi);
const sun = new THREE.DirectionalLight('#FFF4DE', 3);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
Object.assign(sun.shadow.camera, { left: -75, right: 75, top: 75, bottom: -75, near: 1, far: 320 });
sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.03;
scene.add(sun, sun.target);
const moonLight = new THREE.DirectionalLight('#9DB4FF', 0);
scene.add(moonLight, moonLight.target);
scene.fog = new THREE.Fog('#BFDDF7', 90, 560);

/* time of day across the trip (p = 0 → 1) */
const TOD = [
  { p: 0.00, top: '#2E6FD8', hor: '#C4DFF7', sun: '#FFF4DE', si: 3.0, hemi: 1.0, el: 0.7, az: 2.5, night: 0, label: T.day },
  { p: 0.34, top: '#2E6FD8', hor: '#CFE3F5', sun: '#FFF1D6', si: 3.0, hemi: 1.0, el: 0.45, az: 2.8, night: 0, label: T.day },
  { p: 0.46, top: '#3A4F8E', hor: '#F7A35C', sun: '#FFAE6A', si: 2.4, hemi: 0.6, el: 0.07, az: 3.05, night: 0.05, label: T.dusk },
  { p: 0.54, top: '#121A3A', hor: '#6E4A78', sun: '#FF7A4A', si: 0.5, hemi: 0.3, el: -0.06, az: 3.1, night: 0.6, label: T.nightfall },
  { p: 0.62, top: '#040812', hor: '#121E3B', sun: '#8FA8FF', si: 0.0, hemi: 0.14, el: -0.4, az: 3.1, night: 1, label: T.night },
  { p: 0.80, top: '#040812', hor: '#121E3B', sun: '#8FA8FF', si: 0.0, hemi: 0.14, el: -0.4, az: -3.1, night: 1, label: T.night },
  { p: 0.88, top: '#27325F', hor: '#F2A07A', sun: '#FFB27A', si: 1.5, hemi: 0.45, el: 0.05, az: -3.05, night: 0.35, label: T.dawn },
  { p: 1.00, top: '#3D7DDA', hor: '#D4E6F7', sun: '#FFF1D8', si: 2.9, hemi: 0.95, el: 0.4, az: -2.7, night: 0, label: T.day }
];
const cA = new THREE.Color(), cB = new THREE.Color();
function lerpColor(a, b, k, out) { cA.set(a); cB.set(b); return out.copy(cA).lerp(cB, k); }
let todLabel = '', applyNight = 0;
const floodC = new THREE.Color(), HAL_TOP = new THREE.Color('#2B0F45'), HAL_HOR = new THREE.Color('#5A2050'), MOON_HAL = new THREE.Color(2.0, 1.1, 0.4), MOON_STD = new THREE.Color(1.6, 1.6, 1.5);
function applyTimeOfDay(p) {
  let i = 0; while (i < TOD.length - 2 && p > TOD[i + 1].p) i++;
  const a = TOD[i], b = TOD[i + 1], k = THREE.MathUtils.clamp((p - a.p) / (b.p - a.p), 0, 1), L = (x, y) => x + (y - x) * k;
  lerpColor(a.top, b.top, k, skyUniforms.top.value);
  lerpColor(a.hor, b.hor, k, skyUniforms.horizon.value);
  lerpColor(a.sun, b.sun, k, skyUniforms.sunColor.value);
  scene.fog.color.copy(skyUniforms.horizon.value);
  const el = L(a.el, b.el), az = L(a.az, b.az);
  const dir = v3(Math.cos(el) * Math.sin(az), Math.sin(el), Math.cos(el) * Math.cos(az));
  skyUniforms.sunDir.value.copy(dir);
  const night = L(a.night, b.night); applyNight = night;
  skyUniforms.glow.value = 1 - night * 0.8;
  sun.color.copy(skyUniforms.sunColor.value);
  sun.intensity = L(a.si, b.si) * THREE.MathUtils.clamp(el * 6 + 0.4, 0, 1);
  sun.position.copy(plane.position).addScaledVector(dir.y > 0.05 ? dir : v3(dir.x, 0.05, dir.z).normalize(), 140);
  sun.target.position.copy(plane.position);
  hemi.intensity = L(a.hemi, b.hemi);
  hemi.color.copy(skyUniforms.top.value).lerp(new THREE.Color('#FFFFFF'), 0.5);
  moonLight.intensity = night * 0.55;
  const moonDir = v3(-0.35, 0.42, -0.84).normalize();
  moonLight.position.copy(plane.position).addScaledVector(moonDir, 140); moonLight.target.position.copy(plane.position);
  moon.material.opacity = night;
  stars.material.opacity = night * 0.9;
  lights.material.opacity = THREE.MathUtils.clamp(night * 1.3 - 0.1, 0, 1);
  landing.intensity = night * 400;
  plane.userData.trailMat.opacity = 0.6 - night * 0.4;
  planeFill.intensity = night * 70; planeFill2.intensity = night * 45;
  for (const m of litMaterials) m.envMapIntensity = m.userData.env * (1 - night * 0.85);
  const th = THEMES[theme];
  if (th.flood) floodC.set(th.flood).multiplyScalar(0.3);
  for (const m of monumentMaterials) { m.emissive.copy(m.userData.flood); if (th.flood) m.emissive.lerp(floodC, 0.4); m.emissive.multiplyScalar(night * 1.6); }
  if (theme === 'halloween') { skyUniforms.top.value.lerp(HAL_TOP, night * 0.8); skyUniforms.horizon.value.lerp(HAL_HOR, night * 0.7); scene.fog.color.copy(skyUniforms.horizon.value); }
  moon.material.color.copy(theme === 'halloween' ? MOON_HAL : MOON_STD); moon.scale.setScalar(theme === 'halloween' ? 1.5 : 1);
  pumpkinFaceMat.emissiveIntensity = 0.7 + night * 2.6;
  plane.userData.paint.emissiveIntensity = night * 1.3;
  renderer.toneMappingExposure = 1.0 + night * 0.35;
  todLabel = night > 0.5 ? T.night : (k < 0.5 ? a.label : b.label);
  return moonDir;
}

/* ---------- post-processing (glow for lights and the sun) ---------- */
const composer = new EffectComposer(renderer);
composer.addPass(new RenderPass(scene, camera));
const bloom = new UnrealBloomPass(new THREE.Vector2(256, 256), 0.6, 0.55, 1.6);
composer.addPass(bloom);
composer.addPass(new OutputPass());

/* ---------- cameras ---------- */
const CAMS = {
  frente: { pos: v3(6.5, 2.6, 22), look: v3(0, -1.6, 0) },
  lateral: { pos: v3(-26, 1.6, 3), look: v3(0, -2.2, 1) },
  detras: { pos: v3(0, 4.2, -25), look: v3(0, -0.6, 8) },
  arriba: { pos: v3(-5, 17, -15), look: v3(0, -2, 4) }
};
const CINE_ORDER = ['frente', 'lateral', 'detras', 'arriba'];
let camMode = 'frente';
const camPos = CAMS.frente.pos.clone(), camLook = CAMS.frente.look.clone();

/* ---------- HUD ---------- */
const $ = (id) => document.getElementById(id);
const labelsEl = $('labels');
ROUTE.forEach((m) => {
  const el = document.createElement('div'); el.className = 'tag'; el.innerHTML = `${FLAG(m.code)}<span>${esc(m.name)}</span>`; el.style.opacity = '0';
  labelsEl.appendChild(el); m.tag = el;
});
const card = $('card');
let cardKey = '';
function setCard(m) {
  if (!m) { card.dataset.off = '1'; cardKey = ''; return; }
  card.dataset.off = '0';
  if (cardKey === m.key) return;
  cardKey = m.key;
  $('cardFlag').innerHTML = FLAG(m.code);
  $('cardName').textContent = m.name; $('cardPlace').textContent = m.place; $('cardFact').textContent = m.fact;
}
document.querySelectorAll('[data-cam]').forEach((b) => b.addEventListener('click', () => {
  camMode = b.dataset.cam;
  document.querySelectorAll('[data-cam]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
}));
let speed = 1, paused = false;
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
$('speed').addEventListener('click', () => { speed = speed === 1 ? 2 : speed === 2 ? 0.5 : 1; $('speed').textContent = 'x' + speed; });
const setPaused = (v) => { paused = v; $('pause').textContent = v ? T.resume : T.pause; };
$('pause').addEventListener('click', () => setPaused(!paused));
if (reduceMotion) setPaused(true);
let theta = 0, landT = -1, snapCam = false;
function restart(fromTheta) { theta = fromTheta; landT = -1; endShown = false; $('arrive').hidden = true; document.body.classList.remove('ending'); setPaused(false); }
$('again').addEventListener('click', () => restart(0));
$('land').addEventListener('click', () => restart(THETA_END - 0.035));

/* themes: picked from today's date (or ?tema=), the button cycles through them */
let theme = 'normal';
const terrainCache = { normal: terrainTex };
function applyTheme(name) {
  theme = name; const th = THEMES[name], ud = plane.userData;
  if (!terrainCache[name]) terrainCache[name] = makeTerrain(TERRAIN[name], mkRand(4242));
  earthMat.map = terrainCache[name]; earthMat.needsUpdate = true;
  colorTrees(name); colorRoofs(name);
  airGrass.color.set(th.grass);
  ud.paint.map = cached('livery-' + name, () => liveryTexture(th)); ud.paint.needsUpdate = true;
  ud.finMat.map = cached('fin-' + name, () => finTexture(th)); ud.finMat.needsUpdate = true;
  ud.nacMat.color.set(th.nacelle); ud.bandMat.color.set(th.band); ud.doorMat.color.set(th.top || '#FFFFFF');
  for (const k of ['halloween', 'navidad']) { ud.hats[k].visible = k === name; hero.hats[k].visible = k === name; for (const g of decoGroups[k]) g.visible = k === name; }
  ud.nose.visible = name === 'navidad';
  festiveLights.visible = name !== 'normal';
  snow.visible = name === 'navidad';
  blinkLights(0);
  $('theme').textContent = fmt(T.theme, { name: th.label });
}
$('theme').addEventListener('click', () => applyTheme(THEME_ORDER[(THEME_ORDER.indexOf(theme) + 1) % THEME_ORDER.length]));
{
  let q = null; try { q = new URLSearchParams(location.search).get('tema'); } catch (e) { q = null; }
  applyTheme(THEMES[q] ? q : themeForDate(new Date()));
}

/* ---------- textos fijos de la pantalla, en tu idioma ---------- */
// Idiomas que se leen de derecha a izquierda: los textos se giran, pero la
// barra de la ruta no (el avión siempre va de la salida a la llegada).
if (['ar', 'he', 'fa', 'ur'].includes(NQ.lang)) {
  for (const el of document.querySelectorAll('.meta, .card, .end-text, .controls')) el.setAttribute('dir', 'rtl');
}
canvas.setAttribute('aria-label', T.sceneLabel);
$('loading').textContent = T.loading;
$('fromFlag').innerHTML = FLAG(NQ.from.cc); $('fromCode').textContent = NQ.from.code;
$('toFlag').innerHTML = FLAG(NQ.to.cc); $('toCode').textContent = NQ.to.code;
$('controls').setAttribute('aria-label', T.controls);
for (const [id, key] of [['cam-frente', 'camFront'], ['cam-lateral', 'camSide'], ['cam-detras', 'camBehind'], ['cam-arriba', 'camTop'], ['cam-cine', 'camCine'], ['land', 'land'], ['again', 'again'], ['done', 'done']]) $(id).textContent = T[key];
$('speed').setAttribute('aria-label', T.speed);
if (!paused) $('pause').textContent = T.pause;
$('endFlag').innerHTML = FLAG(NQ.to.cc);
$('endTitle').textContent = fmt(T.welcome, { city: NQ.to.city });
$('endText').textContent = fmt(T.landed, { to: NQ.to.city, km: num(NQ.km), from: NQ.from.city });
$('done').addEventListener('click', () => tellApp('done'));

/* ---------- loop ---------- */
function resize() {
  const w = window.innerWidth, h = window.innerHeight;
  renderer.setSize(w, h, false); composer.setSize(w, h);
  camera.aspect = w / h;
  camera.fov = w / h < 0.8 ? 64 : 50;
  camera.updateProjectionMatrix();
}
window.addEventListener('resize', resize);
resize();

const clock = new THREE.Clock();
let time = 0, blinkStep = -1, hudStatus = '', hudWhere = '';
const tmp = new THREE.Vector3();
const camTarget = new THREE.Vector3(), lookTarget = new THREE.Vector3();
function frame() {
  const dt = Math.min(clock.getDelta(), 0.05);
  if (!paused) {
    time += dt;
    if (landT < 0) { theta = Math.min(THETA_END, theta + dt * SPEED * speed); if (theta >= THETA_END) landT = 0; }
    else landT = Math.min(landT + dt * speed * LAND_RATE, 600); // the landing plays at x2 so the ending never drags
  }
  const L = landT;
  if (L >= 0) theta = THETA_END + landDist(L);
  const p = Math.min(1, theta / THETA_END);
  earth.rotation.x = -theta;

  // the plane breathes while cruising (roll, pitch, bob); on approach it descends, flares and settles on the runway
  const air = L < 0 ? 1 : 1 - smooth(L / LAND.touch);
  let pitch;
  if (L < 0) pitch = Math.sin(time * 0.7) * 0.025;
  else if (L < LAND.touch) pitch = Math.sin(time * 0.7) * 0.025 * air - 0.035 * smooth(L / 2) - 0.05 * smooth((L - 6) / 2.2);
  else pitch = -0.085 * (1 - smooth((L - LAND.touch) / 1.4));
  plane.rotation.x = pitch;
  plane.rotation.z = Math.sin(time * 0.45) * 0.09 * air;
  plane.position.y = GROUND_Y + (ALT - GROUND_Y) * air + Math.sin(time * 0.9) * 0.25 * air + Math.max(0, -pitch) * 0.9;
  const thrust = L < 0 ? 1 : 0.25 + 0.75 * landSpeed(L);
  for (const e of plane.userData.engines) e.userData.fan.rotation.z -= dt * 40 * thrust;
  const blink = (time % 1.3) < 0.07;
  for (const s of plane.userData.strobes) s.visible = blink;
  plane.userData.beacon.visible = (time % 1.0) < 0.5;
  updateLanding(L);

  const moonDir = applyTimeOfDay(p);
  if (L >= 0) { plane.userData.trailMat.opacity *= Math.max(0, 1 - L / 3); if (L < LAND.touch + 2) landing.intensity = Math.max(landing.intensity, 260); }

  // camera
  const portrait = camera.aspect < 0.8;
  let mode = camMode;
  if (camMode === 'cine') mode = CINE_ORDER[Math.floor(time / 8) % CINE_ORDER.length];
  if (L >= 0) {
    const [cp, cl] = landingCamera(L, portrait);
    camTarget.copy(cp); lookTarget.copy(cl);
  } else {
    const c = CAMS[mode];
    plane.userData.trailMat.opacity *= mode === 'detras' ? 0.15 : mode === 'arriba' ? 0.5 : 1;
    camTarget.copy(c.pos).multiplyScalar(portrait ? 1.6 : 1).add(tmp.set(Math.sin(time * 0.31) * 1.2, Math.sin(time * 0.23) * 0.6, Math.cos(time * 0.27) * 1.0));
    lookTarget.copy(c.look);
  }
  if (snapCam) { camPos.copy(camTarget); camLook.copy(lookTarget); snapCam = false; }
  const k = 1 - Math.pow(L >= 0 ? 0.12 : 0.02, dt);
  camPos.lerp(camTarget, k); camLook.lerp(lookTarget, k);
  camera.position.copy(plane.position).add(camPos);
  camera.position.y = Math.max(camera.position.y, 0.35);
  camera.lookAt(tmp.copy(plane.position).add(camLook));
  // a soft key light from the camera so Noelia's face is lit in the close-up
  heroLight.intensity = L >= 0 ? 9 * smooth((L - HERO_BOTTOM) / 2) : 0;
  heroLight.position.copy(camera.position).add(tmp.set(0.3, 0.8, 0));
  sky.position.copy(camera.position); stars.position.copy(camera.position);
  moon.position.copy(camera.position).addScaledVector(moonDir, 1500);

  // holiday animation: blinking string lights, circling bats, falling snow
  if (theme !== 'normal') {
    const st = Math.floor(time / 0.45);
    if (st !== blinkStep) { blinkStep = st; blinkLights(st); }
  }
  if (theme === 'halloween') {
    for (const B of bats) {
      if (Math.abs(B.m.phi - theta) > 0.14) continue;
      const a = B.a0 + time * B.sp;
      B.b.position.set(B.cx + Math.cos(a) * B.r, B.h + Math.sin(time * 1.3 + B.a0) * 1.0, B.cz + Math.sin(a) * B.r);
      B.b.rotation.y = B.sp > 0 ? -a : Math.PI - a;
      const fl = Math.sin(time * 14 + B.a0) * 0.7;
      B.b.userData.wr.rotation.z = fl; B.b.userData.wl.rotation.z = -fl;
    }
  }
  if (snow.visible) {
    const ground = paused ? 0 : SPEED * R * speed * (L < 0 ? 1 : landSpeed(L)), fall = paused ? 0 : 1.8;
    const pa = snowGeo.attributes.position, arr = pa.array;
    for (let i = 0; i < SNOW_N; i++) {
      let y = arr[i * 3 + 1] - dt * fall, z = arr[i * 3 + 2] - dt * ground;
      if (y < -6) y += 40;
      if (z < -45) z += 90;
      arr[i * 3] += Math.sin(time * 0.8 + i) * dt * 0.3 * (paused ? 0 : 1); arr[i * 3 + 1] = y; arr[i * 3 + 2] = z;
    }
    pa.needsUpdate = true;
    snow.position.copy(camera.position);
  }
  for (const m of ROUTE) {
    const sp = m.obj.userData.sparkle; // los destellos de la Torre Eiffel de noche
    if (!sp) continue;
    sp.material.opacity = THREE.MathUtils.clamp((applyNight - 0.3) * 2, 0, 1);
    sp.geometry.setDrawRange(Math.floor(time * 9) % 2 ? 0 : 45, 45);
  }

  // HUD: route progress, status, monument card and floating tags
  $('fill').style.width = (p * 100).toFixed(2) + '%';
  $('dot').style.left = (p * 100).toFixed(2) + '%';
  $('km').textContent = fmt(T.kmOf, { km: num(p * NQ.km), total: num(NQ.km) });
  $('tod').textContent = todLabel;
  // Hasta el primer monumento, el país de salida; luego, el del último que
  // pasaste. Al aterrizar, la ciudad de destino.
  let country = countryName(NQ.from.cc);
  for (const m of ROUTE) if (theta >= m.phi - STEP / 2) country = m.country;
  const status = L < 0 ? T.overflying : L < LAND.touch ? T.landingIn : T.arrivedIn;
  if (status !== hudStatus) { hudStatus = status; $('statusLabel').textContent = status; }
  const where = L < 0 ? country : NQ.to.city;
  if (where !== hudWhere) { hudWhere = where; $('country').textContent = where; }
  let near = null;
  for (const m of ROUTE) {
    const d = m.phi - theta;
    if (d < 0.03 && d > -0.03) near = m;
    m.obj.getWorldPosition(tmp); tmp.y += m.height + 1.5 - (m.key === 'fuji' ? 3 : 0);
    const vis = d < 0.09 && d > -0.1 && L < 0;
    tmp.project(camera);
    if (vis && tmp.z < 1 && Math.abs(tmp.x) < 1.1 && Math.abs(tmp.y) < 1.1) {
      m.tag.style.opacity = '1';
      m.tag.style.transform = `translate(${((tmp.x + 1) / 2) * window.innerWidth}px, ${((1 - tmp.y) / 2) * window.innerHeight - 14}px) translate(-50%, -100%)`;
    } else m.tag.style.opacity = '0';
  }
  setCard(near);

  composer.render();
  requestAnimationFrame(frame);
}
requestAnimationFrame(() => { $('loading').style.opacity = '0'; setTimeout(() => $('loading').remove(), 700); frame(); });

/* hooks used to preview specific moments */
window.__vuelo = { land(t) { landT = t; theta = THETA_END + landDist(t); endShown = false; $('arrive').hidden = true; document.body.classList.remove('ending'); snapCam = true; }, theme: (n) => applyTheme(n), set(p, cam) { landT = -1; theta = p * THETA_END; snapCam = true; if (cam) { camMode = cam; document.querySelectorAll('[data-cam]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.cam === cam))); const c = CAMS[cam]; if (c) { camPos.copy(c.pos).multiplyScalar(camera.aspect < 0.8 ? 1.6 : 1); camLook.copy(c.look); } } }, pause: setPaused, debug: () => ({ cam: camera.position.toArray(), plane: plane.position.toArray(), fov: camera.fov }) };
