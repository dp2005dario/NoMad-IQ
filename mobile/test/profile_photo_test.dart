// La foto de perfil elegida en el móvil: guardado, datos rotos y cómo se ve.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/settings/profile_photo.dart';
import 'package:eclipta/widgets/user_avatar.dart';

void main() {
  test('decode entiende lo guardado y aguanta datos rotos', () {
    expect(ProfilePhotoChoice.decode('preset:2').preset, 2);
    expect(ProfilePhotoChoice.decode('file:/a/b.jpg').filePath, '/a/b.jpg');
    expect(ProfilePhotoChoice.decode('preset:99').isNone, isTrue);
    expect(ProfilePhotoChoice.decode('preset:x').isNone, isTrue);
    expect(ProfilePhotoChoice.decode('file:').isNone, isTrue);
    expect(ProfilePhotoChoice.decode(null).isNone, isTrue);
    expect(const ProfilePhotoChoice(preset: 1).encode(), 'preset:1');
  });

  testWidgets('mi avatar enseña el avatar elegido; el de otros no', (
    WidgetTester tester,
  ) async {
    ProfilePhotoController.instance.debugSet(
      const ProfilePhotoChoice(preset: 0),
    );
    addTearDown(
      () =>
          ProfilePhotoController.instance.debugSet(const ProfilePhotoChoice()),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: <Widget>[
            UserAvatar(name: 'Ana', isMe: true),
            UserAvatar(name: 'Luis'),
          ],
        ),
      ),
    );
    expect(find.byIcon(presetAvatars[0].icon), findsOneWidget);
    expect(find.text('L'), findsOneWidget);

    ProfilePhotoController.instance.debugSet(const ProfilePhotoChoice());
    await tester.pump();
    expect(find.text('A'), findsOneWidget);
  });
}
