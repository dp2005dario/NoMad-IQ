// El WebView de las pantallas: el "acelerador" que se pone a cada página y
// que la app de verdad deja a cada pantalla su propio WebScene (con puente).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/route/web_scene.dart';

void main() {
  test('el acelerador va justo después de <head>', () {
    final String html = withPrelude(
      '<html><head><title>x</title></head></html>',
    );
    expect(html.indexOf('__eclVis'), greaterThan(html.indexOf('<head>')));
    expect(html.indexOf('__eclVis'), lessThan(html.indexOf('<title>')));
    expect(withPrelude('<p>sin head</p>'), startsWith('<script>'));
  });

  test(
    'la app no cambia el WebView de las pantallas (perderían el puente)',
    () {
      // Si main.dart pusiera "webScene:", ninguna pantalla podría actualizarse
      // sin recargar (Ajustes, idioma, contactos de emergencia...).
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main, isNot(contains('webScene:')));
      expect(main, contains('scene3d:'));
    },
  );

  test(
    'un aviso antes de que cargue la página se guarda en el puente',
    () async {
      final WebSceneBridge bridge = WebSceneBridge();
      await bridge.run('window.x=1');
      expect(bridge.sent, <String>['window.x=1']);
    },
  );
}
