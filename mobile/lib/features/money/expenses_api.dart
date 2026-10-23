// Las llamadas de Gastos al ai-orchestrator (a través de la puerta de entrada):
//   GET    /v1/expense-groups                    → mis botes, con lo que me deben
//   POST   /v1/expense-groups                    → crear uno (con código)
//   POST   /v1/expense-groups/join               → entrar con el código de un amigo
//   GET    /v1/expense-groups/{id}               → gastos, saldos y quién paga a quién
//   POST   /v1/expense-groups/{id}/expenses      → apuntar un gasto
//   PUT    /v1/expense-groups/{id}/expenses/{e}/items/{i}/claim → "esto me lo pedí yo"
//   DELETE /v1/expense-groups/{id}/expenses/{e}  → borrar un gasto
//   POST   /v1/expense-groups/{id}/payments      → "Saldar": ya le pagué
//
// Un "bote" es un grupo de gente que comparte gastos (un viaje, un piso...).
// Cada persona es un ASIENTO (1, 2, 3...) con el nombre que eligió: el
// servidor nunca enseña el id de nadie.
//
// El dinero va SIEMPRE en unidades mínimas y como número entero (2150 = 21,50 €):
// con decimales, 0,1 + 0,2 no da exactamente 0,3 y con dinero no vale "casi".
//
// Igual que en Grupo, aquí se revisa TODO lo que llega del servidor: si algo
// no tiene la forma esperada, mejor un error claro que una pantalla rota.
import '../../core/api_client.dart';

const String _base = '/v1/expense-groups';

/// Límites del servidor (expenses/domain.py): mejor avisar antes de enviar.
const int maxGroupMembers = 20;
const int maxTicketItems = 100;
const int maxExpenseTitle = 80;
const int maxGroupTitle = 60;
const int maxPersonName = 40;
const int maxItemName = 60;

/// Cómo se reparte un gasto.
enum SplitMode {
  /// A partes iguales entre los que participan.
  equal,

  /// Cada uno paga lo que tomó (las líneas del ticket).
  items;

  String get wire => name;

  static SplitMode parse(Object? raw) => switch (raw) {
    'equal' => SplitMode.equal,
    'items' => SplitMode.items,
    _ => _bad(),
  };
}

class ExpenseMember {
  const ExpenseMember({
    required this.seat,
    required this.name,
    required this.me,
  });

  final int seat;
  final String name;
  final bool me;

  static ExpenseMember parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? me = m['me'];
    if (me is! bool) _bad();
    return ExpenseMember(seat: _seat(m['seat']), name: _str(m['name']), me: me);
  }
}

/// Una línea del ticket: "2 Croquetas 12,00".
class TicketItem {
  const TicketItem({
    required this.name,
    required this.priceMinor,
    this.qty = 1,
    this.claimedBy = const <int>[],
  });

  final String name;
  final int qty;

  /// Lo que cuesta la línea entera (no cada unidad).
  final int priceMinor;

  /// Quién se la pidió. Vacía = "de todos" (se reparte entre todos).
  final List<int> claimedBy;

  TicketItem copyWith({String? name, int? qty, int? priceMinor}) => TicketItem(
    name: name ?? this.name,
    qty: qty ?? this.qty,
    priceMinor: priceMinor ?? this.priceMinor,
    claimedBy: claimedBy,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'qty': qty,
    'price_minor': priceMinor,
    'claimed_by': claimedBy,
  };

  static TicketItem parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? qty = m['qty'];
    final Object? price = m['price_minor'];
    if (qty is! int || qty < 1 || price is! int || price < 0) _bad();
    return TicketItem(
      name: _str(m['name']),
      qty: qty,
      priceMinor: price,
      claimedBy: _seats(m['claimed_by']),
    );
  }
}

class Expense {
  const Expense({
    required this.id,
    required this.title,
    required this.amountMinor,
    required this.payerSeat,
    required this.split,
    required this.participants,
    required this.items,
    required this.shares,
    required this.spentOn,
    required this.createdBy,
    this.originalMinor,
    this.originalCurrency,
  });

  final String id;
  final String title;
  final int amountMinor;
  final int payerSeat;
  final SplitMode split;
  final List<int> participants;
  final List<TicketItem> items;

  /// Lo que le toca pagar a cada asiento (ya calculado por el servidor).
  final Map<int, int> shares;
  final DateTime spentOn;
  final int createdBy;

