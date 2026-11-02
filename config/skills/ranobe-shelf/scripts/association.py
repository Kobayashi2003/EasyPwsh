"""明示的な単書判定から著者・出版社の連帯判定を計算する。移動はしない。"""

import argparse
import json
import pathlib
import unicodedata
from typing import TypedDict, cast


class AssociationRow(TypedDict, total=False):
    book_key: str
    authors: list[str]
    publishers: list[str]
    method: str
    verdict: str
    evidence: object
    media_kind: str
    media_evidence: object


Counts = dict[tuple[str, str], dict[str, list[str]]]


class AssociationTrigger(TypedDict):
    entity_type: str
    entity: str
    ln: int
    non_ln: int
    verdict: str
    seed_group: list[str]


class AssociationDecision(TypedDict, total=False):
    method: str
    verdict: str
    triggers: list[AssociationTrigger]
    route: str | None
    conflict: bool
    threshold: int
    media_kind: str
    reason: str


def entity_key(value: str) -> str:
    return "".join(unicodedata.normalize("NFKC", value).split()).casefold()


def association_counts(evidence: list[AssociationRow]) -> Counts:
    votes: dict[tuple[str, str, str], set[str]] = {}
    for row in evidence:
        if row.get("media_kind") != "novel" or not row.get("media_evidence"):
            continue
        if row.get("method") != "direct" or not row.get("evidence"):
            continue
        if row.get("verdict") not in {"ln", "non_ln"}:
            continue
        book = row.get("book_key")
        if not book:
            raise ValueError("direct evidence requires book_key")
        for kind, names in (
            ("authors", row.get("authors", [])),
            ("publishers", row.get("publishers", [])),
        ):
            for name in names:
                key = entity_key(name)
                if key and key not in {
                    "unknown",
                    "不明",
                    "出版社未記載",
                    "著者等未記載",
                    "著者不明",
                }:
                    votes.setdefault((kind, key, book), set()).add(
                        row.get("verdict", "unknown")
                    )
    counts: Counts = {}
    for (kind, key, book), verdicts in votes.items():
        group = counts.setdefault(
            (kind, key), {"ln": [], "non_ln": [], "conflicts": []}
        )
        target = next(iter(verdicts)) if len(verdicts) == 1 else "conflicts"
        group[target].append(book)
    return counts


def association_decide(
    row: AssociationRow, counts: Counts, threshold: int
) -> AssociationDecision:
    if threshold < 1:
        raise ValueError("threshold must be positive")
    media = row.get("media_kind", "unknown")
    if media not in {"novel", "comic", "other"} or not row.get("media_evidence"):
        return {
            "method": "media_pending",
            "verdict": "unknown",
            "triggers": [],
            "media_kind": "unknown",
            "reason": "単書の媒体種別を先に確認",
        }
    if media in {"comic", "other"}:
        return {
            "method": "direct_media",
            "verdict": "non_ln",
            "triggers": [],
            "media_kind": media,
            "reason": "小説以外は連帯判定の対象外",
        }
    if (
        row.get("method") == "direct"
        and row.get("evidence")
        and row.get("verdict") in {"ln", "non_ln"}
    ):
        return {
            "method": "direct",
            "verdict": row.get("verdict", "unknown"),
            "triggers": [],
        }
    triggers: list[AssociationTrigger] = []
    for kind, names in (
        ("authors", row.get("authors", [])),
        ("publishers", row.get("publishers", [])),
    ):
        for name in names:
            group = counts.get((kind, entity_key(name)))
            if not group:
                continue
            ln, other = len(group["ln"]), len(group["non_ln"])
            if abs(other - ln) >= threshold:
                triggers.append(
                    {
                        "entity_type": kind,
                        "entity": name,
                        "ln": ln,
                        "non_ln": other,
                        "verdict": "non_ln" if other > ln else "ln",
                        "seed_group": [kind, entity_key(name)],
                    }
                )
    verdicts = {t["verdict"] for t in triggers}
    verdict = next(iter(verdicts)) if len(verdicts) == 1 else "unknown"
    types = {t["entity_type"] for t in triggers}
    route = {
        frozenset({"authors"}): "author",
        frozenset({"publishers"}): "publisher",
        frozenset({"authors", "publishers"}): "author_and_publisher",
    }
    return {
        "method": "association",
        "verdict": verdict,
        "route": route.get(frozenset(types)),
        "triggers": triggers,
        "conflict": len(verdicts) > 1,
        "threshold": threshold,
    }


class AssociationArgs(argparse.Namespace):
    evidence: pathlib.Path = pathlib.Path()
    candidates: pathlib.Path = pathlib.Path()
    threshold: int = 20


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("evidence", type=pathlib.Path)
    _ = parser.add_argument("candidates", type=pathlib.Path)
    _ = parser.add_argument("--threshold", type=int, required=True)
    args = parser.parse_args(namespace=AssociationArgs())
    evidence = [
        cast(AssociationRow, json.loads(s))
        for s in args.evidence.read_text(encoding="utf-8").split("\n")
        if s.strip()
    ]
    counts = association_counts(evidence)
    for line in args.candidates.read_text(encoding="utf-8").split("\n"):
        if line.strip():
            row = cast(AssociationRow, json.loads(line))
            print(
                json.dumps(
                    {
                        "candidate": row,
                        "decision": association_decide(row, counts, args.threshold),
                    },
                    ensure_ascii=False,
                )
            )


if __name__ == "__main__":
    main()
