// Genera assets/geo/countries.txt: "País (en inglés, como en airports.txt)|código ISO".
// Con el código, el Vuelo 3D pone la bandera (emoji) y el nombre del país en
// el idioma del usuario (Intl.DisplayNames del navegador del móvil).
//
// Uso (desde mobile/tool/flight3d, con Node 20+):
//   npm install
//   node build_country_codes.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const countries = require('i18n-iso-countries');
countries.registerLocale(require('i18n-iso-countries/langs/en.json'));

// Nombres de OpenFlights que no coinciden con los oficiales.
const ALIASES = {
  Burma: 'MM', Syria: 'SY', 'Wake Island': 'UM', 'East Timor': 'TL',
  'Congo (Kinshasa)': 'CD', 'Congo (Brazzaville)': 'CG', 'Netherlands Antilles': 'CW',
  Brunei: 'BN', Moldova: 'MD', 'British Virgin Islands': 'VG', Laos: 'LA',
  'Johnston Atoll': 'UM', Micronesia: 'FM', 'Midway Islands': 'UM', Macau: 'MO',
  'Falkland Islands': 'FK', Swaziland: 'SZ', Macedonia: 'MK', 'Virgin Islands': 'VI',
};

const airports = readFileSync(new URL('../../assets/geo/airports.txt', import.meta.url), 'utf8');
const names = [...new Set(airports.split('\n').filter(Boolean).map((l) => l.split('|')[4]))].sort();
const lines = [];
for (const name of names) {
  const code = ALIASES[name] ?? countries.getAlpha2Code(name, 'en');
  if (!code) throw new Error(`sin código ISO: ${name}`);
  lines.push(`${name}|${code}`);
}
writeFileSync(new URL('../../assets/geo/countries.txt', import.meta.url), lines.join('\n') + '\n');
console.log(`${lines.length} países`);
