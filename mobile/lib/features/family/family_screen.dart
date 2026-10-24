// Perfiles de familia (maqueta "Familia"): una tarjeta por persona con sus
// etiquetas (alergias en rojo, necesidades en amarillo, gustos en azul) y,
// debajo, "Así os lo planeo": consejos que salen de toda la familia. Al tocar
// a alguien, los consejos se filtran a los suyos.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'family.dart';

/// Colores de las etiquetas (los de la maqueta).
const Color _allergyBg = Color(0xFF3A1A1A);
const Color _allergyFg = Color(0xFFFF9C9C);
const Color _needBg = Color(0xFF2A2418);
const Color _needFg = Color(0xFFFFD9A8);
const Color _likeBg = Color(0xFF15243A);
const Color _likeFg = Color(0xFFBCD6FF);

/// Un color por persona, por turnos.
const List<Color> _avatarColors = <Color>[
  NomadColors.mint,
  Color(0xFFFF8FB1),
  NomadColors.money,
  NomadColors.flights,
  NomadColors.group,
  NomadColors.safety,
];

String needLabel(AppLocalizations t, Need n) => switch (n) {
  Need.walksLittle => t.famNeedWalk,
  Need.carSeat => t.famNeedCarSeat,
  Need.stroller => t.famNeedStroller,
  Need.medication => t.famNeedMeds,
};

String likeLabel(AppLocalizations t, Like l) => switch (l) {
  Like.museums => t.famLikeMuseums,
  Like.food => t.famLikeFood,
  Like.photography => t.famLikePhoto,
  Like.animals => t.famLikeAnimals,
  Like.music => t.famLikeMusic,
  Like.beach => t.famLikeBeach,
  Like.nature => t.famLikeNature,
  Like.shopping => t.famLikeShopping,
};

String tipText(AppLocalizations t, TipKind k) => switch (k) {
  TipKind.allergy => t.famTipAllergy,
  TipKind.walk => t.famTipWalk,
  TipKind.carSeat => t.famTipCarSeat,
  TipKind.stroller => t.famTipStroller,
  TipKind.medication => t.famTipMeds,
  TipKind.kids => t.famTipKids,
  TipKind.seniors => t.famTipSeniors,
};

/// La familia resumida para Flyra ("Carmen, 72 años: camina poco; ...").
/// Solo se usa si la persona pulsa el botón, y la pregunta se puede leer y
/// cambiar antes de mandarla.
String familySummary(AppLocalizations t, List<FamilyMember> family) => family
    .map((FamilyMember m) {
      final List<String> parts = <String>[
        if (m.age != null) t.famAgeYears(m.age!),
        for (final String a in m.allergies) t.famAllergyTag(a),
        for (final Need n in m.needs) needLabel(t, n),
        for (final Like l in m.likes) likeLabel(t, l),
      ];
      return parts.isEmpty ? m.name : '${m.name} (${parts.join(', ')})';
    })
    .join('; ');

