// Avisos: el historial que vive solo en el móvil.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';
import 'package:nomadiq/features/push/notice_log.dart';
import 'package:nomadiq/features/push/push_notice.dart';

import 'helpers.dart';

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

  testWidgets('pestañas por tipo; tocar un aviso abre su pantalla', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore prefs = MemorySettingsStore();
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
      services: fakeServices(session, gateway: g, prefs: prefs),
    );
    await tester.tap(find.byTooltip('Avisos'));
    await tester.pumpAndSettle();
    expect(find.text('Chollo'), findsOneWidget);
    expect(find.text('Estás en Sol'), findsOneWidget);

    await tester.tap(find.text('Seguridad'));
    await tester.pumpAndSettle();
    expect(find.text('Chollo'), findsNothing);
    await tester.tap(find.text('Cuidado'));
    await tester.pumpAndSettle();
    expect(find.text('Mi pasaporte'), findsOneWidget);
  });
}
