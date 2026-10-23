// El "aspecto" de toda la app en un solo sitio: colores, letras y formas.
// Si mañana cambia el verde de la marca, se cambia AQUÍ y se actualizan todas
// las pantallas. Los valores salen de las maquetas aprobadas por DARIO.
import 'package:flutter/material.dart';

/// Paleta de NomadIQ. Cada sección de la app tiene su color, igual que en
/// las maquetas: así el usuario sabe "dónde está" solo con mirar.
abstract final class NomadColors {
  static const Color background = Color(0xFF0B1217); // fondo casi negro
  static const Color surface = Color(0xFF131D24); // tarjetas
  static const Color surfaceHigh = Color(0xFF1B2830); // tarjetas elevadas
  static const Color outline = Color(0xFF26353F);
  static const Color text = Color(0xFFE8F1EE);
  static const Color textMuted = Color(0xFF8FA3A0);
  static const Color mint = Color(0xFF3DDC97); // color principal (marca)
  static const Color flights = Color(0xFF6CA8FF); // vuelos
  static const Color group = Color(0xFFB69CFF); // grupo (y el violeta de Flyra)
  static const Color money = Color(0xFFFFB86B); // dinero y gastos
  static const Color safety = Color(0xFFFF8A65); // seguridad y SOS
}

/// Familias de letra (archivos en assets/fonts, declarados en pubspec.yaml).
abstract final class NomadFonts {
  static const String display = 'BricolageGrotesque'; // títulos con carácter
  static const String body = 'Manrope'; // texto normal, muy legible
}

/// Las fuentes son "variables": un solo archivo con todos los grosores.
/// FontVariation le dice qué grosor dibujar (400 normal, 800 muy gruesa).
TextStyle _display(double size, double weight) => TextStyle(
  fontFamily: NomadFonts.display,
  fontSize: size,
  fontVariations: <FontVariation>[FontVariation.weight(weight)],
  height: 1.1,
  color: NomadColors.text,
);

ThemeData buildNomadTheme() {
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: NomadColors.mint,
        brightness: Brightness.dark,
      ).copyWith(
        primary: NomadColors.mint,
        onPrimary: NomadColors.background,
        secondary: NomadColors.group,
        surface: NomadColors.surface,
        onSurface: NomadColors.text,
        outline: NomadColors.outline,
        error: NomadColors.safety,
      );

  final ThemeData base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NomadColors.background,
    fontFamily: NomadFonts.body,
  );

  return base.copyWith(
    textTheme: base.textTheme
        .apply(bodyColor: NomadColors.text, displayColor: NomadColors.text)
        .copyWith(
          displaySmall: _display(36, 800),
          headlineMedium: _display(28, 750),
          headlineSmall: _display(22, 700),
          titleLarge: _display(20, 700),
        ),
    cardTheme: const CardThemeData(
      color: NomadColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52), // botones fáciles de pulsar
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: NomadFonts.body,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: const StadiumBorder(),
        foregroundColor: NomadColors.text,
        side: const BorderSide(color: NomadColors.outline),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: NomadColors.surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        borderSide: BorderSide.none,
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: NomadColors.surface,
      indicatorColor: Color(0x333DDC97), // verde marca al 20 %
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
  );
}
