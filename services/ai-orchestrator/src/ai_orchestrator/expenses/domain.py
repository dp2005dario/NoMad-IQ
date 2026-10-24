"""Las cuentas de los gastos compartidos, sin base de datos ni red.

Todo en céntimos enteros. Tres preguntas:
    1. ¿Cuánto le toca a cada uno de un gasto? (``shares``)
    2. ¿Cuánto ha puesto y cuánto ha gastado cada uno? (``balances``)
    3. ¿Quién paga a quién para quedar en paz, con los menos pagos posibles?
       (``settle``)

Ejemplo: cena de 86 € que paga Álex entre 4 a partes iguales -> 21,50 € cada
uno. Álex ha puesto 86 y gastado 21,50: le deben 64,50. Los otros tres
deben 21,50 cada uno, y se lo pagan a Álex.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from typing import Literal

Split = Literal["equal", "items", "weights"]

# El bote común ("la hucha") es el asiento 0: poner dinero en él es un pago
# al 0 y pagar con él es un gasto cuyo pagador es el 0.
KITTY = 0

MAX_MEMBERS = 20
MAX_ITEMS = 100
MAX_EXPENSES = 1000


@dataclass(frozen=True, slots=True)
class Item:
    name: str
    qty: int
    price_minor: int
    # Asientos que se han pedido esta línea. Vacío = de todos.
    claimed_by: tuple[int, ...] = ()


@dataclass(frozen=True, slots=True)
class Expense:
    amount_minor: int
    payer_seat: int
    split: Split
    participants: tuple[int, ...]
    items: tuple[Item, ...] = ()
    # Con split "weights": un peso por participante, en el mismo orden
    # (modo pareja "según sueldo": 60 y 40).
    weights: tuple[int, ...] = ()


@dataclass(frozen=True, slots=True)
class Payment:
    from_seat: int
    to_seat: int
    amount_minor: int


@dataclass(frozen=True, slots=True)
class Transfer:
    """Una sugerencia de pago para quedar en paz."""

    from_seat: int
    to_seat: int
    amount_minor: int


def divide(total: int, weights: dict[int, int]) -> dict[int, int]:
    """Reparte ``total`` céntimos según los pesos, sin perder ni un céntimo.

    Método del "resto mayor": cada uno se lleva la parte entera y los
    céntimos que sobran van a quien más decimales perdió (y, si empatan, al
    asiento más bajo, para que el resultado sea siempre el mismo).
    Ejemplo: 100 céntimos entre 3 -> 34, 33, 33.
    """
    weights = {seat: w for seat, w in weights.items() if w > 0}
    if not weights:
        raise ValueError("nadie entre quien repartir")
    total_weight = sum(weights.values())
    base = {seat: total * w // total_weight for seat, w in weights.items()}
    left = total - sum(base.values())
    order = sorted(weights, key=lambda s: (-(total * weights[s] % total_weight), s))
    for seat in order[:left]:
        base[seat] += 1
    return base


def shares(expense: Expense) -> dict[int, int]:
    """Cuánto le toca pagar a cada asiento de este gasto (suma = el total)."""
    people = tuple(dict.fromkeys(expense.participants))
    if expense.split == "weights" and len(expense.weights) == len(expense.participants):
        return divide(expense.amount_minor, dict(zip(expense.participants, expense.weights, strict=True)))
    if expense.split != "items" or not expense.items:
        return divide(expense.amount_minor, dict.fromkeys(people, 1))
    # Por platos: primero, lo que se ha pedido cada uno según el ticket.
    # Una línea pedida por dos se parte entre los dos; una sin dueño, entre
    # todos los participantes.
    consumed: dict[int, int] = dict.fromkeys(people, 0)
    for item in expense.items:
        if item.price_minor == 0:
            continue
        owners = tuple(s for s in dict.fromkeys(item.claimed_by) if s in consumed) or people
        for seat, part in divide(item.price_minor, dict.fromkeys(owners, 1)).items():
            consumed[seat] += part
    if sum(consumed.values()) == 0:
        return divide(expense.amount_minor, dict.fromkeys(people, 1))
    # Después se escala al total pagado: si hubo propina o el ticket no
    # cuadra, cada uno pone en proporción a lo que tomó.
    return divide(expense.amount_minor, consumed)


def balances(
    seats: Iterable[int], expenses: Iterable[Expense], payments: Iterable[Payment]
) -> dict[int, int]:
    """Saldo de cada asiento: positivo = le deben; negativo = debe."""
    out = dict.fromkeys(seats, 0)
    for e in expenses:
        out[e.payer_seat] = out.get(e.payer_seat, 0) + e.amount_minor
        for seat, part in shares(e).items():
            out[seat] = out.get(seat, 0) - part
    for p in payments:
        # Quien paga una deuda "pone" dinero; quien lo recibe, lo "saca".
        out[p.from_seat] = out.get(p.from_seat, 0) + p.amount_minor
        out[p.to_seat] = out.get(p.to_seat, 0) - p.amount_minor
    return out


def settle(balance: dict[int, int]) -> list[Transfer]:
    """Quién paga a quién para quedar en paz (como mucho n-1 pagos).

    Algoritmo "voraz": el que más debe le paga al que más le deben, todo lo
    que pueda; se repite hasta que no queda nadie. Simple y suficiente para
    un grupo de amigos.
    """
    debtors = sorted(((-b, s) for s, b in balance.items() if b < 0), reverse=True)
    creditors = sorted(((b, s) for s, b in balance.items() if b > 0), reverse=True)
    out: list[Transfer] = []
    i = j = 0
    debt = [list(d) for d in debtors]
    credit = [list(c) for c in creditors]
    while i < len(debt) and j < len(credit):
        amount = min(debt[i][0], credit[j][0])
        out.append(Transfer(from_seat=debt[i][1], to_seat=credit[j][1], amount_minor=amount))
        debt[i][0] -= amount
        credit[j][0] -= amount
        if debt[i][0] == 0:
            i += 1
        if credit[j][0] == 0:
            j += 1
    return out


def kitty(expenses: Iterable[Expense], payments: Iterable[Payment]) -> tuple[dict[int, int], int]:
    """El bote común: (lo que ha puesto cada asiento, lo gastado con él)."""
    put: dict[int, int] = {}
    for p in payments:
        if p.to_seat == KITTY:
            put[p.from_seat] = put.get(p.from_seat, 0) + p.amount_minor
        elif p.from_seat == KITTY:
            # El bote le devuelve a alguien lo que sobró.
            put[p.to_seat] = put.get(p.to_seat, 0) - p.amount_minor
    spent = sum(e.amount_minor for e in expenses if e.payer_seat == KITTY)
    return put, spent


def check_expense(expense: Expense, seats: Sequence[int]) -> None:
    """Errores de sentido común (ValueError) antes de guardar un gasto."""
    known = set(seats)
    if expense.payer_seat not in known and expense.payer_seat != KITTY:
        raise ValueError("quien pagó no está en el bote")
    if not expense.participants or any(s not in known for s in expense.participants):
        raise ValueError("participantes que no están en el bote")
    if expense.split == "items" and not expense.items:
        raise ValueError("para repartir por platos hacen falta las líneas del ticket")
    if expense.split == "weights" and (
        len(expense.weights) != len(expense.participants) or any(not 1 <= w <= 100 for w in expense.weights)
    ):
        raise ValueError("hace falta un peso (1-100) por participante")
    if expense.split != "weights" and expense.weights:
        raise ValueError("los pesos solo valen para repartir con pesos")
    for item in expense.items:
        if any(s not in expense.participants for s in item.claimed_by):
            raise ValueError("una línea pedida por alguien que no participa")
