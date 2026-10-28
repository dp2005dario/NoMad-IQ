// Pruebas del globo del buscador: la matemática de la proyección y que el
// dibujo no falla.
import 'dart:typed_data';

import 'package:eclipta/features/flights/search_globe.dart';
import 'package:eclipta/features/route/geo.dart';
import 'package:eclipta/features/route/world_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('projectOrtho', () {
    test('el punto del centro cae en el medio y se ve', () {
      final p = projectOrtho(const LatLon(40, -3), const LatLon(40, -3));
      expect(p.x, closeTo(0, 1e-9));
      expect(p.y, closeTo(0, 1e-9));
      expect(p.front, isTrue);
    });

    test('el lado opuesto del planeta queda por detrás', () {
      final p = projectOrtho(const LatLon(-40, 177), const LatLon(40, -3));
      expect(p.front, isFalse);
    });

    test('lo que está al este cae a la derecha', () {
      final p = projectOrtho(const LatLon(0, 30), const LatLon(0, 0));
      expect(p.x, greaterThan(0));
      expect(p.front, isTrue);
    });
  });

  testWidgets('el globo se dibuja con y sin aeropuertos', (tester) async {
    final WorldData world = await _tinyWorld();
    final Airport madrid = world.airports['MAD']!;
    for (final Airport? to in <Airport?>[null, madrid]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchGlobe(world: world, to: to),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
}

/// Un mundo de mentira con un solo triángulo y Madrid.
Future<WorldData> _tinyWorld() async {
  final ByteData data = ByteData(4 + 4 + 4 + 3 * 4);
  'NQW1'.codeUnits.asMap().forEach((i, c) => data.setUint8(i, c));
  data.setUint32(4, 1, Endian.little);
  data.setUint32(8, 3, Endian.little);
  const List<int> pts = <int>[-100, 400, 0, 450, -50, 380];
  for (int i = 0; i < pts.length; i++) {
    data.setInt16(12 + i * 2, pts[i], Endian.little);
  }
  return WorldData.test(
    WorldShapes.parse(data),
    Airports.parse('MAD|40.472|-3.563|Madrid|Spain|Europe/Madrid\n'),
  );
}
