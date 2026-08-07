"""ラノベの棚を整える道具。**確定した操作だけ。判断は一つも持たない**。

    python cli.py <命令> [引数]

どの本か・どの作品か・種類は何か を決めるのは呼ぶ側（AI）。
道具がするのは、材料を出すこと、決まったことを記録すること、
決まったとおりにファイルを動かすこと。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

import epub as E          # noqa: E402
import ledger as L        # noqa: E402
import mori as M          # noqa: E402
import paths              # noqa: E402
import place as P         # noqa: E402
import same as SM         # noqa: E402
import sources as S       # noqa: E402

BOOK_EXT = P.BOOK_EXT      # ★ 一覧は place に一つだけ置く


def _t(s, n: int) -> str:
    s = (s or "").replace("\n", " ")
    return s if len(s) <= n else s[:n - 1] + "…"


def _norm_path(p: str) -> str:
    return str(Path(p)).lower()


def _need_paths() -> bool:
    if paths.missing():
        print(paths.prompt_text())
        return False
    return True


def cmd_config(a) -> int:
    if a.default:
        paths.use_defaults()
        print(f"これまで使っていた場所を {paths.ENV_FILE} に書きました")
    if a.shelf or a.inbox or a.var:
        paths.set_many(shelf=a.shelf, inbox=a.inbox, var=a.var)
        print(f"指定された場所で {paths.ENV_FILE} を上書きしました")
    print()
    print(paths.describe())
    if paths.missing():
        print("\n" + paths.prompt_text())
        return 1
    return 0


# ---------------------------------------------------------------- 材料

def _ask_word(info: dict) -> str:
    t = (info.get("opf") or {}).get("題名") or ""
    if not t.strip():
        t = re.sub(r"^(?:\[[^\]]*\]\s*)+", "", info["ファイル名"])
        t = re.sub(r"\.(epub|pdf|azw3|mobi|cbz|cbr)$", "", t, flags=re.I)
    return t.strip()


def _mori_line(r: dict, mark: str) -> str:
    return (f"   [{mark}] {r.get('label', '-')} {r.get('date', '-')}"
            f" 「{_t(r.get('title', ''), 40)}」"
            f" 著:{r.get('author') or '-'} 絵:{r.get('artist') or '-'}"
            f" {r.get('isbn') or ('電子専売' if r.get('digital_only') else '-')}")


def _survey_write(fp: str, rec: dict) -> None:
    L.survey_dir().mkdir(parents=True, exist_ok=True)
    (L.survey_dir() / f"{fp}.json").write_text(
        json.dumps(rec, ensure_ascii=False, indent=1), encoding="utf-8")


def cmd_materials(a) -> int:
    if not _need_paths():
        return 1
    L.ensure_dirs()
    root = paths.inbox()
    if not root.exists():
        print(f"★ {root} が無い")
        return 1

    done = L.settled_fingerprints()
    pend = _load_pend()
    files = sorted(p for p in root.rglob("*")
                   if p.is_file() and p.suffix.lower() in BOOK_EXT)
    todo, n_done = [], 0
    for p in files:
        fp = L.fingerprint(p)
        if fp in done:
            n_done += 1
            continue
        if fp in pend and not a.include_pending:
            continue
        if len(todo) < a.count:
            todo.append((fp, p))

    print(f"# 材料  {len(todo)} 件"
          f"（{root} に {len(files)} 件、台帳済み {n_done}、未決 {len(pend)}）\n")
    if not todo:
        print("整理していない実体はもう無い")
        return 0

    index = M.load_index()
    print(f"（杜の索引 {len(index):,} 件）\n")

    for fp, p in todo:
        info = E.read(p)
        ok = info["奥付"]
        b = info["本文"]
        opf = info.get("opf") or {}
        word = _ask_word(info)

        rec = {"指紋": fp, "見た時": L.now(),
               "実体": {"path": str(p), "サイズ": p.stat().st_size},
               "自身": info, "問い": []}

        print(f"── {fp}  {_t(p.name, 66)}")
        if info["読めない理由"]:
            print(f"   ★ 中身が読めない: {info['読めない理由']}")
        else:
            got = [x for x in (
                ok["レーベル"],
                f"紙{ok['紙の日付']}" if ok["紙の日付"] else "",
                f"電子{ok['電子の日付']}" if ok["電子の日付"] else "",
                f"ISBN{ok['ISBN']}" if ok["ISBN"] else "") if x]
            print(f"   {b['字数']:,}字 画像{b['画像']} 頁{b['頁']}  奥付: "
                  + (" ".join(got) if got else
                     ("見つけたが何も取れず" if ok["読めた"] else "見つからず")))
            # ★ その本が自分を何と呼んでいるか。ファイル名は一冊ずれている
            #   ことがあるので（壊れ方 1-9）、判断のときは必ずここを見る
            if info.get("柱"):
                print(f"   柱 「{_t(info['柱'], 62)}」")
            print(f"   OPF「{_t(opf.get('題名', ''), 54)}」"
                  f" 著者={'、'.join(opf.get('著者') or []) or '-'}"
                  f" 日付={opf.get('日付') or '-'}"
                  f" 出版社={opf.get('出版社') or '-'}")

        # ① 手元の索引  ② 網の杜  ③ 他の二源
        isbn = ok.get("ISBN", "")
        hit = M.by_isbn(isbn, index) if isbn else []
        if hit:
            print("   杜（ISBN 一致・確定）")
            for r in hit:
                print(_mori_line(r, "杜"))
            rec["問い"].append({"源": "mori", "経路": "isbn", "答え": hit})
        else:
            res = M.find(word, index)
            # ★ 一致と示唆を混ぜない。混ぜると後から読む側が示唆を答えと読む
            rec["問い"].append({
                "源": "mori", "語": word,
                "経路": ("index-exact:" + res["経路"]) if res["exact"]
                        else ("index-hint" if res["hint"] else "index-none"),
                "答え": res["exact"], "示唆": res["hint"]})
            if res["exact"]:
                print("   杜（題名 完全一致）")
                for r in res["exact"]:
                    print(_mori_line(r, "杜"))
                isbn = isbn or next((r["isbn"] for r in res["exact"]
                                     if r.get("isbn")), "")
            elif res["hint"]:
                print("   杜（**示唆のみ。断定に使わない**）")
                for r in res["hint"][:5]:
                    print(_mori_line(r, "示唆"))
            else:
                print("   杜: 索引に無し")

            # 奥付の レーベル×発売月 で候補を小さくする（選ぶのはあなた）
            cands = M.by_label_month(ok.get("レーベル", ""),
                                     ok.get("紙の日付", ""), index)
            if cands and not res["exact"]:
                print(f"   杜（{ok['レーベル']} の {ok['紙の日付'][:4]} 月"
                      f" — 候補 {len(cands)} 件）")
                for r in cands[:12]:
                    print(_mori_line(r, "候補"))
                rec["問い"].append({"源": "mori", "経路": "label+month",
                                    "答え": cands})

        # ISBN が手に入ったら RanobeDB で作品と巻号まで確定させる
        if isbn and not a.no_isbn:
            d = S.by_isbn(isbn)
            rec["問い"].append({"源": "ranobedb", "経路": "isbn",
                                "isbn": isbn, "答え": d})
            if d:
                print(f"   RDB（ISBN 確定）作品={d['作品']} 第{d['順']}巻"
                      f" 「{_t(d['題名'], 34)}」")
                print(f"      著:{d['著者'] or '-'} 絵:{d['絵師'] or '-'}"
                      f" 紙{d['紙の発売日'] or '-'} 電子{d['電子の発売日'] or '-'}"
                      f"  作品「{_t(d['作品題名'], 26)}」")
            else:
                print(f"   RDB: ISBN {isbn} を知らない")

        if a.deep:
            got = S.ask(word)
            rec["問い"].append({"源": "rdb/bw", "語": word, "答え": got})
            for src in S.NAMES:
                for ans in (got.get(src) or []):
                    print(f"   [{src}] #{ans['id']}「{_t(ans['題名'], 40)}」")
        _survey_write(fp, rec)
        print()

    print(f"（調査記録を {L.survey_dir()} に残した）")
    msg = S.report()
    if msg:
        print(msg)
    return 0


def cmd_ask(a) -> int:
    if not _need_paths():
        return 1
    L.ensure_dirs()
    got = S.ask(a.word, refresh=a.refresh)
    print(f"# 「{a.word}」に問うた\n")
    n = 0
    for src in S.NAMES:
        for ans in (got.get(src) or []):
            n += 1
            print(f"[{src}] #{ans['id']}「{ans['題名']}」"
                  f" 著者={ans.get('著者') or '-'} ﾚｰﾍﾞﾙ={ans.get('レーベル') or '-'}")
            for v in (ans.get("巻") or [])[:10]:
                print(f"      {v.get('順', '')} 「{_t(v.get('題名', ''), 34)}」"
                      f" {v.get('発売日', '')}"
                      f"{'' if v.get('型') in (None, 'main') else '(' + v['型'] + ')'}")
    if not n:
        print("どの源も答えなかった")
    return 0


# ---------------------------------------------------------------- 記録

def cmd_record(a) -> int:
    if not _need_paths():
        return 1
    L.ensure_dirs()
    if a.kind not in L.KINDS:
        print(f"★ --kind は {' / '.join(L.KINDS)} のどれか")
        return 1

    if not a.retire_into and not (a.fp and a.title):
        print("★ 巻を書くには --fp と --title が要る")
        return 1

    notes = []
    vols = L.load_volumes()
    vid = a.id or L.next_volume_id()
    if a.id and a.id not in vols:
        print(f"★ {a.id} は台帳に無い")
        return 1

    # ★ 同じ巻が二つの巻ID を持ってしまったときの畳み方。
    #   台帳は追記のみなので**行は消さない**。実体を一つも持たない行を
    #   足すと、この巻ID は棚にも隔離にも現れなくなる（place は採用実体の
    #   無い巻を飛ばす）。実体は先に残す側へ付け替えておくこと。
    if a.retire_into:
        if not a.id:
            print("★ --retire-into は --id と一緒に使う")
            return 1
        if a.retire_into not in vols:
            print(f"★ 統合先 {a.retire_into} が台帳に無い")
            return 1
        if a.retire_into == a.id:
            print("★ 自分自身へは統合できない")
            return 1
        keep = vols[a.retire_into]
        left = ({f.指紋 for f in vols[a.id].ファイル}
                - {f.指紋 for f in keep.ファイル})
        # ★ --leave は「同じ巻を既に持っているので、こちらは**採らない**」。
        #   実体は今在る場所（置き場）に置いたままにする。棚にも隔離にも動かさない。
        #   併せて pend に出しておかないと、次の周でまた材料に上がってくる
        if left and a.leave:
            left = set()
        if left:
            print(f"★ {a.id} の実体 {len(left)} 個がまだ {a.retire_into} に"
                  f"付いていない。先に record --id {a.retire_into} で付け替える")
            return 1
        d = L.decision(a.by, a.why)
        d["統合先"] = a.retire_into
        old = vols[a.id]
        L.append_volumes([L.Vol(a.id, old.題名, old.レーベル, old.著者, old.絵師,
                                old.発売日, old.ISBN, old.種類, old.作品,
                                old.巻号, [], d)])
        print(f"{a.id} を {a.retire_into} に統合した"
              + ("（実体は置き場に置いたまま）" if a.leave
                 else f"（実体は {a.retire_into} 側）"))
        return 0

    # ★ 改めるときは既に付いている実体を引き継ぐ。作り直すと前の実体が
    #   台帳の今の姿から消え、置かれも隔離もされない迷子になる
    # ★ 改めるときは既に付いている実体を引き継ぐ。ただし **間違って一つの巻に
    #   寄せてしまった実体を切り離す**道が要る（別の本を「同じ巻の二つ目の
    #   実体」と読み違えたとき）。--only は今指した実体だけを残す。
    files = list(vols[a.id].ファイル) if (a.id and not a.only) else []
    if a.path:
        p = Path(a.path)
        if p.exists():
            st = p.stat()
            new = L.FileRef(a.fp, str(p), st.st_size,
                            datetime.fromtimestamp(st.st_mtime)
                            .isoformat(timespec="seconds"), True)
            # ★ 同じ指紋のものと、**同じ path のもの**を落とす。
            #   一つの path は一つの実体なので、そこを指す古い行は今の行に
            #   置き換わる（指紋を書き間違えて入れ直すときに要る）
            here = _norm_path(str(p))
            files = [f for f in files
                     if f.指紋 != a.fp and _norm_path(f.path) != here]
            if files:
                notes.append(f"★ 同じ巻に実体が {len(files) + 1} 個。"
                             f"採用は今指した方。残りは隔離へ移る")
            files = [L.FileRef(f.指紋, f.path, f.サイズ, f.更新, False)
                     for f in files] + [new]
        else:
            notes.append(f"★ {p} が見つからない。ファイル無しで記録した")

    d = L.decision(a.by, a.why)
    # ★ 承知は**引き継ぐ**。`--id` は行を丸ごと書き直すので、後から作品を
    #   足しただけで承知が落ち、下げたはずの指摘が戻ってくる（実際に戻った）。
    #   承知は「源の方が誤っている」という源についての見立てなので、
    #   その巻を書き直しても有効
    if a.id and vols[a.id].判断.get("承知"):
        d["承知"] = True
    if a.noted:
        # ★ 源が誤っていると見た上での判断。毎周同じ指摘が出ると、
        #   本当の指摘がその中に埋もれる（記録/1-壊れ方.md 8-4）
        d["承知"] = True
    # ★ 棚外は**引き継ぐ**。承知と同じ理由 — `--id` は行を丸ごと書き直すので、
    #   後から一欄を直しただけで棚外が落ち、外したはずの本が棚へ戻る
    if a.id and vols[a.id].判断.get("棚外"):
        d["棚外"] = vols[a.id].判断["棚外"]
    if a.off_shelf:
        d["棚外"] = a.off_shelf
    v = L.Vol(vid, a.title, a.label or "", a.author or "", a.artist or "",
              a.date or "", re.sub(r"\D", "", a.isbn or ""), a.kind,
              a.work or "", a.num, files, d)
    L.append_volumes([v])

    if a.isbn:
        same = [x for x in vols.values()
                if x.ISBN and x.ISBN == v.ISBN and x.巻ID != vid]
        if same:
            notes.append(f"★ 同じ ISBN が {'、'.join(x.巻ID for x in same)} にもある")

    print(f"{vid}  {a.kind}  「{_t(a.title, 44)}」")
    print(f"   {'/'.join(v.tags()) or '（タグ無し）'}")
    for n in notes:
        print("   " + n)
    return 0


def cmd_work(a) -> int:
    if not _need_paths():
        return 1
    L.ensure_dirs()
    works = L.load_works()
    w = works.get(a.id) or L.Work(a.id)
    if a.name is not None:
        w.表示名 = a.name
    if a.done is not None:
        w.完結 = a.done
    if a.last:
        w.最終巻 = a.last
    w.判断 = L.decision(a.by, a.why)
    L.append_works([w])
    print(f"{w.作品}  状態={L.state_of(w)}  完結={w.完結}  最終巻={w.最終巻 or '-'}"
          f"  「{w.表示名}」")
    return 0


def _load_pend() -> dict:
    p = L.pending_path()
    if not p.exists():
        return {}
    out = {}
    for line in p.read_text(encoding="utf-8").splitlines():
        if line.strip():
            d = json.loads(line)
            out[d["指紋"]] = d
    return out


def cmd_pend(a) -> int:
    if not _need_paths():
        return 1
    L.ensure_dirs()
    with L.pending_path().open("a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({"指紋": a.fp, "path": a.path or "",
                            "why": a.why, "時": L.now()},
                           ensure_ascii=False) + "\n")
    print(f"未決に出した: {a.fp}  {a.why}")
    return 0


# ---------------------------------------------------------------- 検め

def _oku_date(fp: str) -> str:
    try:
        d = json.loads((L.survey_dir() / f"{fp}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    return ((d.get("自身", {}).get("奥付") or {}).get("紙の日付") or "").strip()


def _months_apart(a: str, b: str):
    if not (a and b and len(a) == len(b) == 6 and a.isdigit() and b.isdigit()):
        return None
    return abs((int(a[:2]) - int(b[:2])) * 12 + (int(a[2:4]) - int(b[2:4])))


def cmd_audit(a) -> int:
    if not _need_paths():
        return 1
    # ★ 畳んだ巻はどの検めにも参加させない。行は残っているが、その巻ID は
    #   もう棚を持たない。混ぜると「同じ ISBN が二つの巻に」が畳んだ相手を
    #   指し続け、直しようの無い指摘が毎周出る
    all_vols = L.load_volumes()
    merged = [v for v in all_vols.values() if v.判断.get("統合先")]
    vols = {k: v for k, v in all_vols.items() if not v.判断.get("統合先")}
    works = L.load_works()
    found = 0

    print("## 同じ名前になる二冊（平らな棚での唯一の構造的破綻）")
    names = {}
    for v in vols.values():
        cur = v.current()
        if cur is None:
            continue
        n = P.file_name(v, Path(cur.path).suffix).lower()
        names.setdefault(n, []).append(v.巻ID)
    dup = {k: ids for k, ids in names.items() if len(ids) > 1}
    for k, ids in list(dup.items())[:20]:
        print(f"   {'、'.join(ids)}  →  {k}")
    print("   無し" if not dup else "")
    found += len(dup)

    print("## タグが欠けているもの")
    miss = {"レーベル": [], "著者": [], "絵師": [], "発売日": []}
    for v in vols.values():
        # ★ 承知は「見た上でこうしている」。絵の無い本（一般小説）や、
        #   どちらの源も持っていない本を毎周並べても、本当の欠けが埋もれる
        if v.種類 == "其他" or v.判断.get("承知"):
            continue
        for k in miss:
            if not getattr(v, k):
                miss[k].append(v.巻ID)
    for k, ids in miss.items():
        if ids:
            print(f"   {k:<6} {len(ids):>4} 件   {'、'.join(ids[:6])}"
                  f"{' …' if len(ids) > 6 else ''}")
            found += len(ids)
    if not any(miss.values()):
        print("   無し")

    print("## レーベルが文庫名でなく判型のもの")
    # 杜のレーベル欄には判型が入っている行がある（実測-26、索引 981 件）。
    # 埋まってはいるので上の「欠けているもの」には出ない。だが `[B6判]` は
    # 棚で何もまとめないので、奥付か RanobeDB から採り直す
    fmt = [v.巻ID for v in vols.values()
           if v.種類 != "其他" and M.is_format(v.レーベル)]
    print(f"   {len(fmt)} 件   {'、'.join(fmt[:6])}{' …' if len(fmt) > 6 else ''}"
          if fmt else "   無し")
    found += len(fmt)

    print("## 奥付が印刷した発売日と台帳の発売日が離れているもの")
    # ★★ **奥付は本の中に印刷されている。ファイル名より強い。**
    #   ここが大きく離れているときは、たいていファイル名が別の本を指していて、
    #   台帳がそれを信じてしまっている（壊れ方 1-9）。実際これで八件見つかった。
    far = []
    for v in vols.values():
        cur = v.current()
        if cur is None:
            continue
        got = _oku_date(cur.指紋)
        if not got or not v.発売日:
            continue
        g = _months_apart(got, v.発売日)
        if g is not None and g >= 2:
            far.append((g, v, got))
    # ★ 鍵を指す。指さないと、月数が同じときに Vol どうしを比べて落ちる
    far.sort(key=lambda x: -x[0])
    for g, v, got in far[:20 if a.verbose else 6]:
        print(f"   {v.巻ID}  奥付 {got} / 台帳 {v.発売日}（{g} ヶ月）"
              f"  「{_t(v.題名, 40)}」")
    if not far:
        print("   無し")
    else:
        print("   ★ 奥付は本の中に印刷されている。**ファイル名より強い。**"
              "本文の柱も見て確かめること")
    found += len(far)

    print("## 同じ ISBN が二つの巻に")
    by_isbn = {}
    for v in vols.values():
        if v.ISBN:
            by_isbn.setdefault(v.ISBN, []).append(v.巻ID)
    d2 = {k: x for k, x in by_isbn.items() if len(x) > 1}
    for k, ids in list(d2.items())[:10]:
        print(f"   {k}  →  {'、'.join(ids)}")
    print("   無し" if not d2 else "")
    found += len(d2)

    # ★ 置いたあとは src == want になるので plan は何も言わない。
    #   手で消された・別の場所へ動かされた本は、ここでしか見つからない
    print("## 同じ作品の同じ巻号が二つ")
    # ★ 一つの作品に同じ巻号は二つ無い。ここが重なるのは、たいてい
    #   別の巻を取り違えて入れている（壊れ方 1-9）。ISBN が無い本でも効く
    byn = {}
    for v in vols.values():
        if v.種類 != "本篇" or not v.作品 or v.巻号 is None:
            continue
        byn.setdefault((v.作品, v.巻号), []).append(v.巻ID)
    d2 = {k: x for k, x in byn.items() if len(x) > 1}
    for (w, num), ids in list(d2.items())[:20 if a.verbose else 8]:
        print(f"   {w} 第{num:g}巻  →  {'、'.join(sorted(ids))}")
    print("   無し" if not d2 else "")
    found += len(d2)

    print("## 台帳にあるのに実体が無い")
    gone = []
    for v in vols.values():
        for f in v.ファイル:
            if not Path(f.path).exists():
                gone.append((v.巻ID, f.path, f.採用))
    for vid, path, adopted in (gone[:20] if a.verbose else gone[:5]):
        print(f"   {vid}{'（採用）' if adopted else '（控え）'}  {_t(path, 62)}")
    if not gone:
        print("   無し")
    else:
        if len(gone) > (20 if a.verbose else 5):
            print(f"   … 他 {len(gone) - (20 if a.verbose else 5)} 件")
        print("   ★ 台帳は持っていると言っているが、そこに無い。"
              "動かしたなら record --id で path を直すこと")
    found += len(gone)

    print("## 他の巻へ統合した巻（実体を持たない）")
    # 追記のみの台帳なので行は消えない。畳んだ巻がどれかは、ここでしか見えない
    for v in (merged[:20] if a.verbose else merged[:5]):
        print(f"   {v.巻ID} → {v.判断['統合先']}  「{_t(v.題名, 44)}」")
    if not merged:
        print("   無し")
    elif len(merged) > (20 if a.verbose else 5):
        print(f"   … 他 {len(merged) - (20 if a.verbose else 5)} 件")

    print("## 実体を一つも持たない巻（統合でもないのに）")
    empty = [v.巻ID for v in vols.values()
             if not v.ファイル and not v.判断.get("統合先")]
    print(f"   {len(empty)} 件   {'、'.join(empty[:6])}" if empty else "   無し")
    found += len(empty)

    print("## 同じ実体が二つの巻に付いている")
    fps = {}
    for v in vols.values():
        for f in v.ファイル:
            fps.setdefault(f.指紋, []).append(v.巻ID)
    d3 = {k: x for k, x in fps.items() if len(set(x)) > 1}
    for k, ids in list(d3.items())[:10]:
        print(f"   {k}  →  {'、'.join(sorted(set(ids)))}")
    print("   無し" if not d3 else "")
    found += len(d3)

    print("## 特典の頭が、その本の OPF の『』と食い違う")
    # ★ 特典の題名は対応巻から**継ぐ**ので、継ぐ先を取り違えても形は整う。
    #   その本自身の OPF が名乗る『対応巻』と突き合わせれば、外から確かめられる。
    #   （実際これで、対応巻の ISBN を引かずに書いた八件が見つかった）
    opf_of = {}
    for sp in L.survey_dir().glob("*.json"):
        try:
            sd = json.loads(sp.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        opf_of[sd.get("指紋", "")] = (sd.get("自身", {}).get("opf")
                                      or {}).get("題名") or ""
    odd, blind = [], 0
    for v in vols.values():
        cur = v.current()
        if v.種類 != "特典" or cur is None:
            continue
        if v.判断.get("承知"):
            continue
        mm = re.search(r"[『「]([^』」]+)[』」]", opf_of.get(cur.指紋, ""))
        if not mm:
            blind += 1
            continue
        want, got = M.norm(mm.group(1)), M.norm(v.題名.split(" 特典 ")[0])
        if not (want in got or got in want):
            odd.append((v.巻ID, mm.group(1), v.題名.split(" 特典 ")[0]))
    for vid, want, got in (odd[:20] if a.verbose else odd[:5]):
        print(f"   {vid}  OPF『{_t(want, 40)}』 / 台帳「{_t(got, 40)}」")
    if not odd:
        print(f"   無し{f'（OPF に『』が無く確かめられないもの {blind} 件）' if blind else ''}")
    found += len(odd)

    print("## 棚に置かないと決めた巻（実体は置き場に在る）")
    off = [v for v in vols.values() if v.判断.get("棚外")]
    for v in (off[:20] if a.verbose else off[:5]):
        print(f"   {v.巻ID}  「{_t(v.題名, 44)}」  {_t(v.判断['棚外'], 40)}")
    if not off:
        print("   無し")
    else:
        if len(off) > (20 if a.verbose else 5):
            print(f"   … 他 {len(off) - (20 if a.verbose else 5)} 件")
        print("   ★ **持っているが棚に並べていない。** 台帳の行は残してあるので、"
              "棚に戻すなら record --id --why で棚外を書き直す")
    found += len(off)

    print("## 小説でないとして退けたもの（其他）")
    others = [v for v in vols.values() if v.種類 == "其他"]
    for v in (others[:20] if a.verbose else others[:5]):
        print(f"   {v.巻ID}  「{_t(v.題名, 52)}」")
    if not others:
        print("   無し")
    else:
        if len(others) > (20 if a.verbose else 5):
            print(f"   … 他 {len(others) - (20 if a.verbose else 5)} 件")
        print("   ★ 其他 は棚から外れる。**一冊でも間違えると黙って蔵書から消える**")
    found += len(others)

    print("## 作品を持たない巻（状態が 4. 未分類 に落ちる）")
    # 承知は「どちらの源も持っていないと見た上でこうしている」
    nw = [v for v in vols.values()
          if not v.作品 and v.種類 != "其他" and not v.判断.get("承知")]
    print(f"   {len(nw)} 件" if nw else "   無し")
    found += len(nw)

    # ★ 中身が同じ写しは指紋で弾かれるので materials に二度と出てこない。
    #   放っておくと置き場が空にならず、しかも理由がどこにも出ない
    print("## 置き場に残っている、既に台帳にある中身の写し")
    known = {f.指紋: v.巻ID for v in vols.values() for f in v.ファイル}
    mine = {_norm_path(f.path) for v in vols.values() for f in v.ファイル}
    inbox = paths.get("inbox")
    stray = []
    if inbox and inbox.exists():
        for p in inbox.rglob("*"):
            if not p.is_file() or p.suffix.lower() not in BOOK_EXT:
                continue
            if _norm_path(str(p)) in mine:
                continue
            vid = known.get(L.fingerprint(p))
            if vid:
                stray.append((vid, p))
    for vid, p in (stray[:20] if a.verbose else stray[:5]):
        print(f"   {vid} と同じ中身  {_t(p.name, 52)}")
    if not stray:
        print("   無し")
    else:
        if len(stray) > (20 if a.verbose else 5):
            print(f"   … 他 {len(stray) - (20 if a.verbose else 5)} 件")
        print("   ★ このままでは置き場が空にならない。要らなければ隔離へ移すこと")
    found += len(stray)

    print(f"\n巻 {len(vols)} / 作品 {len(works)} / 気になるもの {found} 件")
    return 0


# ---------------------------------------------------------------- 配置

def cmd_plan(a) -> int:
    if not _need_paths():
        return 1
    ops, stuck = P.build()
    p = P.save_plan(ops, stuck)
    print(f"計画 {len(ops)} 件 -> {p}")
    kinds = {}
    for o in ops:
        kinds[o.種類] = kinds.get(o.種類, 0) + 1
    print("   " + "  ".join(f"{k} {n}" for k, n in sorted(kinds.items())))
    for o in ops[:a.show]:
        dst = Path(o.先)
        print(f"   {o.種類}  {_t(Path(o.元).name, 30)}"
              f"  →  {_t(dst.parent.name + '/' + dst.name, 66)}")
    if stuck:
        print(f"★ 置けなかった {len(stuck)} 件:")
        for x in stuck[:10]:
            print(f"     {x}")
    print("\n中を見てから apply。この時点では何も動いていません")
    return 0


def _latest(d: Path):
    xs = sorted(d.glob("*.jsonl")) if d.exists() else []
    return xs[-1] if xs else None


def cmd_apply(a) -> int:
    if not _need_paths():
        return 1
    p = Path(a.plan) if a.plan else _latest(L.plans_dir())
    if p is None:
        print("計画がありません")
        return 1
    if not p.exists():
        print(f"★ その計画がありません: {p}")
        return 1
    code, up, msgs = P.apply(p, force=a.force)
    if code:
        print(f"門で止まりました（{len(msgs)} 件）")
        for m in msgs[:20]:
            print(f"   ★ {m}")
        return 1
    for m in msgs:
        print(m)
    print(f"取消は {up}" if up else "（動いていないので取消はありません）")
    return 0


# record / pend に渡す既定値。**呼び出し側で書き漏らしても既定が効く**ように、
# ここに一覧を置く（argparse の既定と同じ形にしておく）
_ARG_DEFAULT = dict(fp=None, path=None, title=None, label=None, author=None,
                    artist=None, date=None, isbn=None, kind="本篇", work=None,
                    num=None, id=None, leave=False, only=False, noted=False,
                    retire_into=None, off_shelf=None, by="agent", why="")


def _run(fn, **kw) -> int:
    """既にある cmd_* を、引数を組み立てて呼ぶ。

    ★ 台帳に書く道は **cmd_record 一つだけ**にしておく。ここで独自に
      L.append_volumes を呼ぶと、実体の引き継ぎ・承知の伝搬・ID の採り方が
      二か所に分かれ、片方だけ直る（記録/1-壊れ方.md 五章）。
    """
    return fn(argparse.Namespace(**{**_ARG_DEFAULT, **kw}))


def _unsettled() -> list:
    """まだ台帳にも未決にも入っていない調べを、置き場の実体の在るものだけ返す。"""
    done = L.settled_fingerprints()
    pend = _load_pend()
    out = []
    for p in sorted(L.survey_dir().glob("*.json")):
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"★ {p.name} が読めない（飛ばした）")
            continue
        if d["指紋"] in done or d["指紋"] in pend:
            continue
        if not Path(d["実体"]["path"]).exists():
            continue
        out.append(d)
    return out


def _mori_answer(d: dict):
    """調べの中の、杜が**一行に絞れた**答え。無ければ None。

    ISBN の行を題名の行より先に見る。ISBN は一冊を名指しするので、
    題名より強い（この順を逆にしていて 28 件が素通りした）。
    """
    for want in ("isbn", "index-exact"):
        for q in d["問い"]:
            if q["源"] != "mori" or not q.get("答え"):
                continue
            if q.get("経路", "").startswith(want) and len(q["答え"]) == 1:
                return q["答え"][0]
    return None


def cmd_dup(a) -> int:
    """置き場の実体が**既に棚に在る巻**かどうかを突き合わせる。

    同じ巻なら規則 7-4 で採否を決める。棚を残すなら実体は**置き場に
    置いたまま**（未決に出すので次の周では材料に上がらない）。
    """
    if not _need_paths():
        return 1
    shelf = paths.shelf()
    vols = [v for v in L.load_volumes().values() if not v.判断.get("統合先")]
    idx = SM.index(vols)
    rows = []
    for d in _unsettled():
        m = _mori_answer(d)
        ot = (d["自身"].get("opf") or {}).get("題名") or ""
        isbn = (m or {}).get("isbn") or (d["自身"].get("奥付") or {}).get("ISBN") or ""
        title = M.title_of(m) if m else ot
        old, how = SM.volume_of(idx, isbn=isbn, title=title)
        if old is None and ot and ot != title:
            old, how = SM.volume_of(idx, title=ot)
        if old is None:
            continue
        cur = old.current()
        if cur is None or shelf not in Path(cur.path).parents:
            continue
        src = Path(d["実体"]["path"])
        size = src.stat().st_size
        # ★ 採否はここで**一度だけ**決めて持ち回る。あとから `r in take` と
        #   引き直していたが、それは比べ方が二か所に分かれるということで、
        #   しかも辞書を含む組の等値比較に頼っていた（五章）
        rows.append((d, old, how, src, size, cur,
                     SM.better(src, size, cur.path, cur.サイズ)))

    n_swap = sum(1 for r in rows if r[6])
    print(f"# 既に棚に在る巻 {len(rows)} 件"
          f"（棚を残す {len(rows) - n_swap} / 置き場の方が良い {n_swap}）\n")
    for d, old, how, src, size, cur, swap in rows[:a.show]:
        mark = "入れ替え" if swap else "棚を残す"
        print(f"  {mark}  {old.巻ID}（{how}）  棚 {cur.サイズ:>11,} / こちら {size:>11,}")
        print(f"          「{_t(old.題名, 44)}」")
    if len(rows) > a.show:
        print(f"  … 他 {len(rows) - a.show} 件")
    if not a.apply:
        print("\n見ただけ。決めるなら --apply")
        return 0

    n_keep = n_take = 0
    for d, old, how, src, size, cur, swap in rows:
        if swap:
            # ★ 自分で台帳に書かない。**record を呼ぶ**。実体の引き継ぎも
            #   承知の伝搬も ID の採り方も、あちらに一つだけ在るべき
            _run(cmd_record, id=old.巻ID, fp=d["指紋"], path=str(src),
                 title=old.題名, label=old.レーベル, author=old.著者,
                 artist=old.絵師, date=old.発売日, isbn=old.ISBN,
                 kind=old.種類, work=old.作品, num=old.巻号,
                 why=f"★ 置き場に**同じ巻のより良い実体**があった"
                     f"（こちら {size:,} / 棚 {cur.サイズ:,} バイト）。"
                     f"同じ巻だと分かったのは {how}。規則 7-4 で採用を入れ替える")
            n_take += 1
        else:
            _run(cmd_pend, fp=d["指紋"], path=str(src),
                 why=f"同じ巻（{old.巻ID}「{_t(old.題名, 30)}」）を既に持っており、"
                     f"棚の方が良い（棚 {cur.サイズ:,} / こちら {size:,} バイト）。"
                     f"同じ巻だと分かったのは {how}。規則 7-4 で棚を残す。"
                     f"実体は置き場に置いたまま")
            n_keep += 1
    print(f"\n棚を残した {n_keep} 件（実体は置き場に残る） / 入れ替えた {n_take} 件")
    return 0


# 特典の名前に出る語。**実測で集めた閉じた一覧**。この手前が親の題名
_TOK_TAIL = re.compile(
    r"\s*(?:購入特典|特典\s*SS|特典|BOOK\s*[☆★]?\s*WALKER|アニメイト|とらのあな|"
    r"ゲーマーズ|メロンブックス|書き下ろし|ショートストーリー|SS\b|ペーパー|"
    r"リーフレット|小冊子|限定).*$", re.I)
_TOK_QUOTED = re.compile(r"『([^』]{4,80})』")
# 特典らしいと見る語。長さも見る（本篇と同じだけ字があるものは特典ではない）
_TOK_HINT = re.compile(r"特典|SS|ショートストーリー|ペーパー|書き下ろし|限定", re.I)
TOKUTEN_MAX_CHARS = 20000


def _tokuten_head(s: str) -> tuple:
    """特典の名前から `(親の題名, 表紙の巻号)` を切り出す。

    『』で括られていればその中。無ければ特典を表す語の**手前**まで。
    そこから先の「頭と巻号に割る」は same に任せる — 台帳の側を割るのと
    **同じ割り方**でなければ突き合わない（記録/1-壊れ方.md 五章）。
    """
    s = unicodedata.normalize("NFKC", s or "").strip()
    q = _TOK_QUOTED.search(s)
    s = q.group(1).strip() if q else _TOK_TAIL.sub("", s).strip()
    s = re.sub(r"^(?:【[^】]*】|購入特典)\s*", "", s).strip()
    return SM.head_number(s)


def cmd_oya(a) -> int:
    """特典の**親の巻**を台帳の中から探す。

    ★ 杜に訊かない。杜は特典を載せないので、訊いても黙る。
      特典は「その巻を買った人が貰うもの」なので、**親はたいてい自分が
      既に持っている**。台帳を引くのが正しい。
    """
    if not _need_paths():
        return 1
    vols = [v for v in L.load_volumes().values() if not v.判断.get("統合先")]
    idx = SM.index(vols)
    ok, ng = [], []
    for d in _unsettled():
        nm = Path(d["実体"]["path"]).name
        ot = (d["自身"].get("opf") or {}).get("題名") or ""
        src = ot if _TOK_QUOTED.search(ot) else (ot or nm)
        if not _TOK_HINT.search(src + nm):
            continue
        if d["自身"]["本文"]["字数"] > TOKUTEN_MAX_CHARS:
            continue          # 本篇の長さがある。特典ではない
        head, num = _tokuten_head(src)
        v, why = SM.parent_of(idx, head, num)
        (ok if v else ng).append((d, v, head, num, why))

    print(f"# 特典らしきもの {len(ok) + len(ng)} 件"
          f"（親が決まった {len(ok)} / 決まらない {len(ng)}）\n")
    for d, v, head, num, why in ok[:a.show]:
        print(f"  親 {v.巻ID}「{_t(v.題名, 40)}」（{why}）")
        print(f"      ← {_t(Path(d['実体']['path']).name, 66)}")
    for d, v, head, num, why in ng[:a.show]:
        print(f"  ? {why}")
        print(f"      切り出し「{_t(head, 40)}」{f' 第{num:g}巻' if num else ''}"
              f"  ← {_t(Path(d['実体']['path']).name, 50)}")
    if not a.apply:
        print("\n見ただけ。書くなら --apply")
        return 0

    n = 0
    for d, v, head, num, why in ok:
        t = (d["自身"].get("opf") or {}).get("題名") or Path(d["実体"]["path"]).name
        kind = ("書き下ろしSSペーパー" if "ペーパー" in t
                else "ガイドブック" if "ガイドブック" in t
                else "書き下ろしショートストーリー")
        _run(cmd_record, fp=d["指紋"], path=d["実体"]["path"],
             title=f"{v.題名.split('　')[0]} 特典 {kind}",
             label=v.レーベル, author=v.著者, artist=v.絵師,
             date=v.発売日, kind="特典", work=v.作品,
             why=f"★ 特典。親巻は**台帳の中から**決めた — 杜は特典を載せない。"
                 f"切り出した親の題名「{head[:30]}」"
                 f"{f'第{num:g}巻' if num else ''}が {v.巻ID}"
                 f"「{v.題名[:30]}」と{why}で当たる。前方一致は使わない"
                 f"（同じ作品の別の巻を掴む。壊れ方 1-9）")
        n += 1
    print(f"\n{n} 件を台帳に書いた")
    return 0


def cmd_gaps(a) -> int:
    import gaps
    return gaps.main(["--apply"] if a.apply else [])


def cmd_undo(a) -> int:
    if not _need_paths():
        return 1
    p = Path(a.undo) if a.undo else _latest(L.undos_dir())
    if p is None:
        print("取消がありません")
        return 1
    if not p.exists():
        print(f"★ その取消がありません: {p}")
        return 1
    n, rewritten, swept, blocked = P.undo(p)
    for b in blocked:
        print(f"   ★ {b}")
    if not n:
        print(f"★ 戻せたものが一つもありません（{p}）")
        return 1
    print(f"{n} 件を戻しました（{p}）。台帳の path を {rewritten} 行追記、"
          f"空フォルダを {swept} 畳んだ")
    return 1 if blocked else 0


def cmd_status(a) -> int:
    print("## 置き場")
    print(paths.describe())
    if paths.missing():
        print("\n" + paths.prompt_text())
        return 1
    vols, works, pend = L.load_volumes(), L.load_works(), _load_pend()
    print("\n## 台帳")
    print(f"  巻      {len(vols):>6}")
    print(f"  作品    {len(works):>6}")
    print(f"  未決    {len(pend):>6}")
    print(f"  杜の索引 {len(M.load_index()):>6}")
    inbox = paths.get("inbox")
    if inbox and inbox.exists():
        n = sum(1 for p in inbox.rglob("*")
                if p.is_file() and p.suffix.lower() in BOOK_EXT)
        print(f"  置き場に {n:>6} 件")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="cli", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("config", help="置き場を決める・確かめる（.env に書く）")
    p.add_argument("--default", action="store_true")
    p.add_argument("--shelf", help="整理済みの蔵書を置く場所")
    p.add_argument("--inbox", help="まだ整理していない実体がある場所")
    p.add_argument("--var", help="台帳・索引・控えを置く場所（唯一の資産）")
    p.set_defaults(fn=cmd_config)

    p = sub.add_parser("materials", help="まだ台帳に無い実体の材料を出す")
    p.add_argument("--count", type=int, default=20)
    p.add_argument("--deep", action="store_true", help="RDB/BW にも問う")
    p.add_argument("--no-isbn", action="store_true", help="ISBN 確定を省く")
    p.add_argument("--include-pending", action="store_true")
    p.set_defaults(fn=cmd_materials)

    p = sub.add_parser("ask", help="RanobeDB / BookWalker に問う")
    p.add_argument("word")
    p.add_argument("--refresh", action="store_true")
    p.set_defaults(fn=cmd_ask)

    p = sub.add_parser("record", help="決まった一巻を台帳に書く")
    p.add_argument("--fp")
    p.add_argument("--path")
    p.add_argument("--title")
    p.add_argument("--label")
    p.add_argument("--author")
    p.add_argument("--artist")
    p.add_argument("--date")
    p.add_argument("--isbn")
    p.add_argument("--kind", default="本篇")
    p.add_argument("--work", help="作品 id（rdb:6547 など）")
    p.add_argument("--num", type=float)
    p.add_argument("--id", help="既存の巻を改めるとき")
    p.add_argument("--leave", action="store_true",
                   help="--retire-into と一緒に。実体を移さず、今在る場所に置いたままにする")
    p.add_argument("--only", action="store_true",
                   help="引き継がず、今指した実体だけにする（寄せ間違いを切る）")
    p.add_argument("--noted", action="store_true",
                   help="源の方が誤っていると見た上で決めた（検めの指摘を下げる）")
    p.add_argument("--off-shelf", metavar="なぜ",
                   help="棚に置かない（実体は今在る場所のまま。台帳の行は残る）")
    p.add_argument("--retire-into", metavar="巻ID",
                   help="この巻を別の巻へ統合する（--id と一緒に。行は消さない）")
    p.add_argument("--by", default="agent", choices=("agent", "user"))
    p.add_argument("--why", required=True)
    p.set_defaults(fn=cmd_record)
    # ★ --fp と --title は「巻を書く」ときだけ要る。統合には要らないので
    #   argparse ではなく cmd_record の中で見る

    p = sub.add_parser("work", help="作品の完結・最終巻")
    p.add_argument("id")
    p.add_argument("--name")
    p.add_argument("--done", type=lambda x: x.lower() in ("1", "true", "yes"))
    p.add_argument("--last", help="既に出た最新巻の yyyymmdd")
    p.add_argument("--by", default="agent", choices=("agent", "user"))
    p.add_argument("--why", required=True)
    p.set_defaults(fn=cmd_work)

    p = sub.add_parser("pend", help="決められないものを未決に出す")
    p.add_argument("--fp", required=True)
    p.add_argument("--path")
    p.add_argument("--why", required=True)
    p.set_defaults(fn=cmd_pend)

    p = sub.add_parser("audit", help="構造的な異常を探す")
    p.add_argument("--verbose", action="store_true")
    p.set_defaults(fn=cmd_audit)

    p = sub.add_parser("plan", help="何をどこへ動かすか（動かない）")
    p.add_argument("--show", type=int, default=10)
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("apply", help="三つの門を通してから動かす")
    p.add_argument("plan", nargs="?")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_apply)

    p = sub.add_parser("undo", help="取り消す")
    p.add_argument("undo", nargs="?")
    p.set_defaults(fn=cmd_undo)

    p = sub.add_parser("dup", help="置き場の実体が既に棚に在る巻か突き合わせる")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--show", type=int, default=12)
    p.set_defaults(fn=cmd_dup)

    p = sub.add_parser("oya", help="特典の親の巻を台帳の中から探す")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--show", type=int, default=12)
    p.set_defaults(fn=cmd_oya)

    p = sub.add_parser("gaps", help="欠巻の標を立て直す（台帳から毎回引き直す）")
    p.add_argument("--apply", action="store_true")
    p.set_defaults(fn=cmd_gaps)

    p = sub.add_parser("status", help="今どうなっているか")
    p.set_defaults(fn=cmd_status)

    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except SystemExit:
        raise
    except (ValueError, OSError) as e:
        # 使い方の間違いに堆栈を返さない。何が悪いかだけ言う
        print(f"★ {type(e).__name__}: {e}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
