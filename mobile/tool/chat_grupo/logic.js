// "Hola Flyra" y el resto de atajos: qué está mirando Flyra mientras piensa.
function thinkOf(q) {
const s = (q || '').toLowerCase();
if (/cen|com|restaur|hambre|tapas/.test(s)) return 0;
if (/llu|llov|agua|tiempo/.test(s)) return 2;
if (/gast|cuánto|cuanto|dinero|pag|debe/.test(s)) return 3;
if (/m[uú]sica|fado|concierto|bailar/.test(s)) return 0;
if (/vot|encuesta|elegir/.test(s)) return 1;
return 4;
}
// "Tú, Marta y Flyra".
function names(l) { return l.length < 2 ? l.join('') : l.slice(0, -1).join(', ') + ' y ' + l[l.length - 1]; }
class Component extends DCLogic {
// La maqueta "Chat del grupo" con vuestro chat de verdad. La app pone los
// datos en window.ECL (ver lib/features/group_chat/chat_page.dart) y manda
// lo nuevo con window.ECLin({...}). Los mensajes los guarda el servidor:
// la página solo le dice a la app qué has escrito o tocado (toApp).
constructor(props) {
super(props);
this.E = window.ECL || {};
this.done = !!this.E.first;
this.state = { stage: this.E.first || 'chat', type: this.E.kind || 'friends', invite: false, profile: false, draft: '', likes: (this.E.likes || []).slice(), stars: 0, think: 4, n: 0 };
}
componentDidMount() {
window.ECLin = (d) => {
  const before = (this.E.msgs || []).length;
  Object.assign(this.E, d || {});
  const st = { n: this.state.n + 1 };
  if (d && d.kind && this.state.stage === 'type' && !this.picked) st.type = d.kind;
  if (d && d.first && !this.done) { this.done = true; st.stage = d.first; }
  this.setState(st);
  if ((this.E.msgs || []).length !== before) this.scroll();
};
this.scroll();
}
componentWillUnmount() { clearTimeout(this.t); }
scroll() { setTimeout(() => { const el = document.querySelector('.cg-msgs'); if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' }); }, 60); }
send(text) {
const t = (text || '').trim(); if (!t || this.E.typing) return;
this.setState({ draft: '', think: thinkOf(t) });
toApp('send:0:' + pack({ t }));
this.scroll();
}
renderVals() {
const st = this.state;
const E = this.E;
const tl = T.find((t) => t[0] === st.type) || T[1];
const types = T.map(([id, label, sub, col, ic], i) => { const on = st.type === id; return { label, sub, img: ICO[ic][2], on: on ? 'true' : 'false', pick: () => { this.picked = true; this.setState({ type: id }); },
ico: 'width: 52px; height: 52px; border-radius: 16px; display: flex; align-items: center; justify-content: center; margin-bottom: auto; background: radial-gradient(120% 100% at 30% 20%, ' + ICO[ic][0] + ', ' + ICO[ic][1] + ')' + (on ? '; animation: cg-fly 2.4s ease-in-out infinite' : ''),
style: 'height: 140px; border-radius: 22px; font-family: inherit; color: #F2F5F3; cursor: pointer; display: flex; flex-direction: column; align-items: flex-start; gap: 4px; padding: 14px; text-align: left; transition: transform .25s, background .25s, border-color .25s; animation: cg-in .5s ease ' + (i * 0.07).toFixed(2) + 's both; ' + (on ? 'border: 2px solid ' + col + '; background: ' + col + '22; transform: scale(1.03); box-shadow: 0 12px 28px -12px ' + col : 'border: 1px solid #26363F; background: #141E25') }; });
const av = (c, sz, ov) => 'width: ' + sz + 'px; height: ' + sz + 'px; border-radius: ' + (sz / 2) + 'px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; font-size: ' + Math.round(sz * 0.42) + 'px; font-weight: 800; color: #0B1217; overflow: hidden; background: ' + c + (ov ? '; margin-left: -10px; box-shadow: 0 0 0 2px #0B1217' : '');
// Tú, Flyra y el resto del grupo (como en la maqueta: Flyra la segunda).
const M = E.members || [];
const meM = M.find((x) => x.me);
const mem = (meM ? [meM] : []).concat([{ fy: true }]).concat(M.filter((x) => !x.me));
const members = mem.map((p, i) => ({ ini: p.fy ? '' : p.ini, fy: !!p.fy, label: p.fy ? 'Perfil de Flyra' : p.name, tap: () => { if (p.fy) this.setState({ profile: true }); else if (p.me) toApp('name'); }, av: av(p.fy ? '#13342A' : p.c, 36, i > 0) + '; border: none; padding: 0; cursor: pointer; font-family: inherit' + (p.fy ? '; box-shadow: 0 0 0 2px #0B1217, 0 0 14px rgba(127,240,191,.6)' : '') }));
const pl = E.plan;
const msgs = (E.msgs || []).map((m) => {
const me = m.who === 'me', ia = m.who === 'ia';
const liked = st.likes.includes(m.id);
return { name: m.name, text: m.text, fy: ia, ini: ia ? '' : (m.name || '?').charAt(0).toUpperCase(),
isPlan: m.card === 'plan' && !!pl, isFood: false, isPoll: false, isRain: false, isMoney: m.card === 'money',
moneyImg: ICO.money[2], openMoney: () => toApp('money'),
planTitle: pl ? pl.title : '', planNote: pl ? pl.note : '',
addPlan: () => { if (pl && !pl.planned) toApp('addplan:0:' + pack({ id: pl.id })); }, planTxt: pl && pl.planned ? '✓ En el plan del grupo' : '+ Añadir al plan',
planBtn: 'margin-top: 4px; height: 32px; border-radius: 10px; border: none; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; transition: background .3s; ' + (pl && pl.planned ? 'background: #3DDC97; color: #0B1217; animation: cg-pop .35s ease both' : 'background: #26363F; color: #F2F5F3'),
spots: [], opts: [], pollNote: '',
canReact: ia, reactTxt: liked ? '❤ 1' : '♡', react: () => { this.setState({ likes: liked ? st.likes.filter((x) => x !== m.id) : st.likes.concat([m.id]) }); toApp('like:' + (liked ? 0 : 1) + ':' + pack({ id: m.id })); },
reactSt: 'align-self: flex-end; margin-top: 4px; height: 22px; min-width: 30px; border-radius: 11px; border: none; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; padding: 0 7px; ' + (liked ? 'background: #FF7AB6; color: #fff; animation: cg-pop .35s ease both' : 'background: rgba(255,255,255,.08); color: #9FB0B8'),
row: 'display: flex; gap: 8px; align-items: flex-end; animation: ' + (me ? 'cg-inR' : 'cg-inL') + ' .45s cubic-bezier(.2,.9,.3,1.1) both; ' + (me ? 'flex-direction: row-reverse' : ''),
av: av(ia ? '#13342A' : (m.c || '#FF8FB1'), 30) + (me ? '; display: none' : ''),
bub: 'max-width: 262px; display: flex; flex-direction: column; gap: 2px; padding: 9px 12px; border-radius: 18px; ' + (me ? 'background: linear-gradient(135deg, #2D5A6E, #24414F); border-bottom-right-radius: 4px' : ia ? 'background: linear-gradient(160deg, #164032, #13342A); border: 1px solid #2E6A52; border-bottom-left-radius: 4px; box-shadow: 0 8px 22px -14px #3DDC97' : 'background: #2A1E26; border-bottom-left-radius: 4px'),
nameSt: 'font-size: 11px; font-weight: 800; color: ' + (ia ? '#7FF0BF' : '#FFB3C9') + (me ? '; display: none' : '') };
});
const quick = QUICK.map((label, i) => ({ label, pick: () => this.send(label), st: 'height: 34px; padding: 0 12px; border-radius: 17px; border: 1px solid #2E6A52; background: #12201A; color: #BFE9D6; font-family: inherit; font-size: 12px; font-weight: 800; cursor: pointer; white-space: nowrap; flex-shrink: 0; animation: cg-in .4s ease ' + (i * 0.06).toFixed(2) + 's both' }));
const has = !!(st.draft && st.draft.trim());
const rec = !!E.rec;
const cols = ['#3DDC97', '#6CA8FF', '#FFB86B', '#FF8FB1', '#B69CFF', '#FFD166'];
const ST = ['Toca las estrellas', 'Sentimos que no haya ido bien', 'Gracias, nos ayuda a mejorar', 'Gracias, vamos a mejorar', '¡Nos alegra que te haya gustado!', '¡Genial! ¿Lo cuentas en Google Play?'];
const others = M.filter((x) => !x.me).map((x) => x.name);
const code = E.code || '';
return {
types, members, msgs, quick,
city: E.city || 'Vuestro viaje', day: E.day || '',
flyraIntro: (E.city ? E.city + '. ' : '') + 'Dime con quién vas y ajusto planes y cómo os repartís los gastos.',
back: () => toApp('back'),
stars: Array.from({ length: 8 }, (_, k) => 'position: absolute; left: ' + R(k + 1, 380).toFixed(0) + 'px; top: ' + R(k + 9, 820).toFixed(0) + 'px; width: 2px; height: 2px; border-radius: 1px; background: #fff; pointer-events: none; animation: cg-tw ' + (2 + R(k, 2)).toFixed(1) + 's ease-in-out ' + R(k + 4, 2).toFixed(1) + 's infinite'),
isType: st.stage === 'type', isChat: st.stage === 'chat', isEnd: st.stage === 'end',
startLabel: st.type === 'solo' ? 'Empezar con Flyra' : 'Crear chat · ' + tl[1], typeTip: TIP[st.type],
tipSt: 'position: relative; border-radius: 18px; background: #141E25; border: 1px solid #26363F; padding: 12px 14px; font-size: 13px; color: #DCE5E9; line-height: 1.45',
startChat: () => { this.done = true; this.picked = false; toApp('kind:0:' + pack({ k: st.type })); if (st.type === 'solo') return; this.setState({ stage: 'chat' }); this.scroll(); }, backType: () => { this.done = true; this.setState({ stage: 'type', type: E.kind || st.type }); },
typeLabel: tl[1], statusLine: E.typing ? 'Flyra está escribiendo…' : names(['Tú'].concat(others).concat(['Flyra'])),
thinking: THINK[st.think],
typing: !!E.typing,
draft: st.draft, hasDraft: has, noDraft: !has, rec, noRec: !rec,
inBorder: rec ? '#FF7A8A' : has ? '#3DDC97' : '#26363F',
onType: (e) => this.setState({ draft: e.target.value }),
onKey: (e) => { if (e.key === 'Enter') { e.preventDefault && e.preventDefault(); this.send(this.state.draft); } },
sendLabel: has ? 'Enviar' : 'Hablar',
sendOrMic: () => { if (has) { this.send(st.draft); return; } if (rec || E.typing) return; this.setState({ think: 4 }); toApp('mic'); },
sendSt: 'width: 50px; height: 50px; border-radius: 25px; border: none; display: flex; align-items: center; justify-content: center; cursor: pointer; flex-shrink: 0; transition: background .3s, transform .2s; ' + (rec ? 'background: #FF7A8A; animation: cg-fly 1s ease-in-out infinite' : 'background: linear-gradient(135deg, #7FF0BF, #3DDC97); box-shadow: 0 8px 20px rgba(61,220,151,.35)'),
waves: Array.from({ length: 12 }, (_, k) => 'width: 3px; height: 22px; border-radius: 2px; background: #FF7A8A; animation: cg-wave ' + (0.5 + (k % 4) * 0.15).toFixed(2) + 's ease-in-out ' + (k * 0.05).toFixed(2) + 's infinite'),
profile: !!st.profile, closeProfile: () => this.setState({ profile: false }),
chipsP: [['Más de 100 idiomas', '#12201A', '#BFE9D6'], ['Aprende vuestros gustos', '#15243A', '#BCD6FF'], ['No vende tus datos', '#221A33', '#DCCFFF']].map(([t, b, c], i) => ({ t, st: 'height: 30px; padding: 0 12px; border-radius: 15px; font-size: 12px; font-weight: 800; display: flex; align-items: center; background: ' + b + '; color: ' + c + '; animation: cg-pop .4s ease ' + (0.2 + i * 0.1).toFixed(1) + 's both' })),
invite: !!st.invite, openInvite: () => this.setState({ invite: true }), closeInvite: () => this.setState({ invite: false }),
code: code || '—', qr: E.qr || '', hasQr: !!E.qr,
codeHint: code ? 'Que lo escanee o lo escriba en su móvil' : 'El código lo tiene quien organiza el viaje',
guestSt: 'display: flex; gap: 10px; align-items: center; border-radius: 16px; padding: 10px 12px; transition: background .3s; background: #12201A; border: 1px solid #2E6A52',
addGuest: () => { this.setState({ invite: false }); if (code) toApp('share:0:' + pack({ c: code })); },
addLabel: code ? 'Compartir el código' : 'Cerrar',
finish: () => { this.done = true; this.setState({ stage: 'end', stars: 0 }); }, backChat: () => { this.setState({ stage: 'chat' }); this.scroll(); },
conf: st.stage === 'end' ? Array.from({ length: 26 }, (_, i) => 'position: absolute; top: 0; left: ' + ((i * 53) % 390) + 'px; width: ' + (6 + (i % 3) * 2) + 'px; height: ' + (10 + (i % 4) * 3) + 'px; border-radius: 2px; background: ' + cols[i % 6] + '; animation: cg-conf ' + (2.4 + (i % 5) * 0.4) + 's ease-in ' + (0.8 + (i % 7) * 0.15) + 's both') : [],
statsL: E.stats || [],
endTitle: (E.city || 'Vuestro viaje') + ', ¡qué viaje!',
memories: () => toApp('memories'),
starList: [1, 2, 3, 4, 5].map((n) => ({ label: n + ' estrellas', pick: () => { this.setState({ stars: n }); toApp('stars:' + n); }, fill: n <= st.stars ? '#FFD166' : 'transparent', stroke: n <= st.stars ? '#FFD166' : '#4A5C66', anim: n <= st.stars ? 'animation: cg-star .4s ease ' + (n * 0.06).toFixed(2) + 's both' : '' })),
starText: ST[st.stars], starTap: () => { if (st.stars === 5) toApp('play'); }
};
}
}
