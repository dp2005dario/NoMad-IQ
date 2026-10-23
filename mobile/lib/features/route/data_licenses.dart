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
    yield const LicenseEntryWithLineBreaks(
      <String>['three.js (Vuelo 3D)'],
      'The MIT License\n\nCopyright © 2010-2023 three.js authors\n\n'
      'Permission is hereby granted, free of charge, to any person obtaining '
      'a copy of this software and associated documentation files (the '
      '"Software"), to deal in the Software without restriction, including '
      'without limitation the rights to use, copy, modify, merge, publish, '
      'distribute, sublicense, and/or sell copies of the Software, and to '
      'permit persons to whom the Software is furnished to do so, subject to '
      'the following conditions:\n\nThe above copyright notice and this '
      'permission notice shall be included in all copies or substantial '
      'portions of the Software.\n\nTHE SOFTWARE IS PROVIDED "AS IS", '
      'WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT '
      'LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR '
      'PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR '
      'COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, '
      'WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT '
      'OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN '
      'THE SOFTWARE.',
    );
  });
}
