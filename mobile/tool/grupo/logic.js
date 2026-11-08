class Component extends DCLogic {
// Lo que pinta la maqueta "Grupo" con los datos de TU viaje. La app los pone
// en window.ECL (ver lib/features/group/group_page.dart) y, sin recargar,
// manda lo que llega después (zonas, sitios cerca, votos) con
// window.ECLin({...}). La página le pide cosas a la app con toApp("aviso").
constructor(props) {
super(props);
this.E = window.ECL || {};
this.spk = (this.E.spots || []).map((x) => x.t).join('|');
const me = (this.E.people || []).findIndex((p) => p.me);
this.state = { step: 0, auto: true, burst: 0, who: me < 0 ? 0 : me, sel: 0, tick: 0 };
}
componentDidMount() {
window.ECLin = (d) => {
Object.assign(this.E, d || {});
// Si cambian los sitios (otro antojo), se vuelve a señalar el primero.
const k = (this.E.spots || []).map((x) => x.t).join('|');
const sel = k === this.spk ? this.state.sel : 0;
this.spk = k;
this.setState({ tick: this.state.tick + 1, sel });
};
this.iv = setInterval(() => {
if (!this.state.auto) return;
if (this.state.step >= 4) { this.setState({ auto: false }); return; }
this.setState({ step: this.state.step + 1 });
}, 2600);
}
componentWillUnmount() { clearInterval(this.iv); clearTimeout(this.nt); }
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const st = this.state;
const E = this.E;
const PEO = E.people || [];
const S = [['Gustos', '#B69CFF', 'group'], ['Zona', '#6CA8FF', 'zone'], ['Dormir', '#8C9BFF', 'bed'], ['Planes', '#FF8A65', 'ticket'], ['Votar', '#3DDC97', 'vote']];
const steps = S.map(([label, c, ik], i) => {
const on = i === st.step, done = i < st.step;
return { label, img: ICO[ik][2], on: on ? 'true' : 'false',
pick: () => this.setState({ step: i, auto: false }),
style: 'height: 64px; border-radius: 14px; font-family: inherit; font-size: 10px; font-weight: 800; cursor: pointer; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; padding: 0; color: #F2F5F3; ' + (on ? 'background: ' + c + '26; border: 1.5px solid ' + c + '; transform: translateY(-2px)' : done ? 'background: #16222A; border: 1px solid ' + c + '66' : 'background: #141E25; border: 1px solid #26363F; color: #9FB0B8'),
ico: 'width: 32px; height: 32px; border-radius: 11px; display: flex; align-items: center; justify-content: center; background: radial-gradient(120% 100% at 30% 20%, ' + ICO[ik][0] + ', ' + ICO[ik][1] + '); box-shadow: inset 0 1px 0 #ffffff55' + (on || done ? '' : '; opacity: .45') + (on ? '; animation: g7-bob 1.4s ease-in-out infinite' : '') };
});
// 1 · Lo que quiere cada uno (sale de sus gustos).
const W = [['#6CA8FF', -60, -30, 8, 6], ['#FF8A65', 60, -30, 190, 14], ['#FFB86B', -60, 30, 20, 56], ['#B69CFF', 60, 30, 176, 64]];
const wants = (E.wants || []).slice(0, 4).map((t, i) => { const [c, fx, fy, x, y] = W[i]; return { t, style: 'position: absolute; left: ' + x + 'px; top: ' + y + 'px; height: 28px; border-radius: 14px; background: ' + c + '22; border: 1px solid ' + c + '88; color: #F2F5F3; font-size: 11.5px; font-weight: 800; display: flex; align-items: center; padding: 0 10px; white-space: nowrap; max-width: 170px; overflow: hidden; text-overflow: ellipsis; --fx: ' + fx + 'px; --fy: ' + fy + 'px; --tx: ' + (140 - x) + 'px; --ty: ' + (110 - y) + 'px; animation: g7-chipfly 2.6s ease ' + (i * 0.15) + 's infinite both' }; });
// 2 · Las zonas (la primera, la que gana, va donde está el radar).
const SLOT = [[196, 56, '#3DDC97', 0.6], [120, 40, '#FFB86B', 0.1], [40, 78, '#6CA8FF', 0.3]];
const pins = (E.zones || []).slice(0, 3).map((z, i) => { const [x, y, c, d] = SLOT[i]; return { t: z.name,
style: 'position: absolute; left: ' + x + 'px; top: ' + (y - 24) + 'px; height: 24px; border-radius: 12px; background: #0B1217E6; border: 1px solid ' + c + '; color: #F2F5F3; font-size: 11px; font-weight: 800; display: flex; align-items: center; gap: 5px; padding: 0 8px 0 6px; white-space: nowrap; animation: g7-pin .6s cubic-bezier(.2,.9,.3,1.3) ' + d + 's both' + (i === 0 ? '; transform-origin: 50% 100%' : ''),
dot: 'width: 9px; height: 9px; border-radius: 5px; background: ' + c }; });
// 3 · Dónde dormir: los filtros y las zonas (abren Booking).
const filters = (E.filters || []).map((t, i) => ({ t, style: 'height: 26px; border-radius: 13px; background: #FFB86B1F; border: 1px solid #FFB86B88; color: #FFE1BC; font-size: 11px; font-weight: 800; display: flex; align-items: center; padding: 0 10px; animation: g7-pop .4s ease ' + (i * 0.12) + 's both' }));
const stays = (E.zones || []).slice(0, 2).map((z, i) => ({ t: z.title, d: z.detail, open: () => toApp('book:' + i),
style: 'display: flex; align-items: center; gap: 10px; border-radius: 14px; background: #141E25; border: 1px solid #26363F; padding: 9px 10px; cursor: pointer; animation: g7-slide .5s cubic-bezier(.2,.8,.2,1) ' + (0.4 + i * 0.25) + 's both',
img: ICO.bed[2], ico: 'width: 36px; height: 36px; border-radius: 12px; background: radial-gradient(120% 100% at 30% 20%, ' + ICO.bed[0] + ', ' + ICO.bed[1] + '); display: flex; align-items: center; justify-content: center; flex-shrink: 0',
okStyle: 'width: 22px; height: 22px; border-radius: 11px; background: #3DDC97; color: #0B1217; font-size: 12px; font-weight: 800; display: flex; align-items: center; justify-content: center; animation: g7-tick .4s ease ' + (0.9 + i * 0.25) + 's both' }));
// 4 · Qué pasa esos días (Ticketmaster).
const TC = [['#FF8A65', 0, -4, 0], ['#6CA8FF', 108, 3, 0.2], ['#3DDC97', 216, -2, 0.4]];
const tickets = (E.events || []).slice(0, 3).map((k, i) => { const [c, x, r, dl] = TC[i]; return { day: k.day, t: k.t, d: k.d, c,
style: 'position: absolute; left: ' + x + 'px; top: 4px; width: 98px; height: 112px; box-sizing: border-box; border-radius: 14px; background: #141E25; border: 1px solid ' + c + '88; border-left: 4px solid ' + c + '; padding: 8px; display: flex; flex-direction: column; gap: 4px; overflow: hidden; --r: ' + r + 'deg; animation: g7-ticket .55s cubic-bezier(.2,.9,.3,1.2) ' + dl + 's both' }; });
// Votad dónde dormir: los votos de verdad (secretos: se ve cuántos).
const total = Math.max(1, E.total || PEO.length || 1);
const DOT = ['#B69CFF', '#FF8A65', '#6CA8FF', '#FFB86B'];
const meP = PEO.find((p) => p.me) || { i: '?' };
const opts = (E.options || []).slice(0, 2);
const options = opts.map((d, k) => {
const chosen = !!d.mine, n = d.yes || 0;
const who = []; for (let j = 0; j < Math.min(4, n); j++) who.push({ i: chosen && j === 0 ? meP.i : '', style: 'width: 24px; height: 24px; border-radius: 12px; background: ' + DOT[j % 4] + '; color: #0B1217; font-size: 11px; font-weight: 800; display: flex; align-items: center; justify-content: center; border: 2px solid #221A38; margin-left: ' + (j ? '-7px' : '0') + '; animation: g7-pop .45s cubic-bezier(.2,.9,.3,1.3) both' });
const slots = {}; for (let j = 0; j < 4; j++) { slots['s' + j] = who[j] ? who[j].style : 'display: none'; slots['l' + j] = who[j] ? who[j].i : ''; }
return Object.assign(slots, { title: d.title, detail: d.detail,
vote: () => { if (!chosen) toApp('zone:' + k); else if (n >= total) toApp('book:' + k); },
fill: 'position: absolute; left: 0; top: 0; bottom: 0; width: ' + Math.round(Math.min(1, n / total) * 100) + '%; background: ' + (chosen ? '#B69CFF33' : '#B69CFF14'),
style: 'position: relative; overflow: hidden; display: flex; align-items: center; gap: 10px; min-height: 58px; border-radius: 16px; padding: 8px 12px; font-family: inherit; color: #F2F5F3; cursor: pointer; ' + (chosen ? 'border: 2px solid #B69CFF; background: #2B2150' : 'border: 1px solid #3E3163; background: #221A38') });
});
const all = opts.some((d) => (d.yes || 0) >= total);
const confetti = all ? Array.from({ length: 14 }, (_, i) => { const a = i / 14 * Math.PI * 2; return { style: 'position: absolute; left: 50%; top: 40%; width: 7px; height: 11px; border-radius: 2px; background: ' + ['#B69CFF', '#3DDC97', '#FFB86B', '#6CA8FF', '#FF8A65'][i % 5] + '; --cx: ' + Math.round(Math.cos(a) * 150) + 'px; --cy: ' + Math.round(Math.sin(a) * 90) + 'px; animation: g7-conf 1.2s cubic-bezier(.1,.7,.3,1) both' }; }) : [];
const voted = opts.reduce((a, d) => a + (d.yes || 0), 0);
const left = Math.max(0, total - voted);
const mine = opts.some((d) => d.mine);
// El plan del grupo (lo que metisteis en «Elegir planes»).
const DY = [['#B69CFF', 'music'], ['#6CA8FF', 'beach'], ['#3DDC97', 'tower']];
const days = (E.days || []).slice(0, 3).map((t, i) => { const [c, ik] = DY[i]; return { k: 'DÍA ' + (i + 1), t, img: ICO[ik][2],
style: 'border-radius: 18px; background: linear-gradient(160deg, ' + c + '22, #141E25 60%); border: 1px solid ' + c + '55; padding: 10px; display: flex; flex-direction: column; gap: 5px; transform-origin: 50% 0; animation: g7-flip .7s cubic-bezier(.2,.9,.3,1.2) ' + (1 + i * 0.25) + 's both',
ico: 'width: 38px; height: 38px; border-radius: 13px; background: radial-gradient(120% 100% at 30% 20%, ' + ICO[ik][0] + ', ' + ICO[ik][1] + '); display: flex; align-items: center; justify-content: center; border: 3px solid #0B1217; animation: g7-pop .5s cubic-bezier(.2,.9,.3,1.3) ' + (1.1 + i * 0.25) + 's both' }; });
// Gustos de cada uno: los tuyos se tocan; los de los demás solo se ven.
const who = Math.min(st.who, Math.max(0, PEO.length - 1));
const P = PEO[who] || { name: '', c: '#B69CFF', tastes: [], me: true };
const gTabs = PEO.map((p, i) => ({ t: p.name, pick: () => this.setState({ who: i }), style: 'flex: 1; min-width: 0; height: 30px; border-radius: 15px; font-family: inherit; font-size: 11.5px; font-weight: 800; cursor: pointer; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; ' + (who === i ? 'background: ' + p.c + '; color: #0B1217; border: none' : 'background: #141E25; color: #F2F5F3; border: 1px solid #33444E') }));
const gusts = (E.tastes || []).map(([id, t]) => { const on = (P.tastes || []).includes(id); return { t, on: on ? 'true' : 'false',
pick: () => { if (P.me) toApp('taste:' + (E.tastes || []).findIndex((x) => x[0] === id)); },
style: 'height: 30px; border-radius: 15px; font-family: inherit; font-size: 11.5px; font-weight: 800; padding: 0 10px; display: flex; align-items: center; gap: 5px; cursor: ' + (P.me ? 'pointer' : 'default') + '; transition: transform .2s, background .2s; ' + (on ? 'background: ' + P.c + '2E; color: #F2F5F3; border: 1px solid ' + P.c + '; transform: scale(1.03)' : 'background: transparent; color: #9FB0B8; border: 1px solid #33444E'),
ck: on ? 'width: 15px; height: 15px; border-radius: 8px; background: ' + P.c + '; color: #0B1217; font-size: 9px; display: flex; align-items: center; justify-content: center; animation: g7-tick .35s ease both' : 'display: none' }; });
const gHint = P.me ? 'Toca para marcar o quitar tus gustos. Flyra los cruza con los del grupo.' : 'Esto lo marcó ' + P.name + ' en su móvil.';
// ¿Qué os apetece?: los sitios de OpenStreetMap cerca, con vuestros votos.
const CR = ['Tapas', 'Pescado', 'Vegetariano', 'Café', 'Con vistas'];
const crave = E.crave || 0;
const craves = CR.map((t, i) => ({ t, pick: () => { if (i !== crave) { this.E.crave = i; this.E.spots = null; this.setState({ sel: 0 }); toApp('crave:' + i); } },
style: 'height: 30px; border-radius: 15px; font-family: inherit; font-size: 11.5px; font-weight: 800; padding: 0 11px; cursor: pointer; transition: transform .2s; ' + (crave === i ? 'background: linear-gradient(135deg, #7FF0BF, #3DDC97); color: #0B1217; border: none; transform: scale(1.05)' : 'background: #141E25; color: #F2F5F3; border: 1px solid #33444E') }));
const SP = (E.spots || []).slice(0, 3);
const CRI = ['food', 'fish', 'leaf', 'cup', 'tower'][crave], CRC = [['#FFB86B', '#7A3A10'], ['#6CA8FF', '#14305A'], ['#3DDC97', '#0F5A3E'], ['#FFB86B', '#6A3A08'], ['#B69CFF', '#2A1A5A']][crave];
const sel = Math.min(st.sel ?? 0, Math.max(0, SP.length - 1));
const mpins = SP.map((s, i) => ({ name: s.t, img: ICO[CRI][2], pick: () => this.setState({ sel: i }),
style: 'position: absolute; left: ' + s.x + '%; top: ' + s.y + '%; transform: translate(-50%, -100%); border: 0; padding: 0; background: none; cursor: pointer; z-index: ' + (i === sel ? 5 : 4) + '; display: flex; flex-direction: column; align-items: center; animation: g7-drop .6s cubic-bezier(.2,.9,.3,1.3) ' + (0.2 + i * 0.15) + 's both',
bd: 'width: 38px; height: 38px; border-radius: 50%; display: grid; place-items: center; border: 2.5px solid #fff; background: linear-gradient(150deg, ' + CRC[0] + ', ' + CRC[1] + '); box-shadow: ' + (i === sel ? '0 0 0 4px #3DDC9780, 0 10px 22px -4px #000; transform: scale(1.3)' : '0 6px 14px -3px #000c') + '; transition: transform .25s',
stem: 'width: 2px; height: 10px; margin-top: -1px; background: linear-gradient(#ffffffcc, #ffffff00)',
tag: (i === sel ? 'display: block' : 'display: none') + '; position: absolute; left: 50%; top: -24px; transform: translateX(-50%); font-size: 10px; font-weight: 800; white-space: nowrap; background: #081014EB; border: 1px solid #3DDC9799; padding: 2px 7px; border-radius: 99px; color: #F2F5F3' }));
const spots = SP.map((s, i) => { const v = s.mine === true ? 1 : s.mine === false ? -1 : 0;
return { t: s.t, walk: s.walk, why: s.why, pickC: () => this.setState({ sel: i }),
yes: () => toApp('spot:' + i + ':1'), no: () => toApp('spot:' + i + ':0'),
yesStyle: 'height: 28px; border-radius: 14px; font-family: inherit; font-size: 11px; font-weight: 800; padding: 0 10px; cursor: pointer; ' + (v === 1 ? 'background: #3DDC97; color: #0B1217; border: none; animation: g7-pop .35s ease both' : 'background: transparent; color: #7FF0BF; border: 1px solid #3DDC9788'),
noStyle: 'height: 28px; border-radius: 14px; font-family: inherit; font-size: 11px; font-weight: 800; padding: 0 10px; cursor: pointer; ' + (v === -1 ? 'background: #33444E; color: #F2F5F3; border: none' : 'background: transparent; color: #9FB0B8; border: 1px solid #33444E'),
votes: (s.yes || 0) + ' de ' + total + ' se apuntan', badge: 'font-size: 10.5px; font-weight: 800; color: ' + ((s.yes || 0) * 2 > total ? '#7FF0BF' : '#B7C5CC'),
style: 'display: flex; flex-direction: column; gap: 6px; border-radius: 14px; background: #141E25; border: 1px solid ' + (v === -1 ? '#26363F; opacity: .5' : v === 1 ? '#3DDC97' : '#26363F') + '; padding: 10px; animation: g7-slide .45s cubic-bezier(.2,.8,.2,1) ' + (i * 0.1) + 's both' + (i === sel ? '; box-shadow: 0 0 0 2px #3DDC9755' : '') }; });
return {
accent, craves, spots, mpins, mapImg: MAPIMG, gusts, gTabs, gHint,
steps, wants, pins, filters, stays, tickets, options, confetti, days,
st0: st.step === 0, st1: st.step === 1, st2: st.step === 2, st3: st.step === 3, st4: st.step === 4,
progStyle: 'height: 4px; border-radius: 2px; background: linear-gradient(90deg, #B69CFF, #3DDC97); width: ' + ((st.step + 1) * 20) + '%',
replay: () => this.setState({ step: 0, auto: true }),
replayLabel: st.auto ? 'Buscando…' : 'Repetir',
status: all ? '¡Acuerdo! Toca la zona para reservar.' : left > 0 ? (mine ? 'Has votado. ' : '') + (left === 1 ? 'Falta 1 voto' : 'Faltan ' + left + ' votos') + (mine ? '…' : ', incluido el tuyo.') : 'Ya habéis votado todos.',
statusStyle: 'font-size: 12px; font-weight: 700; ' + (all ? 'color: #3DDC97; animation: g7-show .4s ease both' : 'color: #B9AEDB'),
// Lo que viene de la app.
title: E.title || '', sub: E.sub || '',
avatars: PEO.slice(0, 4).map((p, i) => ({ i: p.i, style: 'width: 38px; height: 38px; border-radius: 19px; background: ' + p.c + '; color: #0B1217; font-weight: 800; display: flex; align-items: center; justify-content: center; border: 3px solid #0B1217; margin-left: ' + (i ? '-10px' : '0') + '; position: relative; animation: g7-pop .5s cubic-bezier(.2,.9,.3,1.3) ' + (0.15 + i * 0.1).toFixed(2) + 's both', dot: p.on ? 'position: absolute; right: -2px; bottom: -2px; width: 11px; height: 11px; border-radius: 6px; background: #3DDC97; border: 2px solid #0B1217' : 'display: none' })),
flyraTitle: E.flyraTitle || '', flyraText: E.flyraText || '',
zoneNote: E.zoneNote || '', eventsNote: E.eventsNote || '', proposal: E.proposal || '',
hasOptions: opts.length > 0, noOptions: !opts.length, optionsNote: E.optionsNote || '',
hasSpots: SP.length > 0, spotsNote: SP.length ? '' : (E.spotsNote || ''),
golden: E.golden || '', hasGolden: !!E.golden,
hasDays: days.length > 0, noDays: !days.length,
debt: E.debt || '',
tile0: () => toApp('tile:0'), tile1: () => toApp('tile:1'), tile2: () => toApp('tile:2'), tile3: () => toApp('tile:3'),
openSettings: () => toApp('settings'), openEvents: () => toApp('events'), openMoney: () => toApp('money'), openPlans: () => toApp('tile:2'),
goSpot: () => { if (SP[sel]) toApp('go:' + sel); }
};
}
}
