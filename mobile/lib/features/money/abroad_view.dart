// "Tu dinero fuera" (maqueta "Dinero"): cajeros, tarjetas, presupuesto y
// seguro. Cada parte es su propio fichero:
//   atms_panel.dart    → cajeros cercanos (OpenStreetMap) y el aviso DCC
//   cards_panel.dart   → ¿con qué tarjeta pago aquí?
//   budget_panel.dart  → ¿me llega el dinero?
//   insurance_panel.dart → ¿me cubre el seguro? (la póliza de la Bóveda)
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'atms_panel.dart';
import 'budget_panel.dart';
import 'cards_panel.dart';
import 'insurance_panel.dart';

enum AbroadPart { atms, cards, budget, insurance }

class AbroadView extends StatefulWidget {
  const AbroadView({super.key, this.part = AbroadPart.atms});

  final AbroadPart part;

  @override
  State<AbroadView> createState() => _AbroadViewState();
}

class _AbroadViewState extends State<AbroadView> {
  late AbroadPart _part = widget.part;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: NomadColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: NomadColors.outline),
            ),
            child: Row(
              children: <Widget>[
                for (final AbroadPart p in AbroadPart.values)
                  Expanded(
                    child: _PartButton(
                      label: switch (p) {
                        AbroadPart.atms => t.abroadAtms,
                        AbroadPart.cards => t.abroadCards,
                        AbroadPart.budget => t.abroadBudget,
                        AbroadPart.insurance => t.abroadInsurance,
                      },
                      selected: p == _part,
                      onTap: () => setState(() => _part = p),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: switch (_part) {
            AbroadPart.atms => const AtmsPanel(),
            AbroadPart.cards => const CardsPanel(),
            AbroadPart.budget => const BudgetPanel(),
            AbroadPart.insurance => const InsurancePanel(),
          },
        ),
      ],
    );
  }
}

class _PartButton extends StatelessWidget {
  const _PartButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? NomadColors.money : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected ? NomadColors.background : NomadColors.textMuted,
          ),
        ),
      ),
    ),
  );
}
