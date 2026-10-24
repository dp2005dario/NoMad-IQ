// "¿Me cubre el seguro?" (maqueta "Tu dinero fuera → Seguro").
//
// La póliza vive en la Bóveda (cifrada). Al abrirla con la huella, se elige
// la póliza y se toca una pregunta ("¿Cubre la maleta perdida?"). El móvil
// busca en el texto que leyó de la póliza las frases que hablan de eso y las
// enseña con su página. Nada sale del teléfono (ver vault/policy_search.dart).
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../vault/policy_search.dart';
import '../vault/vault.dart';
import '../vault/vault_store.dart';

String topicQuestion(AppLocalizations t, PolicyTopic p) => switch (p) {
  PolicyTopic.luggage => t.insuranceLuggage,
  PolicyTopic.medical => t.insuranceMedical,
  PolicyTopic.cancellation => t.insuranceCancellation,
  PolicyTopic.delay => t.insuranceDelay,
  PolicyTopic.theft => t.insuranceTheft,
  PolicyTopic.sports => t.insuranceSports,
};

class InsurancePanel extends StatefulWidget {
  const InsurancePanel({super.key});

  @override
  State<InsurancePanel> createState() => _InsurancePanelState();
}

class _InsurancePanelState extends State<InsurancePanel> {
  late final AppServices _services = ServicesScope.of(context);
  late final Vault _vault = _services.vault;
  final TextEditingController _question = TextEditingController();
  String? _policyId;
  List<String>? _text;
  PolicyTopic? _topic;
  List<PolicyHit>? _hits;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final UnlockResult r = await _vault.open(t.vaultUnlockReason);
    if (!mounted || r == UnlockResult.ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r == UnlockResult.unavailable ? t.vaultNoLock : t.vaultUnlockFailed,
        ),
      ),
    );
  }

  Future<void> _choose(VaultDoc doc) async {
    final List<String> text = await _vault.text(doc.id);
    if (!mounted) return;
    setState(() {
      _policyId = doc.id;
      _text = text;
      _topic = null;
      _hits = null;
    });
  }

  void _ask(PolicyTopic topic) => setState(() {
    _topic = topic;
    _hits = searchPolicy(_text ?? const <String>[], topicWords[topic]!);
  });

  void _askFree() {
    final List<String> words = questionWords(_question.text);
    setState(() {
      _topic = null;
      _hits = searchPolicy(_text ?? const <String>[], words);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _vault,
    builder: (BuildContext context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    if (!_vault.isOpen) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          const Icon(
            Icons.health_and_safety_rounded,
            size: 56,
            color: NomadColors.flights,
          ),
          const SizedBox(height: 12),
          Text(
            t.abroadInsuranceIntro,
            textAlign: TextAlign.center,
            style: text.bodyLarge,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _unlock,
            icon: const Icon(Icons.fingerprint_rounded),
            label: Text(t.insuranceOpenVault),
          ),
        ],
      );
    }
    final List<VaultDoc> policies = <VaultDoc>[
      for (final VaultDoc d in _vault.docs)
        if (d.kind == DocKind.insurance) d,
    ];
    if (policies.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          Text(t.insuranceNoPolicy, style: text.bodyLarge),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.push(Routes.vault),
            child: Text(t.vaultTitle),
          ),
        ],
      );
    }
    final VaultDoc? policy = policies
        .where((VaultDoc d) => d.id == _policyId)
        .firstOrNull;
    final List<PolicyHit>? hits = _hits;
    return Listener(
      onPointerDown: (_) => _vault.touch(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          for (final VaultDoc d in policies)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: d.id == _policyId
                    ? NomadColors.surfaceHigh
                    : NomadColors.surface,
                borderRadius: BorderRadius.circular(18),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(
                      color: d.id == _policyId
                          ? NomadColors.flights
                          : NomadColors.outline,
                    ),
                  ),
                  leading: const Icon(
                    Icons.picture_as_pdf_rounded,
                    color: NomadColors.flights,
                  ),
                  title: Text(d.title),
                  subtitle: Text(t.insuranceReadOnPhone(d.pages)),
                  onTap: () => _choose(d),
                ),
              ),
            ),
          if (policy != null) ...<Widget>[
            const SizedBox(height: 8),
            if ((_text ?? const <String>[]).every((String p) => p.isEmpty))
              Text(
                t.insuranceNoText,
                style: const TextStyle(color: NomadColors.safety),
              )
            else ...<Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final PolicyTopic p in PolicyTopic.values)
                    ChoiceChip(
                      label: Text(topicQuestion(t, p)),
                      selected: p == _topic,
                      onSelected: (_) => _ask(p),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _question,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _askFree(),
                decoration: InputDecoration(
                  labelText: t.insuranceAsk,
                  suffixIcon: IconButton(
                    tooltip: t.insuranceAsk,
                    onPressed: _askFree,
                    icon: const Icon(Icons.search_rounded),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (hits != null && hits.isEmpty) Text(t.insuranceNoHits),
              if (hits != null)
                for (final PolicyHit h in hits) _HitCard(hit: h),
              if (hits != null && hits.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t.insuranceDisclaimer,
                    style: const TextStyle(
                      fontSize: 12,
                      color: NomadColors.textMuted,
                    ),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _HitCard extends StatelessWidget {
  const _HitCard({required this.hit});

  final PolicyHit hit;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Color color = hit.exclusion ? NomadColors.safety : NomadColors.mint;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            children: <Widget>[
              Text(
                t.insurancePage(hit.page),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: NomadColors.textMuted,
                ),
              ),
              if (hit.exclusion)
                Text(
                  t.insuranceExclusion,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text('«${hit.text}»'),
        ],
      ),
    );
  }
}
