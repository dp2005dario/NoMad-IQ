// Prueba del HUD del vuelo: enseña los códigos, los textos y mueve el avión.
import 'package:eclipta/features/route/flight_hud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('enseña origen, destino y los dos datos', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FlightHud(
            fromCode: 'MAD',
            toCode: 'HND',
            progress: 0.5,
            traveled: 'Recorrido: 5.400 km',
            remaining: 'Quedan 6 h',
          ),
        ),
      ),
    );
    expect(find.text('MAD'), findsOneWidget);
    expect(find.text('HND'), findsOneWidget);
    expect(find.text('Recorrido: 5.400 km'), findsOneWidget);
    expect(find.text('Quedan 6 h'), findsOneWidget);
    expect(find.byIcon(Icons.flight_rounded), findsOneWidget);
  });

  testWidgets('un progreso fuera de rango no rompe la barra', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FlightHud(
            fromCode: 'A',
            toCode: 'B',
            progress: 1.7,
            traveled: 'x',
            remaining: 'y',
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
