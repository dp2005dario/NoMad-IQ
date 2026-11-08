// "Entrar con huella o cara" (Ajustes): si lo enciendes, la app pide tu
// huella (o la cara, o el PIN del móvil) al abrirse y al volver después de
// un rato fuera. Mientras tanto se ve una pantalla oscura con un candado.
//
// Si el móvil no tiene ni huella ni PIN, no se puede proteger: la app se
// abre sin más (si no, te quedarías fuera para siempre).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../vault/vault_store.dart';

/// ¿Está encendido "Entrar con huella o cara"?
bool appLockOn(SettingsStore prefs) => prefs.readData(LocalData.appLock) == '1';

/// Lo que tarda en volver a pedir la huella si sales de la app.
const Duration appLockAfter = Duration(minutes: 1);

/// Va por encima de todas las pantallas (ver lib/app.dart).
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _started = false;
  bool _locked = false;
  bool _asking = false;
  DateTime? _left;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (appLockOn(ServicesScope.of(context).prefs)) {
      _locked = true;
      // Se pide al acabar de dibujar la primera vez.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_ask()));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // La ventana de la huella también "pausa" la app en algunos móviles:
    // eso no cuenta como salir.
    if (_asking) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _left ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final DateTime? left = _left;
      _left = null;
      if (left == null || !mounted) return;
      if (!appLockOn(ServicesScope.of(context).prefs)) return;
      if (DateTime.now().difference(left) < appLockAfter) return;
      setState(() => _locked = true);
      unawaited(_ask());
    }
  }

  Future<void> _ask() async {
    if (_asking || !mounted) return;
    final AppServices services = ServicesScope.of(context);
    final String reason = AppLocalizations.of(context).appLockReason;
    _asking = true;
    final UnlockResult r = await services.vault.verify(reason);
    _asking = false;
    if (!mounted) return;
    if (r != UnlockResult.cancelled) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: <Widget>[
      widget.child,
      if (_locked) Positioned.fill(child: _LockScreen(onUnlock: _ask)),
    ],
  );
}

/// La pantalla del candado (tapa todo lo de debajo).
class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Material(
      color: NomadColors.background,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF141E25),
                ),
                child: const Icon(
                  Icons.fingerprint_rounded,
                  size: 48,
                  color: NomadColors.mint,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                t.appLockTitle,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onUnlock,
                icon: const Icon(Icons.lock_open_rounded),
                label: Text(t.appLockButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
