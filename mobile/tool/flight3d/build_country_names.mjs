// Genera assets/geo/country_names.txt: el nombre de cada país en cada idioma
// de la app. Lo usa la pantalla Visado para enseñar "Estados Unidos" en vez
// de "US", sin red y en tu idioma.
//
// Primera línea: "iso3 en ar de...". Luego "ES|ESP|Spain|إسبانيا|Spanien|...":
// el código de tres letras (ESP) es el que viene en la zona MRZ del pasaporte
// (las dos líneas con <<<< de abajo), así sabemos tu nacionalidad.
//
// Los idiomas salen de los archivos app_XX.arb de lib/l10n: cuando la app
// tenga más idiomas, basta con volver a ejecutarlo.
//
// Uso (desde mobile/tool/flight3d, con Node 20+):
//   npm install
//   node build_country_names.mjs
import { readdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const countries = require('i18n-iso-countries');

const l10n = new URL('../../lib/l10n/', import.meta.url);
const langs = readdirSync(l10n)
  .map((f) => /^app_([a-z]{2,3})\.arb$/.exec(f)?.[1])
  .filter(Boolean)
  .sort((a, b) => (a === 'en' ? -1 : b === 'en' ? 1 : a.localeCompare(b)));
for (const l of langs) countries.registerLocale(require(`i18n-iso-countries/langs/${l}.json`));

const codes = Object.keys(countries.getAlpha2Codes()).sort();
// "|" separa columnas: si un nombre lo tuviera, se rompería el archivo.
const clean = (s) => (s ?? '').replaceAll('|', ' ').trim();
const lines = [["iso3", ...langs].join(" ")];
for (const code of codes) {
  // {select: 'official'} daría "Reino de España": queremos el nombre corto.
  lines.push([code, countries.alpha2ToAlpha3(code) ?? "", ...langs.map((l) => clean(countries.getName(code, l)))].join('|'));
}
writeFileSync(new URL('../../assets/geo/country_names.txt', import.meta.url), lines.join('\n') + '\n');
console.log(`${codes.length} países × ${langs.length} idiomas`);
