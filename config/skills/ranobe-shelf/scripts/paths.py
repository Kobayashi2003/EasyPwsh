"""置き場 — 四つ。

    棚      整理済みの蔵書を置く場所
    置き場   まだ整理していない実体がある場所
    作業     台帳・計画・取消・隔離（**唯一の資産**）
    控え     源への問い合わせの控えと杜の索引。作り直せるので丸ごと消してよい

決まり方は 環境変数 → `.env` → 訊く の順。控えだけは物を動かさないので、
決まっていなければ訊かずに既定を使う。相対パスはスキルの直下から数える。

`.env` はスキルの直下に置く。**var の中には置けない** — var 自身が
そこに書いてあるので、先に読めないと場所が分からない。

道具はファイルを動かす。指す先を間違えると別の場所のファイルが動くので、
決まっていなければ黙って既定を使わずに人へ訊く。
"""

from __future__ import annotations

import os
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ENV_FILE = HERE / ".env"

# (鍵, 環境変数, 日本語, 説明, 既定値)
ITEMS = [
    (
        "shelf",
        "RANOBE_SHELF",
        "棚",
        "整理済みの蔵書を置く場所",
        str(Path.home() / "Books" / "LightNovels"),
    ),
    (
        "inbox",
        "RANOBE_INBOX",
        "置き場",
        "まだ整理していない実体がある場所",
        str(Path.home() / "Books" / "Inbox"),
    ),
    # 既定の作業データはスキルの直下。Gitの対象外。
    (
        "var",
        "RANOBE_VAR",
        "作業",
        "台帳・計画・取消を置く場所（唯一の資産）",
        str(HERE / "var"),
    ),
    # 既定の控えもスキルの直下。Gitの対象外。
    (
        "cache",
        "RANOBE_CACHE",
        "控え",
        "問い合わせの控えと索引を置く場所（作り直せる）",
        str(HERE / "cache"),
    ),
]
# 決まっていなくても訊かないもの
QUIET = {"cache"}
ENV = {k: e for k, e, *_ in ITEMS}


def load() -> dict:
    """`.env` を読む。`鍵=値` の行だけ見る。`#` から先は注釈。"""
    if not ENV_FILE.exists():
        return {}
    out = {}
    by_env = {e: k for k, e, *_ in ITEMS}
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        name, _, value = line.partition("=")
        key = by_env.get(name.strip())
        if key and value.strip():
            out[key] = value.strip().strip('"')
    return out


def save(d: dict) -> Path:
    """`.env` を書き直す。**説明を必ず添える** — 人が直に開いて直すため。"""
    lines = [
        "# ranobe-shelf の置き場。",
        "# ここを間違えると別の場所のファイルが動く。",
        "# 環境変数を立てておくと、こちらより優先される。",
        "",
    ]
    for k, e, jp, desc, _ in ITEMS:
        lines += [f"# {jp} — {desc}", f"{e}={d.get(k, '')}", ""]
    tmp = ENV_FILE.with_suffix(".tmp")
    tmp.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    tmp.replace(ENV_FILE)
    return ENV_FILE


def get(key: str) -> Path | None:
    v = os.environ.get(ENV.get(key, "")) or load().get(key)
    return HERE / v if v else None


def _need(key: str, jp: str) -> Path:
    p = get(key)
    if p is None:
        raise SystemExit(f"★ {jp}が決まっていません。\n\n" + prompt_text())
    return p


def shelf() -> Path:
    return _need("shelf", "棚")


def inbox() -> Path:
    return _need("inbox", "置き場")


def var() -> Path:
    p = _need("var", "作業場所")
    p.mkdir(parents=True, exist_ok=True)
    return p


def cache() -> Path:
    p = get("cache") or HERE / "cache"
    p.mkdir(parents=True, exist_ok=True)
    return p


def quarantine() -> Path:
    """★ 作らない。plan がここを呼ぶので、作ると「計画しただけ」で
    フォルダが生える。実際に置くとき apply が作る。"""
    return var() / "quarantine"


def missing() -> list:
    return [
        (k, e, jp, desc, old)
        for k, e, jp, desc, old in ITEMS
        if k not in QUIET and get(k) is None
    ]


def _pad(s: str, width: int) -> str:
    w = sum(2 if unicodedata.east_asian_width(c) in "FWA" else 1 for c in s)
    return s + " " * max(1, width - w)


def describe() -> str:
    cfg = load()
    out = []
    for k, e, jp, _, old in ITEMS:
        cur = get(k) or (Path(old) if k in QUIET else None)
        src = (
            "環境変数"
            if os.environ.get(e)
            else ".env"
            if k in cfg
            else "既定"
            if k in QUIET
            else "**未設定**"
        )
        out.append(
            "  "
            + _pad(jp, 8)
            + _pad(str(cur) if cur else "（決まっていない）", 46)
            + src
        )
    out.append(f"\n  設定ファイル  {ENV_FILE}")
    return "\n".join(out)


def prompt_text() -> str:
    ms = missing()
    if not ms:
        return ""
    lines = ["この道具はファイルを動かします。**置き場を確かめてください。**", ""]
    for _k, _e, jp, desc, old in ms:
        lines.append(f"  {jp}  — {desc}")
        lines.append(f"        未設定時の提案: {old}")
    lines += [
        "",
        "  これでよければ:  uv run cli.py config --default",
        '  変えるなら:      uv run cli.py config --shelf "…" --inbox "…" --var "…"',
        f"  直に書くなら:    {ENV_FILE}",
    ]
    return "\n".join(lines)


def use_defaults() -> Path:
    d = load()
    for k, _, _, _, old in ITEMS:
        d.setdefault(k, old)
    return save(d)


def set_many(**kw) -> Path:
    d = load()
    for k, v in kw.items():
        if v:
            d[k] = str(v)
    return save(d)
