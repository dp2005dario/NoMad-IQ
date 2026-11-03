// Flutter lee este archivo antes de cada prueba de esta carpeta.
import 'dart:async';

import 'package:eclipta/core/motion.dart';
import 'package:eclipta/features/flyra/flyra_mini.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // En las pruebas, las animaciones de adorno se acaban (si no,
  // pumpAndSettle esperaría para siempre).
  Motion.forever = false;
  // Cada prueba empieza sin avisos de la mini Flyra.
  setUp(FlyraNotes.instance.reset);
  await testMain();
}
