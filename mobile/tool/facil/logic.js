// La maqueta "Modo fácil" con tu viaje de verdad. La app pone los datos en
// window.ECL (ver lib/features/easy/easy_page.dart) y manda lo nuevo con
// window.ECLin({...}). Lo que tocas se le dice a la app con toApp('...').
const pad = (n) => (n < 10 ? '0' : '') + n;
class Component extends DCLogic {
constructor(props) {
super(props);
this.E = window.ECL || {};
this.state = { sheet: '', opt: this.E.help == null ? 0 : this.E.help, taxi: false, want: 0, n: 0 };
}
componentDidMount() {
window.ECLin = (d) => { Object.assign(this.E, d || {}); this.setState({ n: this.state.n + 1 }); };
}
listen() { const want = (this.E.flyN || 0) + 1; this.setState({ sheet: 'fly', want }); toApp('listen'); }
renderVals() {
const st = this.state;
const E = this.E;
const H = E.helpOpts || [];
const asked = E.help != null;
const helpOpts = H.map((label, i) => ({ label, on: st.opt === i ? 'true' : 'false', pick: () => this.setState({ opt: i }), style: 'min-height: 60px; border-radius: 18px; display: flex; align-items: center; gap: 14px; padding: 0 16px; font-family: inherit; font-size: 19px; font-weight: 800; color: #F2F5F3; cursor: pointer; text-align: left; transition: background .2s; ' + (st.opt === i ? 'border: 3px solid #FFB86B; background: #2A2418' : 'border: 2px solid #26363F; background: #141E25'), radio: 'width: 26px; height: 26px; border-radius: 13px; flex-shrink: 0; box-sizing: border-box; transition: border .2s; border: ' + (st.opt === i ? '8px solid #FFB86B' : '3px solid #4A5C66') }));
const family = (E.family || []).map((f, i) => ({ name: f.name, rel: f.rel, ini: (f.name || '?')[0].toUpperCase(),
pick: () => { this.setState({ sheet: '' }); toApp('call:' + i); },
video: (e) => { if (e && e.stopPropagation) e.stopPropagation(); this.setState({ sheet: '' }); toApp('video:' + i); },
av: 'width: 58px; height: 58px; border-radius: 29px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; font-size: 26px; font-weight: 800; color: #0B1217; background: ' + f.c,
btn: 'width: 56px; height: 56px; border-radius: 28px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; background: #3DDC97' }));
const bars = Array.from({ length: 9 }, (_, k) => 'width: 7px; height: 50px; border-radius: 4px; background: #3DDC97; transform-origin: center; animation: fz-bar ' + (0.7 + (k % 3) * 0.2).toFixed(1) + 's ease-in-out ' + (k * 0.08).toFixed(2) + 's infinite');
const answered = st.want > 0 && (E.flyN || 0) >= st.want;
const fl = E.flight || {};
const ho = E.hotel || {};
const T = E.t || {};
return {
helpOpts, family, bars,
day: E.day || '', hello: E.hello || '', normal: T.normal || '',
goNormal: () => toApp('normal'),
editTrip: () => toApp('edit'),
hasFlight: !!fl.time, noFlight: !fl.time,
flightK: fl.k || '', flightTime: fl.time || '', flightRoute: fl.route || '', gateLbl: fl.gateLbl || '', gate: fl.gate || '', leave: fl.leave || '', noTripTxt: T.noTrip || '', setTrip: T.setTrip || '',
tHotel: T.toHotel || '', tFamily: T.family || '', tPapers: T.papers || '', tFly: T.fly || '', tFlySub: T.flySub || '',
openPapers: () => toApp('papers'),
hotel: st.sheet === 'hotel', help: st.sheet === 'help', call: st.sheet === 'call', fly: st.sheet === 'fly',
hasHotel: !!ho.address, noHotel: !ho.address, noHotelTxt: T.noHotel || '',
hotelTitle: T.yourHotel || '', hotelName: ho.name || '', hotelAddr: ho.address || '', hotelLine: ho.name ? ho.name : ho.address || '', hotelLine2: ho.name ? ho.address : '',
walk: () => toApp('walk'), walkTxt: T.walk || '', taxiTxt: T.showTaxi || '', taxiTitle: T.taxiTitle || '', taxiPhrase: ho.phrase || '', backTxt: T.back || '',
taxiOn: !!st.taxi, taxiOff: !st.taxi,
showTaxi: () => this.setState({ taxi: true }), hideTaxi: () => this.setState({ taxi: false }),
openHotel: () => this.setState({ sheet: 'hotel', taxi: false }), openHelp: () => this.setState({ sheet: 'help', opt: asked ? E.help : st.opt }), openCall: () => this.setState({ sheet: 'call' }),
openFly: () => this.listen(), askAgain: () => this.listen(),
listening: !answered, answered,
listenTxt: T.listening || '', listenSub: T.listenSub || '', againTxt: T.again || '',
q: E.flyQ || '', hasQ: !!E.flyQ, a: E.flyA || '', hasAct: !!E.flyAct, act: E.flyAct || '', doAct: () => { this.setState({ sheet: '' }); toApp('act'); },
closeAll: () => { if (st.sheet === 'fly') toApp('stop'); this.setState({ sheet: '' }); },
noFamily: family.length === 0, noFamilyTxt: T.noFamily || '', addFamily: () => { this.setState({ sheet: '' }); toApp('family'); }, addFamilyTxt: T.addFamily || '',
whoCall: T.whoCall || '', callHint: T.callHint || '',
helpTitle: T.help || '', helpWhy: T.helpWhy || '', helpAsk: T.helpAsk || '', helpSend: T.helpSend || '', helpChange: T.helpChange || '',
asked, notAsked: !asked, helpDone: E.helpDone || '',
confirmHelp: () => toApp('help:' + st.opt), undoHelp: () => toApp('help:-1'), sendHelp: () => toApp('send'),
helpTile: asked ? (T.helpAsked || '') : (T.help || ''),
helpTileSt: 'display: flex; flex-direction: column; align-items: flex-start; justify-content: space-between; height: 138px; border-radius: 26px; padding: 16px; font-family: inherit; text-align: left; cursor: pointer; text-decoration: none; box-sizing: border-box; color: #F2F5F3; animation: fz-in .5s ease both; animation-delay: .19s; ' + (asked ? 'background: #1F3A2A; border: 2px solid #3DDC97' : 'background: #2A2418; border: 2px solid #8A6A2A')
};
}
}
