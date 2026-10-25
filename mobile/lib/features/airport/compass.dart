// La brújula del móvil (paquete flutter_compass): hacia dónde miras, en
// grados (0 = norte). null = este móvil no tiene brújula.
import 'package:flutter_compass/flutter_compass.dart';

Stream<double?> deviceCompass() {
  final Stream<CompassEvent>? events = FlutterCompass.events;
  if (events == null) return Stream<double?>.value(null);
  return events.map((CompassEvent e) => e.heading);
}
