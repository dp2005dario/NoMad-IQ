// Las licencias de los DATOS que lleva la app (no del código): aparecen en
// Ajustes → Licencias junto a las de las librerías. La ODbL de OpenFlights
// exige citar de dónde salen los aeropuertos.
import 'package:flutter/foundation.dart';

void registerDataLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      <String>['Natural Earth (mapa del mundo)'],
      'Made with Natural Earth. Free vector and raster map data @ '
      'naturalearthdata.com. Public domain.',
    );
    yield const LicenseEntryWithLineBreaks(
      <String>['world-atlas'],
      'Copyright 2013-2019 Michael Bostock\n\n'
      'Permission to use, copy, modify, and/or distribute this software for '
      'any purpose with or without fee is hereby granted, provided that the '
      'above copyright notice and this permission notice appear in all '
      'copies.\n\nTHE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS '
      'ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED '
      'WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE '
      'AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL '
      'DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR '
      'PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER '
      'TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR '
      'PERFORMANCE OF THIS SOFTWARE.',
    );
    yield const LicenseEntryWithLineBreaks(
      <String>['OpenFlights (aeropuertos)'],
      'Airport data from OpenFlights (https://openflights.org/data.html), '
      'made available under the Open Database License (ODbL) v1.0: '
      'https://opendatacommons.org/licenses/odbl/1-0/. Based on data from '
      'OurAirports (public domain).',
    );
  });
}
