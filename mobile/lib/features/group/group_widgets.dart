// Piezas pequeñas que comparten las pantallas de Grupo: los nombres de los
// gustos en cada idioma, las "caritas" de los miembros y el estado de un viaje.
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/user_avatar.dart';
import 'group_api.dart';

/// Cada gusto ("beach") en el idioma de la persona ("Playa").
/// Si el servidor trae uno que esta versión de la app no conoce, se enseña
/// tal cual en vez de romper la pantalla.
String tagLabel(AppLocalizations t, String tag) => switch (tag) {
  'beach' => t.groupTagBeach,
  'museums' => t.groupTagMuseums,
  'nightlife' => t.groupTagNightlife,
  'mountains' => t.groupTagMountains,
  'food' => t.groupTagFood,
  'nature' => t.groupTagNature,
  'history' => t.groupTagHistory,
  'shopping' => t.groupTagShopping,
  'relax' => t.groupTagRelax,
  'adventure' => t.groupTagAdventure,
  'sport' => t.groupTagSport,
  'romantic' => t.groupTagRomantic,
  'kids' => t.groupTagKids,
  'early-starts' => t.groupTagEarlyStarts,
  'long-walks' => t.groupTagLongWalks,
  'crowds' => t.groupTagCrowds,
  _ => tag,
};

/// Colores de las caritas, como en la maqueta (cada persona el suyo).
const List<Color> _faces = <Color>[
  NomadColors.group,
  NomadColors.safety,
  NomadColors.flights,
  NomadColors.money,
  NomadColors.mint,
  Color(0xFFFF7EB6),
  Color(0xFF7FE0E6),
  Color(0xFFE6D86B),
];

/// El nombre que se enseña de un miembro: el suyo, "Tú" o su alias.
String memberName(AppLocalizations t, TripMember m) =>
    m.me ? t.groupYou : (m.name ?? m.alias);

/// Una carita redonda con la inicial y una marca verde si ya envió lo suyo.
class MemberFace extends StatelessWidget {
  const MemberFace({
    super.key,
    required this.member,
    required this.index,
    this.size = 40,
  });

  final TripMember member;
  final int index;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String name = memberName(t, member);
    // "characters" cuenta letras como las ve una persona (también emoji o
    // letras con tilde compuestas), no trozos de memoria.
    return Semantics(
      label: member.submitted ? t.groupMemberReady(name) : name,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // Foto si la hay; si no, la inicial sobre el color de siempre.
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: NomadColors.background, width: 3),
              ),
              child: UserAvatar(
                name: name,
                photoUrl: member.photoUrl,
                size: size - 6,
                color: _faces[index % _faces.length],
              ),
            ),
            if (member.submitted)
              PositionedDirectional(
                end: -2,
                bottom: -2,
                child: Container(
                  decoration: const BoxDecoration(
                    color: NomadColors.background,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(1),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: size * 0.4,
                    color: NomadColors.mint,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Las caritas de todo el grupo, una encima de otra como en la maqueta.
class MemberFaces extends StatelessWidget {
  const MemberFaces({super.key, required this.members, this.size = 36});

  final List<TripMember> members;
  final double size;

  @override
  Widget build(BuildContext context) {
    final double step = size * 0.72;
    return SizedBox(
      height: size,
      width: size + step * (members.length - 1),
      child: Stack(
        children: <Widget>[
          for (int i = 0; i < members.length; i++)
            PositionedDirectional(
              start: step * i,
              child: MemberFace(member: members[i], index: i, size: size),
            ),
        ],
      ),
    );
  }
}

/// El estado del viaje en una etiqueta de color.
class TripStatusChip extends StatelessWidget {
  const TripStatusChip({super.key, required this.trip});

  final GroupTrip trip;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final (String label, Color color) = switch (trip.status) {
      TripStatus.collecting => (
        t.groupStatusCollecting(trip.ready, trip.members.length),
        NomadColors.money,
      ),
      TripStatus.queued ||
      TripStatus.running => (t.groupStatusWorking, NomadColors.group),
      TripStatus.concluded => (t.groupStatusConcluded, NomadColors.mint),
      TripStatus.expired => (t.groupStatusExpired, NomadColors.textMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
