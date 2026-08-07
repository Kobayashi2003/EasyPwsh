"""台帳 — 巻と作品。**追記のみ、消さない**。

巻台帳の鍵は 巻ID そのもの。同じ鍵が暗黙にぶつかることは無い。
判断を改めるときは巻IDを明示して追記する（後の行が今の答え）。

作品は id しか持たない。名前を付けず、フォルダも作らず、統合もしない。
唯一の役目は、同じ作品の巻が違う状態に散らばらないようにすること。

状態は保存しない。**時間の関数なので毎回計算する** —
最終巻から 12 か月を過ぎれば連載中は打ち切りに変わる。
"""

from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from pathlib import Path

import paths

KINDS = ("本篇", "特典", "番外", "短編集", "合本版", "其他")
STATES = ("1. 連載中", "2. 打ち切り", "3. 完結", "4. 未分類")
OTHER_DIR = "_其他"
STALE_MONTHS = 12

_CHUNK = 64 * 1024


def var() -> Path:
    return paths.var()


def volumes_path() -> Path:
    return var() / "volumes.jsonl"


def works_path() -> Path:
    return var() / "works.jsonl"


def cache_dir() -> Path:
    return var() / "cache"


def plans_dir() -> Path:
    return var() / "plans"


def undos_dir() -> Path:
    return var() / "undos"


def survey_dir() -> Path:
    return var() / "survey"


def pending_path() -> Path:
    return var() / "pending.jsonl"


def ensure_dirs() -> None:
    for d in (var(), cache_dir(), plans_dir(), undos_dir(), survey_dir()):
        d.mkdir(parents=True, exist_ok=True)


