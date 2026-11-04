// Ayuda: Flyra primero y, si hace falta, una persona. Las opciones sin
// contacto configurado no salen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/help/help_contacts.dart';

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

  testWidgets('sin socios configurados salen las cinco y avisan', (
    WidgetTester tester,
  ) async {
    await open(tester);
    expect(find.text('Ayuda'), findsOneWidget);
    expect(find.text('Pregunta a Flyra'), findsOneWidget);
    expect(find.text('La aerolínea o agencia donde compraste'), findsOneWidget);
    expect(find.text('Asistencia de tu seguro de viaje'), findsOneWidget);
    // Las cinco salen como en la maqueta; sin socio, avisan de que llega
    // pronto en vez de abrir nada.
    expect(find.text('Expertos en reclamaciones'), findsOneWidget);
    expect(find.text('Gestor de visados'), findsOneWidget);
    expect(find.text('Soporte de ECLIPTA'), findsOneWidget);
    await tester.tap(find.text('Que lo reclamen por mí'));
    await tester.pump();
    expect(find.textContaining('Aún no está disponible'), findsOneWidget);
    await tester.tap(find.text('La aerolínea o agencia donde compraste'));
    await tester.pumpAndSettle();

    // La primera está abierta: lleva a la Bóveda (billetes y reservas).
    await tester.tap(find.text('Abrir la Bóveda'));
    await tester.pumpAndSettle();
    expect(find.text('Bóveda'), findsWidgets);
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
    // Como en la maqueta, la de reclamaciones sale ya abierta.
    expect(find.textContaining('comisión'), findsOneWidget);
    await tester.tap(find.text('Que lo reclamen por mí'));
    await tester.pumpAndSettle();
    expect(opened.last.host, 'reclama.example');

    // La lista es larga: se baja hasta la última opción.
    await tester.scrollUntilVisible(find.text('Soporte de ECLIPTA'), 200);
    await tester.tap(find.text('Soporte de ECLIPTA'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Escribir al equipo'), 200);
    await tester.tap(find.text('Escribir al equipo'));
    await tester.pumpAndSettle();
    final Uri mail = opened.last;
    expect(mail.scheme, 'mailto');
    expect(mail.path, 'hola@nomadiq.app');
    expect(mail.toString(), isNot(contains('+')));
    expect(Uri.decodeComponent(mail.query), contains('ECLIPTA 1.0.0 · es'));
  });
}
