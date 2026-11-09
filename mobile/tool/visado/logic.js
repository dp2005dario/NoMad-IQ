// La maqueta "Visado" con tus datos. La app pone los datos en window.ECL
// (ver lib/features/visa/visa_page.dart) y manda lo nuevo con
// window.ECLin({...}). Lo que tocas se le dice a la app con toApp('...'):
// "from" / "to" eligen país, "read" lee tu pasaporte de la Bóveda,
// "manual" sigue sin leerlo, "copy:<n>" copia un dato, "next" pasa a
// enviar, "official" abre la web oficial, "vault" abre la Bóveda y
// "flyHide" cierra el bocadillo de Flyra.
// ----
const TONE = { ok: ['#12291F', '#2E8A5E', '#3DDC97'], info: ['#121E2E', '#2E5A8A', '#6CA8FF'], warn: ['#2A2114', '#5A4527', '#FFB86B'], bad: ['#2A1416', '#7A3A3F', '#FF6B6B'], muted: ['#141E25', '#26363F', '#9FB0B8'] };
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { n: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
renderVals() {
const accent = this.props.accent ?? '#3DDC97';
const E = this.E;
const T = E.t || {};
const step = E.step || 0;
const steps = (T.steps || []).map((text, i) => ({ text, bar: 'height: 6px; border-radius: 3px; display: block; background: ' + (i <= step ? '#6CA8FF' : '#26363F'), label: 'font-size: 11px; font-weight: 800; color: ' + (i <= step ? '#F2F5F3' : '#6F8490') }));
const SRC = { pass: '#6CA8FF', you: '#FFB86B' };
const fields = (E.fields || []).map((f, i) => ({ k: f.k, v: f.v || '—', from: f.from, canCopy: !!f.v, aria: f.k + (f.v ? ' · ' + (T.copy || '') : ''),
copy: () => { if (f.v) toApp('copy:' + i); },
style: 'display: flex; align-items: center; gap: 10px; border-radius: 14px; background: #141E25; border: 1px solid ' + (f.warn ? '#5A4527' : '#26363F') + '; padding: 9px 12px; flex-shrink: 0; cursor: ' + (f.v ? 'pointer' : 'default') + '; animation: nq-in 0.3s ease ' + (i * 0.05) + 's both',
src: 'height: 22px; border-radius: 11px; padding: 0 8px; font-size: 10px; font-weight: 800; display: flex; align-items: center; flex-shrink: 0; color: #0B1217; background: ' + (SRC[f.src] || accent) }));
const v = E.verdict || null;
const tone = TONE[(v && v.tone) || 'muted'] || TONE.muted;
const fly = E.fly || null;
return {
accent, steps, fields,
back: () => toApp('back'), backTxt: T.back || '',
title: E.title || '', sub: E.sub || '',
pickFrom: () => toApp('from'), pickTo: () => toApp('to'),
fromH: T.fromH || '', toH: T.toH || '', fromAria: T.fromH || '', toAria: T.toH || '',
fromTxt: E.fromTxt || '', toTxt: E.toTxt || '',
pillSt: 'flex: 1; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; gap: 1px; border-radius: 14px; border: 1px solid #26363F; background: #141E25; color: #F2F5F3; font-family: inherit; padding: 7px 12px; cursor: pointer; text-align: left',
hasVerdict: !!v, verdictH: v ? v.h : '', verdictDays: v ? v.days || '' : '', verdictP: v ? v.p : '', source: v ? v.source || '' : '',
verdictSt: 'flex-shrink: 0; display: flex; flex-direction: column; gap: 4px; border-radius: 16px; padding: 10px 12px; animation: nq-pop 0.4s ease both; color: ' + tone[2] + '; background: ' + tone[0] + '; border: 1px solid ' + tone[1],
hasNote: !!E.note, note: E.note || '',
apply: !!E.apply,
s0: !!E.apply && step === 0, s1: !!E.apply && step === 1, s2: !!E.apply && step === 2,
readH: T.readH || '', readP: T.readP || '',
scanLabel: E.reading ? (T.reading || '') : (T.read || ''),
scan: () => { if (!E.reading) toApp('read'); },
manual: () => toApp('manual'), manualTxt: T.manual || '',
youAnswer: E.youAnswer || '', allGood: T.allGood || '', next: () => toApp('next'),
readyH: T.readyH || '', readyP: E.readyP || '',
tipWait: T.tipWait || '', tipSave: T.tipSave || '', tipOfficial: T.tipOfficial || '',
hasOfficial: !!E.hasOfficial, official: () => toApp('official'), officialTxt: T.official || '',
saveApproval: () => toApp('vault'), saveTxt: T.save || '',
flyOn: !!fly,
flyTitle: fly ? fly.title : '', flyText: fly ? fly.text : '',
flyRetry: () => toApp('read'), flyRetryTxt: fly ? fly.retry : '',
flyAlt: () => toApp('vault'), flyAltTxt: fly ? fly.alt : '',
flyHide: () => toApp('flyHide')
};
}
}
