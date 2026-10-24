// Piezas que comparten las pantallas de la Bóveda: el color y la letra de
// cada tipo de documento, su nombre traducido y la línea de caducidad.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'vault.dart';

/// Faltan menos de estos días para caducar: se avisa en naranja (muchos
/// países piden 6 meses de validez del pasaporte para entrar).
const int expiresSoonDays = 180;

Color kindColor(DocKind k) => switch (k) {
  DocKind.passport => NomadColors.flights,
  DocKind.idCard => NomadColors.money,
  DocKind.boarding => NomadColors.flights,
  DocKind.insurance => NomadColors.mint,
  DocKind.booking => NomadColors.group,
  DocKind.visa => const Color(0xFF7FE0E6),
  DocKind.medical => NomadColors.safety,
  DocKind.other => NomadColors.textMuted,
};

IconData kindIcon(DocKind k) => switch (k) {
  DocKind.passport => Icons.menu_book_rounded,
  DocKind.idCard => Icons.badge_rounded,
  DocKind.boarding => Icons.airplane_ticket_rounded,
  DocKind.insurance => Icons.health_and_safety_rounded,
  DocKind.booking => Icons.hotel_rounded,
  DocKind.visa => Icons.verified_rounded,
  DocKind.medical => Icons.medical_information_rounded,
  DocKind.other => Icons.description_rounded,
};

String kindLabel(AppLocalizations t, DocKind k) => switch (k) {
  DocKind.passport => t.vaultKindPassport,
  DocKind.idCard => t.vaultKindIdCard,
  DocKind.boarding => t.vaultKindBoarding,
  DocKind.insurance => t.vaultKindInsurance,
  DocKind.booking => t.vaultKindBooking,
  DocKind.visa => t.vaultKindVisa,
  DocKind.medical => t.vaultKindMedical,
  DocKind.other => t.vaultKindOther,
};

/// "Caduca el 3 mar 2029" (o "Caducó..." / "Caduca pronto...") y su color.
(String, Color)? expiryLine(BuildContext context, VaultDoc doc, DateTime now) {
  final DateTime? e = doc.expires;
  if (e == null) return null;
  final AppLocalizations t = AppLocalizations.of(context);
  final String date = DateFormat.yMMMd(
    Localizations.localeOf(context).toLanguageTag(),
  ).format(e);
  final int days = e.difference(DateUtils.dateOnly(now)).inDays;
  if (days < 0) return (t.vaultExpired(date), NomadColors.safety);
  if (days < expiresSoonDays) {
    return (t.vaultExpiresSoon(date), NomadColors.money);
  }
  return (t.vaultExpires(date), NomadColors.textMuted);
}
