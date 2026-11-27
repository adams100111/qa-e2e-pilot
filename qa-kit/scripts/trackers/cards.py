"""The scenario cards file: `.qa/specs/<target>/tracker-cards.json`.

It defines, in plain words, the tickets the tracker pushes for a spec (A4). `load` validates its
shape; `problems` checks it against the spec's frozen plan (`checklist.json`) and the wording
rules; `lint_verb` is the handler of `tracker.sh lint`.

From a checklist row we read `id` (a non-empty string; `validate-checklist-json.sh` defines it) and
the acting role(s) from `persona` (a string, as checkpoint rows and the ship-profile rows use it)
or a list in `personas` / `roles`. A row with none of these is role-less: one check, in any card.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import wording

CARDS_NAME = "tracker-cards.json"
PRIORITIES = ("P1", "P2", "P3")
AS_VALUES = ("subtasks", "checklist")


class CardsError(Exception):
    """The cards file is missing or malformed. The message names the file."""


@dataclass
class Check:
    criterion: str
    title: str
    do: str
    expect: str


@dataclass
class Card:
    id: str
    role: str
    roleName: str
    title: str
    storyline: str
    priority: str
    as_: str
    checks: List[Check] = field(default_factory=list)


@dataclass
class Cards:
    spec: Dict[str, Any]
    cards: List[Card]


def spec_dir(project: Path, target: str) -> Path:
    return Path(project) / ".qa" / "specs" / target


def exists(project: Path, target: str) -> bool:
    """The spec has a cards file (`/qa-scenarios` writes it; a spec starts without one)."""
    return (spec_dir(project, target) / CARDS_NAME).is_file()


def _str(obj: dict, key: str, where: str, path: Path) -> str:
    v = obj.get(key)
    if not isinstance(v, str) or not v.strip():
        raise CardsError(f"{path}: {where}.{key} must be a non-empty string")
    return v


def load(project: Path, target: str) -> Cards:
    path = spec_dir(project, target) / CARDS_NAME
    if not path.is_file():
        raise CardsError(f"{path}: not found; run /qa-scenarios")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CardsError(f"{path}: {exc}") from exc
    if not isinstance(data, dict):
        raise CardsError(f"{path}: must be an object with spec and cards")
    spec = data.get("spec")
    if not isinstance(spec, dict):
        raise CardsError(f"{path}: spec must be an object")
    out_scope = spec.get("outOfScope", [])
    if not isinstance(out_scope, list) or not all(isinstance(x, str) for x in out_scope):
        raise CardsError(f"{path}: spec.outOfScope must be a list of strings")
    spec = {"title": _str(spec, "title", "spec", path), "overview": _str(spec, "overview", "spec", path),
            "outOfScope": list(out_scope)}
    raw_cards = data.get("cards")
    if not isinstance(raw_cards, list):
        raise CardsError(f"{path}: cards must be a list")
    out: List[Card] = []
    for i, rc in enumerate(raw_cards):
        where = f"cards[{i}]"
        if not isinstance(rc, dict):
            raise CardsError(f"{path}: {where} must be an object")
        prio = rc.get("priority")
        if prio not in PRIORITIES:
            raise CardsError(f"{path}: {where}.priority must be one of {', '.join(PRIORITIES)}")
        as_ = rc.get("as")
        if as_ not in AS_VALUES:
            raise CardsError(f"{path}: {where}.as must be one of {', '.join(AS_VALUES)}")
        raw_checks = rc.get("checks")
        if not isinstance(raw_checks, list):
            raise CardsError(f"{path}: {where}.checks must be a list")
        checks: List[Check] = []
        for j, ck in enumerate(raw_checks):
            cw = f"{where}.checks[{j}]"
            if not isinstance(ck, dict):
                raise CardsError(f"{path}: {cw} must be an object")
            checks.append(Check(*(_str(ck, k, cw, path) for k in ("criterion", "title", "do", "expect"))))
        out.append(Card(id=_str(rc, "id", where, path), role=_str(rc, "role", where, path),
                        roleName=_str(rc, "roleName", where, path), title=_str(rc, "title", where, path),
                        storyline=_str(rc, "storyline", where, path), priority=prio, as_=as_, checks=checks))
    return Cards(spec=spec, cards=out)


def _row_id(row: dict) -> Optional[str]:
    v = row.get("id")
    return v if isinstance(v, str) and v else None


def _row_roles(row: dict) -> List[str]:
    """The roles a row runs as; `[""]` when it names none (role-less)."""
    for key in ("personas", "roles"):
        v = row.get(key)
        if isinstance(v, list):
            roles = [x for x in v if isinstance(x, str) and x]
            if roles:
                return roles
    v = row.get("persona")
    if isinstance(v, str) and v:
        return [v]
    return [""]


def problems(c: Cards, checklist_rows: List[dict], cfg) -> List[dict]:
    out: List[dict] = []

    def add(card: str, criterion: str, reason: str) -> None:
        out.append({"card": card, "criterion": criterion, "reason": reason})

    plan: Dict[str, List[str]] = {}
    dup_rows = set()
    for row in checklist_rows or []:
        if isinstance(row, dict) and _row_id(row):
            if _row_id(row) in plan:
                if _row_id(row) not in dup_rows:
                    dup_rows.add(_row_id(row))
                    add("", _row_id(row), "duplicate row in the plan")
                continue
            plan[_row_id(row)] = _row_roles(row)

    def name(title: str) -> str:
        """A title as a reader tells it from another: spacing and case aside."""
        return " ".join(title.split()).casefold()

    seen_ids, seen_titles = set(), set()
    for card in c.cards:
        if card.id in seen_ids:
            add(card.id, "", "duplicate card id")
        seen_ids.add(card.id)
        # a card is a ticket and a Doc page, a check a subtask or a checklist item: each is found
        # by its title, so two alike cannot both be shown
        if name(card.title) in seen_titles:
            add(card.id, "", "duplicate card title")
        seen_titles.add(name(card.title))
        check_titles: Dict[str, str] = {}  # title -> the first check that has it
        for ck in card.checks:
            # the same check twice is reported below as repeated, once
            if check_titles.setdefault(name(ck.title), ck.criterion) != ck.criterion:
                add(card.id, ck.criterion, "duplicate check title in this card")

    held: Dict[str, List[Card]] = {}  # criterion -> cards (one entry per check)
    for card in c.cards:
        for ck in card.checks:
            held.setdefault(ck.criterion, []).append(card)
            roles = plan.get(ck.criterion)
            if roles is None or (roles != [""] and card.role not in roles):
                add(card.id, ck.criterion, "check is not in the plan")

    def crowding(holders: List[Card], cid: str) -> None:
        """Report a check held more than once: repeated in one card, and/or spread over cards."""
        distinct: List[Card] = []
        for k in holders:
            if not any(k is d for d in distinct):
                distinct.append(k)
        for d in distinct:
            if sum(1 for k in holders if k is d) > 1:
                add(d.id, cid, "check is repeated in this card")
        if len(distinct) > 1:
            add(distinct[1].id, cid, "check is in two cards")

    for cid, roles in plan.items():
        cards_of = held.get(cid, [])
        if roles == [""]:
            if not cards_of:
                add("", cid, "no card for this check")
            else:
                crowding(cards_of, cid)
            continue
        for role in roles:
            mine = [k for k in cards_of if k.role == role]
            if not mine:
                add("", cid, "no card for this check")
            else:
                crowding(mine, cid)

    for r in wording.lint_text(c.spec["title"], "title", cfg):
        add("", "", r)
    for text in [c.spec["overview"]] + c.spec["outOfScope"]:
        for r in wording.lint_text(text, "body", cfg):
            add("", "", r)
    for card in c.cards:
        for r in wording.lint_text(card.title, "title", cfg):
            add(card.id, "", r)
        for r in wording.lint_text(card.roleName, "title", cfg):  # sent to ClickUp as the Role field
            add(card.id, "", r)
        for r in wording.lint_text(card.storyline, "body", cfg):
            add(card.id, "", r)
        for ck in card.checks:
            for text, kind in ((ck.title, "title"), (ck.do, "body"), (ck.expect, "body")):
                for r in wording.lint_text(text, kind, cfg):
                    add(card.id, ck.criterion, r)
    return out


def card_for(c: Cards, criterion: str, persona: str) -> Optional[Card]:
    """The card holding `criterion` for `persona`. An empty persona matches only when exactly one
    card holds the criterion."""
    holders = [card for card in c.cards if any(k.criterion == criterion for k in card.checks)]
    if persona:
        for card in holders:
            if card.role == persona:
                return card
        return None
    return holders[0] if len(holders) == 1 else None


def plan_rows(project: Path, target: str) -> List[dict]:
    """The rows of the spec's frozen plan (`checklist.json`); `CardsError` when unreadable."""
    path = spec_dir(project, target) / "checklist.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CardsError(f"{path}: {exc}") from exc
    if isinstance(data, dict):
        for k in ("criteria", "rows", "checklist", "items"):
            if isinstance(data.get(k), list):
                data = data[k]
                break
    if not isinstance(data, list):
        raise CardsError(f"{path}: not a plan the tracker can read")
    return [r for r in data if isinstance(r, dict)]


_plan_rows = plan_rows  # kept so callers of the old private name keep working


def lint_verb(ctx) -> None:
    """`tracker.sh lint`: print `{"ok", "problems"}` as one JSON line; one skip per problem."""
    target = ctx.args.spec
    try:
        c = load(ctx.project, target)
        found = problems(c, _plan_rows(ctx.project, target), ctx.cfg)
    except CardsError as exc:
        found = [{"card": "", "criterion": "", "reason": str(exc)}]
    for p in found:
        ctx.log.skip("lint", f"{p['card'] or '-'}\t{p['criterion'] or '-'}\t{p['reason']}")
    print(json.dumps({"ok": not found, "problems": found}, ensure_ascii=False))
