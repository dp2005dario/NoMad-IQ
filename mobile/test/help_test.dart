// Ayuda: Flyra primero y, si hace falta, una persona. Las opciones sin
// contacto configurado no salen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/help/help_contacts.dart';

import 'helpers.dart';

void main() {
  Future<List<Uri>> open(
    WidgetTester tester, {
    HelpContacts help = const HelpContacts(),
  }) async {
    final FakeGateway g = FakeGateway();
    final SessionController session = await signedInSession(g);
    final List<Uri> opened = <Uri>[];
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.help,
      services: fakeServices(
        session,
        gateway: g,
        help: help,
        openLink: (Uri u) async {
          opened.add(u);
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  testWidgets('sin socios configurados solo salen aerolínea y seguro', (
    WidgetTester tester,
  ) async {
    await open(tester);
    expect(find.text('Ayuda'), findsOneWidget);
    expect(find.text('Pregunta a Flyra'), findsOneWidget);
    expect(find.text('La aerolínea o agencia donde compraste'), findsOneWidget);
    expect(find.text('Asistencia de tu seguro de viaje'), findsOneWidget);
    expect(find.text('Expertos en reclamaciones'), findsNothing);
    expect(find.text('Gestor de visados'), findsNothing);
    expect(find.text('Soporte de NomadIQ'), findsNothing);

    // La primera está abierta: lleva a Papeles.
    await tester.tap(find.text('Ver mis derechos'));
    await tester.pumpAndSettle();
    expect(find.text('Papeles y derechos'), findsOneWidget);
  });

  testWidgets('con socios: avisan de la comisión y abren su web', (
    WidgetTester tester,
  ) async {
    final List<Uri> opened = await open(
      tester,
      help: HelpContacts(
        supportEmail: 'hola@nomadiq.app',
        claimsUrl: Uri.parse('https://reclama.example/?ref=nq'),
        visaUrl: Uri.parse('https://visados.example'),
      ),
    );
    await tester.tap(find.text('Expertos en reclamaciones'));
    await tester.pumpAndSettle();
    expect(find.textContaining('comisión'), findsOneWidget);
    await tester.tap(find.text('Que lo reclamen por mí'));
    await tester.pumpAndSettle();
    expect(opened.last.host, 'reclama.example');

    // La lista es larga: se baja hasta la última opción.
    await tester.scrollUntilVisible(find.text('Soporte de NomadIQ'), 200);
    await tester.tap(find.text('Soporte de NomadIQ'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Escribir al equipo'), 200);
    await tester.tap(find.text('Escribir al equipo'));
    await tester.pumpAndSettle();
    final Uri mail = opened.last;
    expect(mail.scheme, 'mailto');
    expect(mail.path, 'hola@nomadiq.app');
    expect(mail.toString(), isNot(contains('+')));
    expect(Uri.decodeComponent(mail.query), contains('NomadIQ 1.0.0 · es'));
  });
}
