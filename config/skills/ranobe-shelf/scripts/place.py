"""配置 — 台帳のとおりにファイルを動かす。**判断しない**。

    棚 / 状態 / [レーベル][著者][絵師][発売日] 巻の題名.epub

系列のフォルダは作らない。棚は二段しかない。

    plan → 門① → 門② → 門③ → apply → undo

    ① ops が成立するか       元があるか、先が塞がっていないか
    ② 名前のタグが減らないか   付け直しで情報を落とさない
    ③ その plan が今の台帳から作られたか

ops の種類は 移動・改名 の二つだけ。削除は無い。
退けるものは隔離先へ移す。
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import unicodedata
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import ledger as L
import paths

MOVE, RENAME = "移動", "改名"
KINDS = (MOVE, RENAME)

# Windows が受け付けない字。**消さずに似た形の全角へ逃がす**
_FS_MAP = str.maketrans({"\\": "＼", "/": "／", ":": "：", "*": "＊",
                         "?": "？", '"': "”", "<": "＜", ">": "＞", "|": "｜"})
# NFKC が揃えてくれない波ダッシュだけ手で揃える。
# ★ 長音符 ー(U+30FC) は日本語の字。ここで - に変えると コーヒー が壊れる
_TILDE = dict.fromkeys(map(ord, "〜﹏"), ord("~"))
_CTRL = {c: None for c in range(0x20)}
_BRACKETS = re.compile(r"^((?:\[[^\[\]]*\])+)\s*(.*)$")


@dataclass
class Op:
    種類: str
    元: str
    先: str
    根拠: str

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False)


# 棚に置ける実体の形。**ここが唯一の一覧**（記録/1-壊れ方.md 5-9）。
# ★ ここに無い形は、道具から**存在ごと見えない**。置き場に 3,936 ファイル
#   在るのに「材料 0 件」と報告し、`.zip` の中の 104 冊を一度も調べずに
#   「処理し終えた」と言った。形を足すときは、足しただけで置き場の
#   数え方が変わることを承知して足す。
BOOK_EXT = (".epub", ".pdf", ".azw3", ".mobi", ".cbz", ".cbr")


def safe(s: str) -> str:
    """棚に出す名前にする。

    ① NFKC で全角を半角へ揃える（２→2, Ａ→A, ！→!, （→(, ｶﾞ→ガ）
    ② Windows が受け付けない 9 字だけ、似た形の全角へ逃がす
       — つまり ？ ： ／ ＊ ＜ ＞ ｜ ＼ ” は全角のまま揃う
    ③ 制御文字を落とし、空白を詰め、末尾の点と空白を削る

    ★ NFKC の前後で順序が大事。先に揃えないと ？ と ? が混在し、
      後で逃がさないと Windows に置けない。
    """
    s = unicodedata.normalize("NFKC", s or "")
    s = s.translate(_TILDE).translate(_CTRL).translate(_FS_MAP)
    return re.sub(r"\s+", " ", s).strip().rstrip(". ")


def tags_of(name: str) -> list:
    m = _BRACKETS.match(name or "")
    return re.findall(r"\[([^\[\]]*)\]", m.group(1)) if m else []


def file_name(v: L.Vol, suffix: str) -> str:
    tags = "".join(f"[{safe(t)}]" for t in v.tags())
    return safe(tags + " " + v.題名) + suffix


SPARE_DIR = "重複版（採用しなかった方）"
SPARE_README = """このフォルダに在るもの
====================

同じ巻に実体が二つ以上あったとき、棚に置かなかった方をここへ移してある。
**消していない。** 名前の末尾の (V000123-1) が、台帳のどの巻から来たかを指す。

採用の選び方（記録/1-壊れ方.md 7-4）:

    ① epub を優先する
    ② どちらも epub なら、ファイルサイズの大きい方
    ③ サイズも同じなら、日付の新しい方

選び直したいときは、台帳でその巻を record --id で書き直してから
plan を作り直せば、こちらが棚へ戻り、今棚に在る方がここへ来る。
"""


def build(today=None) -> tuple:
    root = paths.shelf()
    works = L.load_works()
    ops, stuck = [], []
    for v in L.load_volumes().values():
        cur = v.current()
        if cur is None:
            continue
        # ★ 棚に置かないと決めた巻は動かさない。実体は今在る場所に置いたまま。
        #   台帳の行は消さないので「持っていたが棚から外した」ことは残る。
        #   ここを飛ばさないと、置き場へ戻したものが毎周棚へ引き戻される
        if v.判断.get("棚外"):
            continue
        # ★ 揃えたあとで見る。「..」のように、揃えると何も残らない題名がある
        if not safe(v.題名):
            stuck.append(f"{v.巻ID}: 題名が無い（揃えると空になる）")
            continue
        if v.種類 == "其他":
            dest = root / L.OTHER_DIR
        else:
            dest = root / L.state_of(works.get(v.作品), today)
        src = Path(cur.path)
        want = dest / file_name(v, src.suffix)
        if src != want:
            if not src.exists():
                stuck.append(f"{v.巻ID}: 実体が見つからない {src}")
            else:
                ops.append(Op(MOVE if src.parent != want.parent else RENAME,
                              str(src), str(want), v.巻ID))
        # 採用しなかった実体は隔離へ。**消さない**
        # ★ 巻ID は名前の**後ろ**に付ける。前に付けるとタグが頭から外れ、
        #   門②が「タグが減った」と読む
        for i, f in enumerate(v.spare(), 1):
            s = Path(f.path)
            w = (paths.quarantine() / SPARE_DIR
                 / (file_name(v, "") + f" ({v.巻ID}-{i}){s.suffix}"))
            if s == w:
                continue
            if not s.exists():
                stuck.append(f"{v.巻ID}: 退ける実体が見つからない {s}")
                continue
            ops.append(Op(MOVE, str(s), str(w), v.巻ID))
    return ops, stuck


def order_ops(ops: list) -> tuple:
    """先を塞いでいる相手を先に動かす順に並べ替える。

    ★ 同じ巻の写しを入れ替えるとき、新しい方の行き先を古い方が塞いでいる。
      順序を考えないと門①で必ず止まる（旧い道具では、両方が退避されて
      その巻が棚から消えた）。堂々巡り（入れ替え）は動かさずに報告する。
    """
    by_src = {_norm(o.元): i for i, o in enumerate(ops) if o.元}
    need = {i: set() for i in range(len(ops))}
    for i, o in enumerate(ops):
        j = by_src.get(_norm(o.先))
        if j is not None and j != i:
            need[i].add(j)          # i の前に j を動かす
    out, done = [], set()
    while len(out) < len(ops):
        ready = [i for i in range(len(ops))
                 if i not in done and not (need[i] - done)]
        if not ready:
            stuck = [i for i in range(len(ops)) if i not in done]
            return out, [f"入れ替えが堂々巡りしている: "
                         + "、".join(Path(ops[i].先).name for i in stuck[:4])]
        for i in ready:
            out.append(ops[i])
            done.add(i)
    return out, []


def check(ops: list) -> list:
    bad, seen = [], set()
    # この計画の中で「そこから退く」実体。塞いでいても順番を守れば空く
    vacating = {_norm(o.元) for o in ops if o.元}
    for o in ops:
        if o.種類 not in KINDS:
            bad.append(f"知らない種類 {o.種類}（削除は存在しない）")
            continue
        if not o.根拠:
            bad.append(f"根拠が無い: {o.先}")
        if not o.元:
            bad.append(f"元が無い: {o.先}")
        elif not Path(o.元).exists():
            bad.append(f"元が見つからない: {o.元}")
        low = _norm(o.先)
        if low in seen:
            bad.append(f"同じ先へ二つ置こうとしている: {o.先}")
        seen.add(low)
        if Path(o.先).exists() and low != _norm(o.元 or "") \
                and low not in vacating:
            bad.append(f"先が塞がっている: {o.先}")
    return bad + order_ops(ops)[1]


# 日は 00 や 99 が普通に来る（源が日を持たない月）ので、そこは見ない
_DATE_TAG = re.compile(r"^\d{6}$")
# ★ `[000000]` は旧い流れが「分からない」のしるしに使っていた**空札**。
#   日付でもなければ書誌でもないので、門②では**どちらにも数えない**。
#   日付と読めば「日付が消える」で止まり、書誌と読めば「タグが減る」で止まる —
#   中身の無い札を守ろうとすると、どちらの数え方でも正しい付け直しが止まる
_VOID_TAG = re.compile(r"^0{6}$")


def check_format(ops: list) -> tuple:
    """門② — 付け直しで書誌が**痩せて**いないか。(止めるもの, 知らせるもの)。

    見るのは **数**。値そのものではない。

    ★ タグの値は入れ替わる。それが正しいことの方が多い —
      日付は旧い流れと源の紙の発売日で違って当たり前だし、
      レーベルは「B6判」から「KADOKAWA」へ直る（実測-26）し、
      同じ人を源によって「古河 樹」「古河樹」と書き分ける（実測-25）。
      **値の違いで止めると、正しい付け直しが軒並み止まる。**

    ★ この門が守っているのは「台帳のタグが埋まっていない」ことだけ。
      台帳に無いものは名前にも出ないので、**タグの数が減る**形で現れる。
      値が変わったことは止めずに**知らせる**（人が見て気づけるように）。

    ★ 値の取り違えはここでは捕まらない。それは `audit` の仕事
      （魔女と傭兵6上/下 を捕まえたのも audit の二つの突き合わせだった）。
    """
    stop, tell = [], []
    for o in ops:
        if not o.元:
            continue
        a, b = Path(o.元).name, Path(o.先).name
        ta = [x for x in tags_of(a) if not _VOID_TAG.match(x)]
        tb = [x for x in tags_of(b) if not _VOID_TAG.match(x)]
        na = [x for x in ta if not _DATE_TAG.match(x)]
        nb = [x for x in tb if not _DATE_TAG.match(x)]
        if len(nb) < len(na):
            stop.append(f"タグが {len(na)} 個から {len(nb)} 個へ減る"
                        f"（{a} -> {b}）")
        if any(_DATE_TAG.match(x) for x in ta) \
                and not any(_DATE_TAG.match(x) for x in tb):
            stop.append(f"日付が消える（{a} -> {b}）")
        gone = [x for x in na if x not in nb]
        if gone and len(nb) >= len(na):
            tell.append(f"{'、'.join(gone)} → "
                        f"{'、'.join(x for x in nb if x not in na)}（{a}）")
    return stop, tell


def ledger_stamp() -> str:
    p = L.volumes_path()
    if not p.exists():
        return "0:-"
    raw = p.read_bytes()
    return f"{raw.count(10)}:{hashlib.blake2b(raw, digest_size=8).hexdigest()}"


def check_fresh(stamp: str) -> list:
    cur = ledger_stamp()
    if stamp != cur:
        return [f"台帳が変わっている（計画時 {stamp} / 今 {cur}）。plan を作り直すこと"]
    return []


def save_plan(ops: list, stuck: list) -> Path:
    L.ensure_dirs()
    p = L.plans_dir() / f"{datetime.now():%Y%m%d-%H%M%S}.jsonl"
    head = {"作った時": L.now(), "台帳": ledger_stamp(), "置けなかった": stuck}
    with p.open("w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(head, ensure_ascii=False) + "\n")
        for o in ops:
            f.write(o.to_json() + "\n")
    return p


def load_plan(p: Path) -> tuple:
    lines = [x for x in p.read_text(encoding="utf-8").splitlines() if x.strip()]
    return json.loads(lines[0]), [Op(**json.loads(x)) for x in lines[1:]]


def _rewrite_paths(moved: dict) -> int:
    """動いた実体の path を追記する。

    ★ 鍵は**元の path**。巻ID にすると、一つの巻が二つ動いたとき
      （採用を棚へ／余りを隔離へ）後の行が前の行を潰す。
    """
    if not moved:
        return 0
    rows = []
    for v in L.load_volumes().values():
        hit = [f for f in v.ファイル if _norm(f.path) in moved]
        if not hit:
            continue
        v.ファイル = [L.FileRef(f.指紋, moved.get(_norm(f.path), f.path),
                              f.サイズ, f.更新, f.採用) for f in v.ファイル]
        v.判断 = {**v.判断, "path更新": L.now()}
        rows.append(v)
    return L.append_volumes(rows)


def _norm(p: str) -> str:
    return str(Path(p)).lower()


def _roots() -> set:
    """ここから上は消さない。棚・置き場そのものと、棚の一段目。"""
    shelf, inbox = paths.shelf(), paths.inbox()
    keep = {shelf.resolve(), inbox.resolve()}
    for s in list(L.STATES) + [L.OTHER_DIR]:
        keep.add((shelf / s).resolve())
    for q in (shelf, inbox):
        keep.update(x.resolve() for x in q.parents)
    return keep


def sweep_empty(dirs) -> int:
    """空になったフォルダを畳む。**中に何か在れば触らない**。

    ファイルは一つも消さない。空の入れ物だけを取り除く。
    取消でファイルを戻すときは mkdir で作り直されるので、戻せなくならない。
    """
    keep = _roots()
    n = 0
    todo = sorted({Path(d).resolve() for d in dirs}, key=lambda x: -len(x.parts))
    seen = set()
    while todo:
        d = todo.pop(0)
        if d in seen or d in keep or not d.exists() or not d.is_dir():
            continue
        seen.add(d)
        if any(d.iterdir()):
            continue
        try:
            d.rmdir()
            n += 1
        except OSError:
            continue
        if d.parent not in keep:
            todo.append(d.parent)
    return n


def apply(p: Path, *, force: bool = False) -> tuple:
    head, ops = load_plan(p)
    thin, swapped = check_format(ops)
    problems = check(ops) + thin
    if not force:
        problems += check_fresh(head.get("台帳", ""))
    if problems:
        return 1, None, problems
    if not ops:
        return 0, None, ["動かすものはありません"]

    ops, cyc = order_ops(ops)      # 塞いでいる相手を先に退かす
    if cyc:
        return 1, None, cyc

    up = L.undos_dir() / p.name
    up.parent.mkdir(parents=True, exist_ok=True)
    moved, froms, err = {}, set(), None
    with up.open("w", encoding="utf-8", newline="\n") as u:
        for o in ops:
            dst = Path(o.先)
            try:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(o.元, str(dst))
            except Exception as e:      # 途中で落ちても、動いた分の取消は残る
                err = f"{o.元} を動かせない — {type(e).__name__}: {e}"
                break
            moved[_norm(o.元)] = str(dst)
            froms.add(Path(o.元).parent)
            u.write(Op(o.種類, str(dst), o.元, o.根拠).to_json() + "\n")
            # 退けた先には、なぜそこに在るかを残す（配置-3）
            if dst.parent.name == SPARE_DIR:
                rm = dst.parent / "README.txt"
                if not rm.exists():
                    rm.write_text(SPARE_README, encoding="utf-8", newline="\n")

    msgs = [f"{len(moved)} 件を実行。台帳の path を "
            f"{_rewrite_paths(moved)} 行追記",
            f"空になったフォルダを {sweep_empty(froms)} 畳んだ"]
    # 門②が通した「値の入れ替わり」を見せる。止めはしないが、黙って
    # 通すと台帳の取り違えが名前に流れ込んだことに誰も気づかない
    if swapped:
        msgs.append(f"タグの値が入れ替わったもの {len(swapped)} 件:")
        msgs += [f"   {x}" for x in swapped[:8]]
        if len(swapped) > 8:
            msgs.append(f"   … 他 {len(swapped) - 8} 件")
    if err:
        return 1, up, [f"★ 途中で止まった: {err}",
                       f"動いた {len(moved)} 件の取消は {up}"] + msgs
    return 0, up, msgs


def undo(p: Path) -> tuple:
    ops = [Op(**json.loads(x))
           for x in p.read_text(encoding="utf-8").splitlines() if x.strip()]
    moved, froms, n, blocked = {}, set(), 0, []
    for o in reversed(ops):
        if not o.先 or not Path(o.元).exists():
            continue
        back = Path(o.先)
        # ★ 戻す先が塞がっていたら上書きしない。黙って一冊消えるのを防ぐ
        if back.exists() and back.resolve() != Path(o.元).resolve():
            blocked.append(f"戻す先が塞がっている: {o.先}")
            continue
        back.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(o.元, o.先)
        n += 1
        froms.add(Path(o.元).parent)
        moved[_norm(o.元)] = o.先
    return n, _rewrite_paths(moved), sweep_empty(froms), blocked
