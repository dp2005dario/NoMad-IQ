// Avisos: el historial que vive solo en el móvil.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/passport/passport_screen.dart';
import 'package:eclipta/features/push/notice_log.dart';
import 'package:eclipta/features/push/notices_page.dart';
import 'package:eclipta/features/push/notices_screen.dart';
import 'package:eclipta/features/push/push_notice.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

NoticeEntry entry(PushKind kind, String title, int minute, {String? route}) =>
    NoticeEntry(
      kind: kind,
      title: title,
      body: 'Texto de $title',
      at: DateTime.utc(2026, 10, 24, 10, minute),
      route: route,
    );

void main() {
  test('guarda los 100 últimos, el más nuevo primero', () async {
    final MemorySettingsStore prefs = MemorySettingsStore();
    final NoticeLog log = NoticeLog(prefs);
    for (int i = 0; i < 105; i++) {
      await log.add(
        NoticeEntry(
          kind: PushKind.fareAlert,
          title: 'n$i',
          body: '',
          at: DateTime.utc(2026).add(Duration(minutes: i)),
        ),
      );
    }
    final List<NoticeEntry> all = log.all();
    expect(all, hasLength(NoticeLog.max));
    expect(all.first.title, 'n104');
    await log.clear();
    expect(log.all(), isEmpty);
  });

  test('una ruta de fuera o un tipo desconocido no se aceptan', () {
    final MemorySettingsStore prefs = MemorySettingsStore();
    prefs.data[LocalData.noticeLog] = jsonEncode(<Object?>[
      <String, Object?>{
        'kind': 'fareAlert',
        'title': 'a',
        'body': 'b',
        'at': '2026-10-24T10:00:00Z',
        'route': '//malo.example',
      },
      <String, Object?>{
        'kind': 'otro',
        'title': 'a',
        'body': 'b',
        'at': '2026-10-24T10:00:00Z',
      },
    ]);
    final List<NoticeEntry> all = NoticeLog(prefs).all();
    expect(all.single.route, isNull);
  });

  testWidgets('tu historial en la maqueta; tocar un aviso abre su pantalla', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore prefs = MemorySettingsStore();
    final m.PageSpy spy = m.PageSpy();
    final NoticeLog log = NoticeLog(prefs);
    await log.add(entry(PushKind.zoneAudioguide, 'Estás en Sol', 1));
    await log.add(
      entry(PushKind.zoneSafety, 'Cuidado', 2, route: Routes.passport),
    );
    await log.add(entry(PushKind.fareAlert, 'Chollo', 3));
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.home,
      services: fakeServices(
        session,
        gateway: g,
        prefs: prefs,
        webScene: spy.build,
      ),
    );
    // Los Avisos están dentro de Ajustes (se abre con tu foto en el Mapa):
    // "Historial de avisos" en su página.
    // Ajustes se abre con tu foto, arriba en el Mapa (como en la maqueta).
    await tester.tap(find.text('Mapa'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Tu foto de perfil y ajustes'));
    await tester.pumpAndSettle();
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    spy.to('ECLIPTA · Ajustes')('notices');
    await tester.pumpAndSettle();
    await spy.wait(
      tester,
      () => spy.pages.any((String h) => h.contains('ECLIPTA · Avisos')),
    );
    await tester.pumpAndSettle();
    // La maqueta con el historial de verdad (el más nuevo primero).
    final Map<String, Object?> d = spy.data(
      NoticesScreen.lastBridge!,
      title: 'ECLIPTA · Avisos',
    );
    final List<Object?> items = d['items']! as List<Object?>;
    expect(
      <Object?>[
        for (final Object? i in items) (i! as Map<String, Object?>)['title'],
      ],
      <String>['Chollo', 'Cuidado', 'Estás en Sol'],
    );
    expect(
      <Object?>[
        for (final Object? i in items) (i! as Map<String, Object?>)['kind'],
      ],
      <String>['flight', 'safety', 'zone'],
    );
    expect(d['tabs'], <String>['Todos', 'Zonas', 'Vuelos', 'Grupo']);

    // Tocar "Cuidado" abre su pantalla.
    spy.to('ECLIPTA · Avisos')('open:1');
    await tester.pumpAndSettle();
    expect(find.byType(PassportScreen), findsOneWidget);
  });

  test('la hora: de hoy, de ayer o la fecha', () {
    final DateTime now = DateTime(2026, 11, 8, 18);
    expect(noticeTime(DateTime(2026, 11, 8, 9, 5), now, 'Ayer'), '09:05');
    expect(noticeTime(DateTime(2026, 11, 7, 23), now, 'Ayer'), 'Ayer');
    expect(noticeTime(DateTime(2026, 10, 24, 10), now, 'Ayer'), '24/10');
    expect(noticeDrawing(PushKind.groupChat), 'group');
    expect(noticeDrawing(PushKind.airportArrival), 'flight');
  });
}