  /// Lo que marcaba el ticket si era en otra moneda (solo para enseñarlo).
  final int? originalMinor;
  final String? originalCurrency;

  static Expense parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final Object? amount = m['amount_minor'];
    final Object? items = m['items'];
    final Object? shares = m['shares'];
    final Object? original = m['original_minor'];
    final Object? originalCurrency = m['original_currency'];
    final DateTime? spentOn = DateTime.tryParse(_str(m['spent_on']));
    if (amount is! int ||
        amount <= 0 ||
        items is! List<Object?> ||
        shares is! List<Object?> ||
        spentOn == null ||
        (original != null && original is! int) ||
        (originalCurrency != null && originalCurrency is! String)) {
      _bad();
    }
    return Expense(
      id: _str(m['expense_id']),
      title: _str(m['title']),
      amountMinor: amount,
      payerSeat: _seat(m['payer_seat']),
      split: SplitMode.parse(m['split']),
      participants: _seats(m['participants']),
      items: items.map(TicketItem.parse).toList(),
      shares: <int, int>{
        for (final Object? s in shares)
          _seat(_map(s)['seat']): _int(_map(s)['amount_minor']),
      },
      spentOn: spentOn,
      createdBy: _seat(m['created_by']),
      originalMinor: original as int?,
      originalCurrency: originalCurrency as String?,
    );
  }
}

/// "Saldar": [fromSeat] le pagó [amountMinor] a [toSeat].
class Payment {
  const Payment({
    required this.fromSeat,
    required this.toSeat,
    required this.amountMinor,
  });

  final int fromSeat;
  final int toSeat;
  final int amountMinor;

  static Payment parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    return Payment(
      fromSeat: _seat(m['from_seat']),
      toSeat: _seat(m['to_seat']),
      amountMinor: _int(m['amount_minor']),
    );
  }
}

/// Un bote completo, tal y como lo ve quien pregunta.
class ExpenseGroup {
  const ExpenseGroup({
    required this.id,
    required this.title,
    required this.currency,
    required this.inviteCode,
    required this.mySeat,
    required this.members,
    required this.expenses,
    required this.payments,
    required this.balances,
    required this.transfers,
    required this.totalMinor,
  });

  final String id;
  final String title;
  final String currency;
  final String inviteCode;
  final int mySeat;
  final List<ExpenseMember> members;
  final List<Expense> expenses;
  final List<Payment> payments;

  /// Asiento → saldo. Positivo = le deben; negativo = debe.
  final Map<int, int> balances;

  /// Los pagos que dejan a todos en paz (los menos posibles).
  final List<Payment> transfers;
  final int totalMinor;

  int get myBalance => balances[mySeat] ?? 0;

  ExpenseMember? member(int seat) {
    for (final ExpenseMember m in members) {
      if (m.seat == seat) return m;
    }
    return null;
  }

  /// El nombre de un asiento (o "?" si ya no está, que no debería pasar).
  String nameOf(int seat) => member(seat)?.name ?? '?';

  /// Lo que YO tengo que pagar para quedar en paz (a quién y cuánto).
  List<Payment> get myDebts => <Payment>[
    for (final Payment t in transfers)
      if (t.fromSeat == mySeat) t,
  ];

  static ExpenseGroup parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    final String currency = _str(m['currency']);
    final Object? members = m['members'];
    final Object? expenses = m['expenses'];
    final Object? payments = m['payments'];
    final Object? balances = m['balances'];
    final Object? transfers = m['transfers'];
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
        members is! List<Object?> ||
        expenses is! List<Object?> ||
        payments is! List<Object?> ||
        balances is! List<Object?> ||
        transfers is! List<Object?>) {
      _bad();
    }
    return ExpenseGroup(
      id: _str(m['group_id']),
      title: _str(m['title']),
      currency: currency,
      inviteCode: _str(m['invite_code']),
      mySeat: _seat(m['my_seat']),
      members: members.map(ExpenseMember.parse).toList(),
      expenses: expenses.map(Expense.parse).toList(),
      payments: payments.map(Payment.parse).toList(),
      balances: <int, int>{
        for (final Object? b in balances)
          _seat(_map(b)['seat']): _int(_map(b)['balance_minor']),
      },
      transfers: transfers.map(Payment.parse).toList(),
      totalMinor: _int(m['total_minor']),
    );
  }
}

