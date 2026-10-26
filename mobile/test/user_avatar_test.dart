// UserAvatar: foto si hay, inicial si no. Sin internet: imagen falsa.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/widgets/user_avatar.dart';

// PNG de 1x1 píxel, escrito a mano para no bajar nada.
final MemoryImage _fake = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  ),
);

Widget _app(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  tearDown(() => UserAvatar.debugImageFactory = null);

  test('solo https y dominios de confianza', () {
    expect(isTrustedPhotoUrl('https://lh3.googleusercontent.com/a/x'), isTrue);
    expect(isTrustedPhotoUrl('http://lh3.googleusercontent.com/a'), isFalse);
    expect(isTrustedPhotoUrl('https://evil.example.com/a.png'), isFalse);
    expect(isTrustedPhotoUrl('https://googleusercontent.com.evil.io/a'), isFalse);
    expect(isTrustedPhotoUrl(null), isFalse);
  });

  testWidgets('sin foto enseña la inicial', (WidgetTester tester) async {
    await tester.pumpWidget(_app(const UserAvatar(name: 'darío')));
    expect(find.text('D'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('sin nombre enseña el icono', (WidgetTester tester) async {
    await tester.pumpWidget(_app(const UserAvatar(name: null)));
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
  });

  testWidgets('con foto usa la imagen (falsa)', (WidgetTester tester) async {
    UserAvatar.debugImageFactory = (String url) => _fake;
    await tester.pumpWidget(
      _app(const UserAvatar(name: 'Darío', photoUrl: 'https://lh3.googleusercontent.com/a')),
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('dominio desconocido: ni se intenta, sale la inicial', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(const UserAvatar(name: 'Darío', photoUrl: 'https://evil.example.com/a.png')),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('D'), findsOneWidget);
  });
}