class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key});

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  late final AppServices _services = ServicesScope.of(context);
  List<FamilyMember>? _family;
  int? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_family == null) unawaited(_load());
  }

  Future<void> _load() async {
    final List<FamilyMember> family = await _services.family.load();
    if (mounted) setState(() => _family = family);
  }

  Future<void> _edit({int? index}) async {
    final List<FamilyMember> family = <FamilyMember>[...?_family];
    final _Edited? result = await showModalBottomSheet<_Edited>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) =>
          _MemberSheet(member: index == null ? null : family[index]),
    );
    if (result == null) return;
    if (index == null) {
      if (result.member != null) family.add(result.member!);
    } else if (result.member == null) {
      family.removeAt(index);
    } else {
      family[index] = result.member!;
    }
    await _services.family.save(family);
    if (mounted) {
      setState(() {
        _family = family;
        _selected = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<FamilyMember>? family = _family;
    final List<FamilyTip> tips = family == null
        ? <FamilyTip>[]
        : tipsFor(
            _selected == null ? family : <FamilyMember>[family[_selected!]],
          );
    final bool full = (family?.length ?? 0) >= maxFamily;
    return Scaffold(
      appBar: AppBar(title: Text(t.famTitle)),
      floatingActionButton: family == null || full
          ? null
          : FloatingActionButton.extended(
              onPressed: () => unawaited(_edit()),
              icon: const Icon(Icons.person_add_rounded),
              label: Text(t.famAdd),
            ),
      body: family == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
              children: <Widget>[
                Text(
                  t.famSubtitle,
                  style: text.bodyMedium?.copyWith(
                    color: NomadColors.textMuted,
                  ),
                ),
                const SizedBox(height: 16),
                if (family.isEmpty) Text(t.famEmpty),
                for (int i = 0; i < family.length; i++)
                  _MemberCard(
                    member: family[i],
                    color: _avatarColors[i % _avatarColors.length],
                    selected: _selected == i,
                    onTap: () =>
                        setState(() => _selected = _selected == i ? null : i),
                    onEdit: () => unawaited(_edit(index: i)),
                  ),
                if (tips.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 20),
                  Text(t.famPlanTitle, style: text.titleLarge),
                  const SizedBox(height: 8),
                  for (final FamilyTip tip in tips)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.check_circle_rounded,
                        color: NomadColors.mint,
                      ),
                      title: Text(tipText(t, tip.kind)),
                      subtitle: Text(t.famBecause(tip.who.join(', '))),
                    ),
                ],
                if (family.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      context.push(
                        Routes.flyra(
                          question: t.famFlyraQuestion(
                            familySummary(t, family),
                          ),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: Text(t.famAskFlyra),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.lock_rounded,
                      size: 16,
                      color: NomadColors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.famPrivacy,
                        style: text.bodySmall?.copyWith(
                          color: NomadColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.member,
    required this.color,
    required this.selected,
    required this.onTap,
    required this.onEdit,
  });

  final FamilyMember member;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final FamilyMember m = member;
    Widget tag(String text, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        text,
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w800),
      ),
    );
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? color : NomadColors.outline,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 23,
                backgroundColor: color,
                child: Text(
                  m.name.characters.first.toUpperCase(),
                  style: const TextStyle(
                    color: NomadColors.background,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      m.age == null
                          ? m.name
                          : '${m.name} · ${t.famAgeYears(m.age!)}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final String a in m.allergies)
                          tag(t.famAllergyTag(a), _allergyBg, _allergyFg),
                        for (final Need n in m.needs)
                          tag(needLabel(t, n), _needBg, _needFg),
                        for (final Like l in m.likes)
                          tag(likeLabel(t, l), _likeBg, _likeFg),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                onPressed: onEdit,
                icon: const Icon(Icons.edit_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lo que devuelve el formulario: la persona nueva o cambiada, o null si se
/// ha borrado.
class _Edited {
  const _Edited(this.member);

  final FamilyMember? member;
}

class _MemberSheet extends StatefulWidget {
  const _MemberSheet({this.member});

  final FamilyMember? member;

  @override
  State<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends State<_MemberSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.member?.name,
  );
  late final TextEditingController _age = TextEditingController(
    text: widget.member?.age?.toString(),
  );
  late final TextEditingController _allergies = TextEditingController(
    text: widget.member?.allergies.join(', '),
  );
  late final Set<Need> _needs = <Need>{...?widget.member?.needs};
  late final Set<Like> _likes = <Like>{...?widget.member?.likes};

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _allergies.dispose();
    super.dispose();
  }

  void _save() {
    final FamilyMember? m = FamilyMember.parse(
      FamilyMember(
        name: _name.text,
        age: int.tryParse(_age.text.trim()),
        allergies: splitAllergies(_allergies.text),
        needs: _needs,
        likes: _likes,
      ).toJson(),
    );
    if (m == null) return; // sin nombre no se guarda
    Navigator.of(context).pop(_Edited(m));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _name,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: t.famName,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _age,
                    maxLength: 3,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: InputDecoration(
                      labelText: t.famAge,
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _allergies,
              decoration: InputDecoration(labelText: t.famAllergies),
            ),
            const SizedBox(height: 16),
            Text(t.famNeeds, style: text.labelLarge),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final Need n in Need.values)
                  FilterChip(
                    label: Text(needLabel(t, n)),
                    selected: _needs.contains(n),
                    onSelected: (bool on) =>
                        setState(() => on ? _needs.add(n) : _needs.remove(n)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(t.famLikes, style: text.labelLarge),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final Like l in Like.values)
                  FilterChip(
                    label: Text(likeLabel(t, l)),
                    selected: _likes.contains(l),
                    onSelected: (bool on) =>
                        setState(() => on ? _likes.add(l) : _likes.remove(l)),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _save, child: Text(t.famSave)),
            if (widget.member != null)
              TextButton(
                onPressed: () => Navigator.of(context).pop(const _Edited(null)),
                child: Text(
                  t.famDelete,
                  style: const TextStyle(color: NomadColors.safety),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
