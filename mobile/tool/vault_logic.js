class Component extends DCLogic {
constructor(props) {
super(props);
// Dónde empieza: lo dice la app (cerrada, abriéndose, abierta, leyendo un
// PDF...). Las tarjetas con foto llevan "gN" y las que tienen datos "fN".
const E = window.ECL || {};
const sl = E.slots || {};
let got = ' ', fil = ' ';
for (const k in sl) {
if (sl[k].g) got += 'g' + k + ' ';
if (sl[k].f) fil += 'f' + k + ' ';
}
this.state = { phase: E.phase || 'locked', scan: E.scan || '', sd: E.sd || 1, src: 'cam', bad: E.scan === 'pdferr', got: got, fil: fil };
if (this.state.phase === 'opening') this.t1 = setTimeout(() => this.setState({ phase: 'open' }), 9700);
}
componentWillUnmount() { clearTimeout(this.t1); }
has(n) { return this.state.got.indexOf(' g' + n + ' ') >= 0 || this.state.fil.indexOf(' f' + n + ' ') >= 0; }
openAdd(n) {
if (this.state.phase !== 'open' || this.state.scan) return;
// Una tarjeta ya guardada se abre para verla; una vacía, para añadirla.
if (this.has(n)) { toApp('view:' + n); return; }
this.setState({ scan: 'menu', sd: n });
}
renderVals() {
const st = this.state;
const vals = {
phaseClass: 'ph-' + st.phase + (st.scan ? ' sc-on sc-' + st.scan : '') + ' scd' + st.sd + ' src-' + st.src + (st.bad ? ' pbad' : '') + st.got + st.fil,
prompt: st.phase === 'locked' ? 'Pon tu huella para abrir' : 'Abriendo la bóveda…',
// La huella de verdad la pide la app; si es buena, vuelve con la puerta
// abriéndose.
unlock: () => { if (st.phase === 'locked') toApp('unlock'); },
lock: () => { clearTimeout(this.t1); this.setState({ phase: 'locked', scan: '' }); toApp('lock'); },
addNext: () => {
for (let n = 1; n <= 13; n++) {
if (!this.has(n)) { this.openAdd(n); return; }
}
this.openAdd(1);
},
// Cámara, galería y PDF: los del móvil.
pickCam: () => { this.setState({ scan: '' }); toApp('cam:' + st.sd); },
pickGal: () => { this.setState({ scan: '' }); toApp('gal:' + st.sd); },
pickPdf: () => { this.setState({ scan: '' }); toApp('pdf:' + st.sd); },
retryFile: () => { this.setState({ scan: '', bad: false }); toApp('pdf:' + st.sd); },
pickFileOk: () => {},
pickFileBad: () => {},
pickForm: () => { this.setState({ scan: 'form', bad: false }); },
saveData: () => {
const v = st.scan === 'form' ? formValues(st.sd) : foundValues();
this.setState({ scan: '' });
toApp('save:' + st.sd + ':' + pack(v));
},
cancelScan: () => { this.setState({ scan: '', bad: false }); toApp('cancel'); }
};
for (let n = 1; n <= 13; n++) vals['add' + n] = () => this.openAdd(n);
return vals;
}
}