/// Un bote en la lista "Tus botes" (sin todos los gastos dentro).
class ExpenseGroupSummary {
  const ExpenseGroupSummary({
    required this.id,
    required this.title,
    required this.currency,
    required this.members,
    required this.myBalanceMinor,
    required this.totalMinor,
  });

  final String id;
  final String title;
  final String currency;
  final int members;
  final int myBalanceMinor;
  final int totalMinor;

  static ExpenseGroupSummary parse(Object? json) {
    final Map<String, Object?> m = _map(json);
    return ExpenseGroupSummary(
      id: _str(m['group_id']),
      title: _str(m['title']),
      currency: _str(m['currency']),
      members: _int(m['members']),
      myBalanceMinor: _int(m['my_balance_minor']),
      totalMinor: _int(m['total_minor']),
    );
  }
}

/// Lo que se manda al apuntar un gasto.
class NewExpense {
  const NewExpense({
    required this.title,
    required this.amountMinor,
    required this.payerSeat,
    required this.participants,
    required this.spentOn,
    this.split = SplitMode.equal,
    this.items = const <TicketItem>[],
  });

  final String title;
  final int amountMinor;
  final int payerSeat;
  final List<int> participants;
  final DateTime spentOn;
  final SplitMode split;
  final List<TicketItem> items;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'amount_minor': amountMinor,
    'payer_seat': payerSeat,
    'split': split.wire,
    'participants': participants,
    'items': items.map((TicketItem i) => i.toJson()).toList(),
    'spent_on': _day(spentOn),
  };
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class ExpensesApi {
  const ExpensesApi(this._api);

  final ApiClient _api;

  Future<List<ExpenseGroupSummary>> list() async {
    final Map<String, Object?> body = _map(await _api.getJson(_base));
    final Object? items = body['items'];
    if (items is! List<Object?>) _bad();
    return items.map(ExpenseGroupSummary.parse).toList();
  }

  Future<ExpenseGroup> get(String id) async =>
      ExpenseGroup.parse(await _api.getJson('$_base/${_id(id)}'));

  Future<ExpenseGroup> create({
    required String title,
    required String currency,
    required String myName,
  }) async => ExpenseGroup.parse(
    await _api.postJson(_base, <String, Object?>{
      'title': title,
      'currency': currency,
      'my_name': myName,
    }),
  );

  Future<ExpenseGroup> join(String code, {required String myName}) async =>
      ExpenseGroup.parse(
        await _api.postJson('$_base/join', <String, Object?>{
          'code': code,
          'my_name': myName,
        }),
      );

  Future<Expense> add(String groupId, NewExpense expense) async =>
      Expense.parse(
        await _api.postJson(
          '$_base/${_id(groupId)}/expenses',
          expense.toJson(),
        ),
      );

  /// "Esto me lo pedí yo" ([claimed] true) o "ya no" (false).
  Future<Expense> claim(
    String groupId,
    String expenseId,
    int index, {
    required bool claimed,
  }) async => Expense.parse(
    await _api.putJson(
      '$_base/${_id(groupId)}/expenses/${_id(expenseId)}/items/$index/claim',
      <String, Object?>{'claimed': claimed},
    ),
  );

  Future<void> delete(String groupId, String expenseId) =>
      _api.delete('$_base/${_id(groupId)}/expenses/${_id(expenseId)}');

  Future<void> pay(
    String groupId, {
    required int toSeat,
    required int amountMinor,
  }) => _api.postJson('$_base/${_id(groupId)}/payments', <String, Object?>{
    'to_seat': toSeat,
    'amount_minor': amountMinor,
  });
}

String _id(String id) => Uri.encodeComponent(id);

Map<String, Object?> _map(Object? json) =>
    json is Map<String, Object?> ? json : _bad();

String _str(Object? value) =>
    value is String && value.isNotEmpty && value.length <= 200 ? value : _bad();

int _int(Object? value) => value is int ? value : _bad();

int _seat(Object? value) =>
    value is int && value >= 1 && value <= maxGroupMembers ? value : _bad();

List<int> _seats(Object? value) {
  if (value is! List<Object?>) _bad();
  return <int>[for (final Object? v in value) _seat(v)];
}

Never _bad() => throw const ApiException(ApiError.unavailable);
