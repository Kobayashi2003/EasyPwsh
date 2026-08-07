"""欠巻の標 — 持っていない巻の場所に、同じ形の名前で目印を置く。

棚は平らなので、持っている巻と同じ名前の形にしておけば、
標は**抜けているその場所に並ぶ**。開けば何の巻かが書いてある。

★ 標は記録ではない。台帳と源から**毎回引き直す派生物**で、
  台帳が変われば書き直る。標を読んで何かを決めてはいけない
  （記録/1-壊れ方.md 5 章 — 派生物を記録として読み直すと、
  古い答えが新しい事実を上書きする）。

★ タグは**手元の巻から継ぐ**。RanobeDB の publisher は文庫名ではないので
  （実測-5）、そこから採ると標だけ違う棚に並ぶ。
"""
import shutil
import sys
from datetime import date

import ledger as L
import paths
import place

MARK = ".txt"
HEAD = "これは欠巻の標です（実体はありません）"


def _inherit(vols: list) -> tuple:
    """手元の巻から レーベル・著者・絵師 を継ぐ。一番多いものを採る。

    ★ **同数のときの決め方まで決めておく。** 元は `max(set(vals), key=vals.count)`
      で、同数が二つあると set の巡り順で勝者が決まっていた。文字列の
      ハッシュは走るたびに変わるので、**同じ台帳から毎回ちがう標の名前**が
      出る。名前が変われば前の標は「要らないもの」として隔離へ下り、
      新しい名前で立て直される — 台帳が一行も動いていないのに、
      毎周 8〜19 本が隔離へ落ちていた。

      同数なら「巻号の若い巻のもの」を採る。作品の顔はふつう一巻にある。
    """
    ordered = sorted(vols, key=lambda v: (v.巻号 is None, v.巻号 or 0, v.巻ID))
    out = []
    for f in ("レーベル", "著者", "絵師"):
        vals = [getattr(v, f) for v in vols if getattr(v, f)]
        if not vals:
            out.append("")
            continue
        first = {}
        for i, v in enumerate(ordered):
            x = getattr(v, f)
            if x and x not in first:
                first[x] = i
        out.append(max(sorted(set(vals)), key=lambda x: (vals.count(x), -first[x])))
    return tuple(out)


def _text(v: L.Vol, w: dict, num) -> str:
    return "\n".join([
        HEAD, "=" * len(HEAD), "",
        f"作品   {v.作品}（{w.get('題名', '')}）",
        f"巻号   第{num:g}巻",
        f"題名   {v.題名}",
        f"発売日 {v.発売日}",
        "",
        "同じ作品の巻は持っているのに、この巻だけ手元に無い。",
        "タグは手元の巻から継いだので、抜けているその場所に並ぶ。",
        "",
        f"引いた元 RanobeDB {v.作品} の巻一覧",
        # ★ 引いた日は書かない。中身が毎回変わると、同じ標を毎周書き直す
        #   ことになり、いつ何が変わったのか本当に見たいときに埋もれる
        "",
        "★ この紙は台帳から引き直される。書き足しても次で消える。",
        "  手に入れたら、その本を置き場に入れて一周回せば標は下がる。",
        "",
    ])


