// El clima de adorno del mapa: se dibuja sin errores y no tapa los toques.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/map/weather_overlay.dart';

void main() {
  for (final MapWeather w in MapWeather.values) {
    testWidgets('clima $w se dibuja y deja pasar los toques', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => taps++,
                  child: const ColoredBox(color: Colors.green),
                ),
              ),
              Positioned.fill(child: WeatherOverlay(weather: w)),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tapAt(const Offset(100, 100));
      expect(taps, 1);
    });
  }
}