def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def write_atomic(path: Path, text: str) -> Path:
    """書き換えは一度で入れ替える。

    直接 open("w") すると、途中で落ちたときに中身が切れたまま残る。
    索引は作り直しに 20 分かかるので、切れると高くつく。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    tmp.replace(path)
    return path


def fingerprint(p: Path) -> str:
    st = p.stat()
    h = hashlib.blake2b(digest_size=16)
    h.update(str(st.st_size).encode())
    with p.open("rb") as f:
        h.update(f.read(_CHUNK))
        if st.st_size > _CHUNK * 2:
            f.seek(-_CHUNK, 2)
            h.update(f.read(_CHUNK))
    return h.hexdigest()


@dataclass
class FileRef:
    指紋: str
    path: str
    サイズ: int = 0
    更新: str = ""
    採用: bool = False


@dataclass
class Vol:
    巻ID: str
    題名: str = ""
    レーベル: str = ""
    著者: str = ""
    絵師: str = ""
    発売日: str = ""
    ISBN: str = ""
    種類: str = "本篇"
    作品: str = ""
    巻号: float | None = None
    ファイル: list = field(default_factory=list)
    判断: dict = field(default_factory=dict)

    def key(self) -> str:
        return self.巻ID

    def current(self):
        return next((f for f in self.ファイル if f.採用), None)

    def spare(self) -> list:
        """採用しなかった実体。**消さずに隔離へ移す**（巻-4）。"""
        return [f for f in self.ファイル if not f.採用]

    def tags(self) -> list:
        # 二番目は必ず著者。著者が無いときに絵師を繰り上げない
        names = (self.レーベル, self.著者, self.絵師 if self.著者 else "",
                 self.発売日)
        return [t for t in names if t]

    def to_json(self) -> str:
        d = asdict(self)
        d["ファイル"] = [asdict(f) if not isinstance(f, dict) else f
                       for f in self.ファイル]
        return json.dumps(d, ensure_ascii=False)

    @classmethod
    def from_dict(cls, d: dict) -> "Vol":
        return cls(巻ID=d["巻ID"], 題名=d.get("題名", ""),
                   レーベル=d.get("レーベル", ""), 著者=d.get("著者", ""),
                   絵師=d.get("絵師", ""), 発売日=d.get("発売日", ""),
                   ISBN=d.get("ISBN", ""), 種類=d.get("種類", "本篇"),
                   作品=d.get("作品", ""), 巻号=d.get("巻号"),
                   ファイル=[FileRef(**f) for f in d.get("ファイル", [])],
                   判断=d.get("判断", {}))


@dataclass
class Work:
    作品: str
    表示名: str = ""          # 報告に出すだけ。照合には使わない
    完結: bool | None = None
    最終巻: str = ""          # 既に出た巻のうち最新の yyyymmdd
    判断: dict = field(default_factory=dict)

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False)

    @classmethod
    def from_dict(cls, d: dict) -> "Work":
        return cls(作品=d["作品"], 表示名=d.get("表示名", ""),
                   完結=d.get("完結"), 最終巻=d.get("最終巻", ""),
                   判断=d.get("判断", {}))


def _months_since(yyyymmdd: str, today: date | None = None) -> int | None:
    s = (yyyymmdd or "").strip()
    if len(s) < 6 or not s[:6].isdigit():
        return None
    if len(s) == 6:
        y, m = 2000 + int(s[:2]), int(s[2:4])
    else:
        y, m = int(s[:4]), int(s[4:6])
    t = today or date.today()
    return (t.year - y) * 12 + (t.month - m)


def state_of(w: Work | None, today: date | None = None) -> str:
    """完結 → 最終巻からの月数 → 未分類。**保存せず毎回計算する**。"""
    if w is None:
        return "4. 未分類"
    if w.完結:
        return "3. 完結"
    n = _months_since(w.最終巻, today)
    if n is None:
        return "4. 未分類"
    return "2. 打ち切り" if n > STALE_MONTHS else "1. 連載中"


def _read(path: Path) -> list:
    """台帳を読む。**読めない行は飛ばし、飛ばしたと言う。**

    ★ 一行でも壊れていると全部の道具が止まる、というのが元の形だった。
      追記の途中で切れた欠片（`}}` の二文字）が一つ末尾に出来ただけで、
      検め・配置・標のすべてが JSONDecodeError で落ちた。しかも
      落ちた場所は「検め」の中なので、**その周の検めが丸ごと飛んだ**。
      台帳は一行ずつが独立した記録なのだから、壊れた一行は
      その一行だけの問題に留めるべきだった（壊れ方 4 章）。

    ★ 黙って飛ばさない。何行目が読めなかったかを必ず言う。
    """
    if not path.exists():
        return []
    out, bad = [], []
    for i, x in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not x.strip():
            continue
        try:
            out.append(json.loads(x))
        except json.JSONDecodeError:
            bad.append((i, x[:40]))
    for i, frag in bad:
        print(f"★ {path.name} の {i} 行目が読めない（飛ばした）: {frag!r}",
              file=sys.stderr)
    return out


def _append(path: Path, rows: list) -> int:
    """★ 一行ずつ write して flush する。まとめて書くと、途中で落ちたときに
      **行の途中で切れた欠片**が残る。実際それで works.jsonl の末尾に
      `}}` が出来た（複数の周を並行して回していた）。
    """
    if not rows:
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as f:
        for r in rows:
            f.write(r.to_json() + "\n")
            f.flush()
    return len(rows)


def load_volumes() -> dict:
    out = {}
    for d in _read(volumes_path()):
        v = Vol.from_dict(d)
        out[v.巻ID] = v
    return out


def load_works() -> dict:
    out = {}
    for d in _read(works_path()):
        w = Work.from_dict(d)
        out[w.作品] = w
    return out


def append_volumes(vols: list) -> int:
    return _append(volumes_path(), vols)


def append_works(items: list) -> int:
    return _append(works_path(), items)


def next_volume_id() -> str:
    n = 0
    for d in _read(volumes_path()):
        i = d.get("巻ID", "")
        if i.startswith("V") and i[1:].isdigit():
            n = max(n, int(i[1:]))
    return f"V{n + 1:06d}"


def decision(by: str, why: str) -> dict:
    if by in ("agent", "user") and not (why or "").strip():
        raise ValueError(f"{by} の判断には理由が要る")
    return {"時": now(), "by": by, "why": why}


def settled_fingerprints() -> set:
    return {f.指紋 for v in load_volumes().values() for f in v.ファイル}