def build(today: date | None = None) -> tuple:
    """(置く標, 下ろす標, 引けなかった作品) を返す。まだ何も書かない。

    `today` は date。**状態を決めるのと「もう出たか」を見るので二つの形が要る**
    ので、ここで yymmdd も作る（state_of は date、発売日は文字列で比べる）。
    """
    import sources as S
    root = paths.shelf()
    works = L.load_works()
    vols = list(L.load_volumes().values())
    cut = (today or date.today()).strftime("%y%m%d")

    # ★ 「持っている」に数えるのは本篇だけではない。番外や合本版として
    #   入れた巻が RanobeDB では main のことがあり、本篇だけ見ると
    #   **持っている巻に標が立つ**
    by_work, held_by = {}, {}
    for v in vols:
        if not v.作品 or v.種類 == "其他":
            continue
        if v.種類 == "本篇":
            by_work.setdefault(v.作品, []).append(v)
        if v.巻号 is not None:
            held_by.setdefault(v.作品, set()).add(v.巻号)

    put, blind = {}, []
    for wid, mine in sorted(by_work.items()):
        w = S.work(wid)
        if not w or not w.get("巻"):
            blind.append(wid)
            continue
        label, author, artist = _inherit(mine)
        held = held_by.get(wid, set())
        dest = root / L.state_of(works.get(wid), today)
        for b in w["巻"]:
            # ★ 名前を date にしない。import した date を関数ごと覆って、
            #   上の date.today() が UnboundLocalError で落ちる
            num, when = b.get("順"), b.get("発売日")
            # ★ まだ出ていない巻は欠けていない。予告に標を立てない
            if num is None or num in held or b.get("型") != "main":
                continue
            if not when or when > cut:
                continue
            ghost = L.Vol(巻ID="", 題名=b.get("題名") or "", レーベル=label,
                          著者=author, 絵師=artist, 発売日=when,
                          種類="本篇", 作品=wid, 巻号=num)
            if not place.safe(ghost.題名):
                continue
            put[dest / place.file_name(ghost, MARK)] = _text(ghost, w, num)

    # 棚に在るが今の台帳では要らなくなった標を拾う（手に入れた巻など）
    drop = []
    for p in root.rglob("*" + MARK):
        if p in put:
            continue
        try:
            if p.read_text(encoding="utf-8").startswith(HEAD):
                drop.append(p)
        except (OSError, UnicodeDecodeError):
            continue
    return put, drop, blind


def apply(put: dict, drop: list) -> tuple:
    """標を書き、要らなくなった標は**隔離へ移す**（消さない）。

    ★ 状態は時間の関数なので、連載中 → 打ち切り のように**同じ標が段を移る**。
      これを「下ろして立て直す」と扱うと、時が経つだけで隔離が標で埋まる。
      名前が同じまま親だけ変わったものは、**移す**。
    """
    moved = {}
    by_name = {}
    for p in put:
        by_name.setdefault(p.name, []).append(p)
    rest = []
    for p in drop:
        cand = [q for q in by_name.get(p.name, []) if not q.exists()]
        if len(cand) == 1:
            cand[0].parent.mkdir(parents=True, exist_ok=True)
            # ★ replace は**別のドライブへは動かせない**。棚は E:、隔離は D: に
            #   在るので、ここが replace だと下ろすたびに落ちる
            shutil.move(str(p), str(cand[0]))
            moved[cand[0]] = p
        else:
            rest.append(p)
    drop = rest

    n = 0
    for p, text in put.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists() and p.read_text(encoding="utf-8") == text:
            continue
        L.write_atomic(p, text)
        n += 1
    q = paths.quarantine() / "下ろした欠巻の標"
    m = 0
    for p in drop:
        q.mkdir(parents=True, exist_ok=True)
        if not (q / "README.txt").exists():
            L.write_atomic(q / "README.txt", QUARANTINE_README)
        t = q / p.name
        i = 1
        while t.exists():
            t, i = q / f"{p.stem} ({i}){p.suffix}", i + 1
        shutil.move(str(p), str(t))      # ★ 別ドライブ（棚 E: → 隔離 D:）
        m += 1
    return n, m, len(moved)


QUARANTINE_README = """このフォルダに在るもの
====================

かつて棚に立てていた欠巻の標のうち、**今の台帳では要らなくなったもの**。
その巻を手に入れたか、作品の見立てが変わったか、源の巻一覧が変わったか。

標は台帳から毎回引き直す派生物なので、ここに在るものに用は無い。
**消していない**のは、いつ何が下りたかを残しておくため。
"""


def main(argv: list) -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    go = "--apply" in argv
    put, drop, blind = build()
    print(f"欠巻の標 {len(put)} 本 / 下ろすもの {len(drop)} 本")
    if blind:
        print(f"  巻一覧が引けなかった作品 {len(blind)} 件: "
              f"{'、'.join(blind[:6])}{' …' if len(blind) > 6 else ''}")
    if not go:
        for p in sorted(put)[:40]:
            print(f"   {p.parent.name} / {p.name}")
        if len(put) > 40:
            print(f"   … 他 {len(put) - 40} 本")
        print("\n見ただけ。立てるなら --apply")
        return 0
    n, m, mv = apply(put, drop)
    print(f"{n} 本を書き、{mv} 本を段の移動で置き直し、{m} 本を隔離へ下ろした")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
