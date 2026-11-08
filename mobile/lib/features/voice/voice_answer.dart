// Lo que contesta Flyra a una pregunta dicha en voz alta (o escrita): el
// texto (que también se lee en alto) y, si toca, un botón para hacerlo. Lo
// usan "Habla con Flyra" y el botón "Pregunta a Flyra" del Modo fácil.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import 'voice_intents.dart';

class VoiceAnswer {
  const VoiceAnswer(this.text, {this.action, this.onAction, this.icon});

  final String text;
  final String? action;
  final VoidCallback? onAction;
  final IconData? icon;
}

/// La respuesta a [text]: las preguntas típicas se contestan aquí mismo
/// (ver voice_intents.dart); lo demás se manda al chat de Flyra.
VoiceAnswer voiceAnswer(
  String text, {
  required AppLocalizations t,
  required String lang,
  required EasyTrip trip,
  required void Function(String route) go,
  required Future<void> Function() editTrip,
  required Future<bool> Function(Uri) openLink,
}) {
  final VoiceIntent? intent = matchIntent(text, lang);
  switch (intent) {
    case VoiceIntent.flight:
      final DateTime? dep = trip.departure;
      if (!trip.hasFlight || dep == null) {
        return VoiceAnswer(
          t.voiceNoFlight,
          action: t.voiceAddTrip,
          icon: Icons.edit_calendar_rounded,
          onAction: () => unawaited(editTrip()),
        );
      }
      final String date = DateFormat.MMMMEEEEd(lang).format(dep);
      final String time = DateFormat.Hm(lang).format(dep);
      final String? gate = trip.gate;
      final String base = t.voiceFlightAt(trip.from!, trip.to!, date, time);
      return VoiceAnswer(
        gate == null || gate.isEmpty ? base : '$base ${t.voiceGate(gate)}',
        action: t.airportTitle,
        icon: Icons.local_airport_rounded,
        onAction: () => go(Routes.airport(iata: trip.from, gate: gate)),
      );
    case VoiceIntent.hotel:
      final String? address = trip.hotelAddress;
      if (address == null) {
        return VoiceAnswer(
          t.voiceNoHotel,
          action: t.voiceAddTrip,
          icon: Icons.edit_calendar_rounded,
          onAction: () => unawaited(editTrip()),
        );
      }
      return VoiceAnswer(
        t.voiceHotel(trip.hotelName ?? address),
        action: t.voiceTakeMe,
        icon: Icons.directions_rounded,
        onAction: () => unawaited(openLink(directionsTo(address))),
      );
    case VoiceIntent.money:
      return VoiceAnswer(
        t.voiceMoney,
        action: t.voiceOpen,
        icon: Icons.receipt_long_rounded,
        onAction: () => go(Routes.money()),
      );
    case VoiceIntent.visa:
      return VoiceAnswer(
        t.voiceVisa,
        action: t.visaTitle,
        icon: Icons.verified_user_rounded,
        onAction: () => go(Routes.visa()),
      );
    case VoiceIntent.language:
      return VoiceAnswer(
        t.voiceLanguage,
        action: t.voiceOpen,
        icon: Icons.translate_rounded,
        onAction: () => go(Routes.language),
      );
    case VoiceIntent.sos:
      return VoiceAnswer(
        t.voiceSos,
        action: 'SOS',
        icon: Icons.emergency_rounded,
        onAction: () => go(Routes.sos),
      );
    case VoiceIntent.nearby:
      return VoiceAnswer(
        t.voiceNearby,
        action: t.voiceOpen,
        icon: Icons.near_me_rounded,
        onAction: () => go(Routes.nearby),
      );
    case VoiceIntent.translate:
      return VoiceAnswer(
        t.voiceTranslate,
        action: t.voiceOpen,
        icon: Icons.record_voice_over_rounded,
        onAction: () => go(Routes.assistant),
      );
    case VoiceIntent.drive:
      return VoiceAnswer(
        t.voiceDrive,
        action: t.voiceOpen,
        icon: Icons.directions_car_rounded,
        onAction: () => go(Routes.drive),
      );
    case null:
      return VoiceAnswer(
        t.voiceUnknown,
        action: t.voiceAskFlyra,
        icon: Icons.auto_awesome_rounded,
        onAction: () => go(Routes.flyra(question: text)),
      );
  }
}
