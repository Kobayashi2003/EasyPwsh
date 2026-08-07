"""ラノベの杜 — 月刊リストを索引にする。

索引は var/index/mori.jsonl（追記ではなく月ごとに差し替え）。
引くのは全部ローカル。網に触るのは crawl と update だけ。
"""

from __future__ import annotations

import html
import json
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import ledger as L
import paths

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
BASE = "https://ranobe-mori.net"
FEED = BASE + "/rss.xml"
SEARCH = "https://ranobe-mori.xsrv.jp/mt6/mt-search.cgi"
FIRST = (2005, 1)
INTERVAL = 1.2

_ENTRY = re.compile(r'<div class="entry">(.*?)(?=<div class="entry">|\Z)', re.S)
_H2 = re.compile(r'<h2[^>]*class="entry-header"[^>]*>'
                 r'(?:<a[^>]*>)?(.*?)(?:</a>)?</h2>', re.S)
_TABLE = re.compile(r"<table[^>]*>(.*?)</table>", re.S)
_TR = re.compile(r"<tr[^>]*class=\"(book-header|book-info\d?)\"[^>]*>(.*?)</tr>", re.S)
_CELL = re.compile(r"<t[dh][^>]*>(.*?)</t[dh]>", re.S)
_TAG = re.compile(r"<[^>]+>")
_ISBN = re.compile(r"(\d[\d-]{10,16}\d)")
_DELAY = re.compile(r"\(([^()]*より延期)\)")
_FEED_TITLE = re.compile(r"^(.*?)\s*-\s*(\d{4})年(\d{1,2})月刊")

FIELD = {
    "発売日": "day", "タイトル": "title", "著者": "author", "イラスト": "artist",
    "定価": "price", "ISBN": "isbn", "レーベル": "label", "出版元": "label",
    "原作者": "original",
}


def var() -> Path:
    return paths.var()


def index_dir() -> Path:
    d = var() / "index"
    d.mkdir(parents=True, exist_ok=True)
    return d


def index_path() -> Path:
    return index_dir() / "mori.jsonl"


def state_path() -> Path:
    return index_dir() / "mori-state.json"


# ★ 閉じていないタグの断片。杜の頁に `えむえむっ！５</a` のような壊れた
#   HTML がある（索引 90,995 件中 6 件）。`<[^>]+>` は `>` を要るので素通りし、
#   題名に `</a` が残って**その本だけ永久に当たらなくなる**
_TAG_FRAG = re.compile(r"<[^>]*$")


def _text(s: str) -> str:
    s = _TAG_FRAG.sub("", _TAG.sub("", s))
    return html.unescape(s).replace("　", " ").strip()


def _date(year: str, month: str, cell) -> str:
    """発売日のセルを yymmdd にする。

    ★ セルは素直な数字とは限らない（実測 86,286 件中 2,044 件）。

        「25」        その月の 25 日
        「8/29」      月末に出た本が翌月の頁に載っている。月ごと採る
        「\\u200e16」  見えない制御文字が頭に付く（U+200E 左横書き指定）
        それ以外      日は分からないものとして 00 で埋める

    以前は `\\D` を落として繋いでいたので `8/29` が `829` になり、
    `0809829` という 7 桁の日付が棚のタグに出ようとしていた。
    """
    y2, mm = year[2:], int(month)
    # 見えない字（Cf: 書字方向の指定・ゼロ幅空白・BOM）を先に落とす
    s = "".join(c for c in (cell or "")
                if unicodedata.category(c) != "Cf").strip()
    m = re.fullmatch(r"(\d{1,2})\s*[/／・]\s*(\d{1,2})", s)
    if m:                      # 月をまたぐ表記
        mm2, dd = int(m.group(1)), int(m.group(2))
        if 1 <= mm2 <= 12 and 1 <= dd <= 31:
            # 12 月の頁に 1/xx が載っていれば翌年
            yy = int(y2) + (1 if mm == 12 and mm2 == 1 else 0)
            return f"{yy % 100:02d}{mm2:02d}{dd:02d}"
        return f"{y2}{mm:02d}00"
    m = re.fullmatch(r"(\d{1,2})", s)
    if m and 1 <= int(m.group(1)) <= 31:
        return f"{y2}{mm:02d}{int(m.group(1)):02d}"
    return f"{y2}{mm:02d}00"   # 日が読めない


# NFKC は ～(FF5E) を ~ にするが 〜(301C) は変えない。ダッシュ類も揃わない
_DASH = dict.fromkeys(map(ord, "―ー−‐-–—ｰ─━‒﹘"), ord("-"))
_TILDE = dict.fromkeys(map(ord, "~〜～﹋"), ord("~"))
# 山括弧も同じ。NFKC は ＜(FF1C) を < にするが 〈(3008) は変えないので、
# `〈Infinite Dendrogram〉` と `＜Infinite Dendrogram＞` が別物になる
_ANGLE = {**dict.fromkeys(map(ord, "〈《≪«＜<‹"), ord("<")),
          **dict.fromkeys(map(ord, "〉》≫»＞>›"), ord(">"))}
# 引用符は**揃えるのではなく落とす**。山括弧と違って、片方に有って片方に
# 無いという形で食い違う（手元「妹が“義妹”ってこと…」/ 杜「妹が義妹ってこと…」）。
# 索引 90,995 件で確かめて、落としても新たに重なる組は **0**（実測-29）
# ★ 「」『』 は入れない。日本語の題名で意味を持って使われるし、
#   落として良いという実測が無い。«» は _ANGLE の側で扱う
_QUOTE = dict.fromkeys(map(ord, "“”‟„\"'‘’＇＂"), None)

# 電子版だけに付く飾り。**実測で集めた閉じた一覧**（記録/2-実測.md 実測-19）
_DECOR = re.compile(
    r"【[^【】]*(?:電子|特典|限定|書き下ろし|SS)[^【】]*】"
    r"|〈[^〈〉]*(?:電子|限定)[^〈〉]*〉"
    r"|\s*BOOK[☆★]?WALKER\s*(?:special\s*edition|限定[^ ]*)?"
    r"|【[^【】]*版】", re.I)


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s or "")
    s = s.translate(_DASH).translate(_TILDE).translate(_ANGLE).translate(_QUOTE)
    return re.sub(r"[\s　]+", "", s).casefold()


def strip_decor(s: str, labels: set | None = None) -> str:
    """電子版の飾りを落とす。**落とした結果が完全一致したときだけ意味がある。**

    外れても嘘の一致は生まれない（一致しなければ何も言わない）ので安全。
    """
    s = _DECOR.sub("", s or "").strip()
    if labels:
        m = re.search(r"[(（]([^()（）]{2,20})[)）]\s*$", s)
        if m and norm(m.group(1)) in labels:
            s = s[:m.start()].strip()
    return s


def fetch(url: str, tries: int = 4) -> str:
    for i in range(tries):
        try:
            req = urllib.request.Request(url)
            req.add_header("User-Agent", UA)
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return ""
            time.sleep(2.0 * (i + 1))
        except Exception:
            time.sleep(2.0 * (i + 1))
    return ""


def parse(body: str, ym: str) -> list:
    """月ページを行にする。列は見出しの名前で対応づける（位置で取らない）。"""
    year, month = ym.split("/")
    out = []
    for blk in _ENTRY.findall(body):
        h = _H2.search(blk)
        head_label = _text(h.group(1)) if h else ""
        head_label = re.sub(r"\s*-\s*\d{4}年\d{1,2}月刊.*$", "", head_label).strip()
        for tbl in _TABLE.findall(blk):
            cols, extra, section = [], [], ""
            for kind, raw in _TR.findall(tbl):
                cells = [_text(c) for c in _CELL.findall(raw)]
                if kind == "book-header":
                    named = [c for c in cells if FIELD.get(c)]
                    if len(named) >= 3:
                        cols = [FIELD.get(c) for c in cells]
                        extra = [(i, c) for i, c in enumerate(cells)
                                 if FIELD.get(c) is None and c]
                    elif len(cells) <= 2 and cells and cells[0]:
                        section = cells[0]
                    continue
                if not cols:
                    continue
                rec = {"label": section or head_label, "month": ym}
                for i, key in enumerate(cols):
                    if key and i < len(cells):
                        rec[key] = cells[i]
                for i, name in extra:
                    if i < len(cells) and cells[i]:
                        rec["label"] = name
                title = rec.get("title", "")
                d = _DELAY.search(title)
                if d:
                    rec["delayed"] = d.group(1)
                    title = _DELAY.sub("", title).strip()
                rec["title"] = title
                raw_isbn = rec.get("isbn", "")
                rec["digital_only"] = "電子専売" in raw_isbn
                m = _ISBN.search(raw_isbn)
                rec["isbn"] = re.sub(r"-", "", m.group(1)) if m else ""
                rec["date"] = _date(year, month, rec.get("day"))
                rec.pop("day", None)
                if rec.get("title"):
                    out.append(rec)
    return out


def _this_month() -> str:
    n = datetime.now()
    return f"{n.year}/{n.month:02d}"


def months(upto_ahead: int = 4) -> list:
    now = datetime.now()
    y, m = FIRST
    end_y, end_m = now.year, now.month + upto_ahead
    end_y, end_m = end_y + (end_m - 1) // 12, (end_m - 1) % 12 + 1
    out = []
    while (y, m) <= (end_y, end_m):
        out.append(f"{y}/{m:02d}")
        m += 1
        if m > 12:
            y, m = y + 1, 1
    return out


def load_state() -> dict:
    p = state_path()
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    return {"months": {}, "last_feed": ""}


def save_state(st: dict) -> None:
    L.write_atomic(state_path(), json.dumps(st, ensure_ascii=False, indent=1))


def load_index() -> list:
    """★ 照合用の鍵を読み込み時に一度だけ作る。

    引くたびに 86,000 行を正規化し直すと 1 冊 0.76 秒かかっていた。
    """
    p = index_path()
    if not p.exists():
        return []
    rows = [json.loads(x) for x in p.read_text(encoding="utf-8").splitlines()
            if x.strip()]
    for r in rows:
        r["_k"] = index_key(r.get("title", ""))
        r["_lk"] = norm(r.get("label", ""))
    return rows


def _key_of(r: dict) -> str:
    k = r.get("_k")
    return k if k is not None else index_key(r.get("title", ""))


def write_index(rows: list) -> None:
    L.write_atomic(index_path(), "".join(
        json.dumps({k: v for k, v in r.items() if not k.startswith("_")},
                   ensure_ascii=False) + "\n" for r in rows))


def _flush(st: dict, by_month: dict) -> None:
    write_index([r for m in sorted(by_month) for r in by_month[m]])
    save_state(st)


def crawl(targets: list, st: dict, rows_by_month: dict) -> tuple:
    """★ 十月ごとに書き出す。最後にまとめて書くと、途中で落ちたとき全部消える。

    ★ **0 件になったら前のを消さない。** 相手が HTTP 200 のまま中身の欠けた
      応答を返すことがあり（実測で 264 か月中 15 か月）、そのまま上書きすると
      その月が索引から静かに消える。「成功 264 / 失敗 0」と言いながら
      788 行が失われていた。
    """
    ok = fail = kept = 0
    for i, ym in enumerate(targets, 1):
        body = fetch(f"{BASE}/{ym}/")
        time.sleep(INTERVAL)
        if not body:
            fail += 1
            print(f"  [{i}/{len(targets)}] {ym}  ★ 取れず", flush=True)
            continue
        rows = parse(body, ym)
        # ★ 過ぎた月が 0 件になることは無い。相手が間欠的に中身の欠けた応答を
        #   返す（HTTP 200 のまま 754 バイト）ので、取り直す。
        #   まだ来ていない月は本当に 0 件なので、そこは区別する。
        if not rows and ym <= _this_month():
            for _ in range(2):
                time.sleep(3.0)
                body = fetch(f"{BASE}/{ym}/")
                rows = parse(body, ym)
                if rows:
                    break
        had = len(rows_by_month.get(ym, []))
        if not rows and ym <= _this_month():
            kept += 1
            print(f"  [{i}/{len(targets)}] {ym}  ★ 過ぎた月なのに 0 件"
                  f"（{'前の ' + str(had) + ' 件を残す' if had else '取れていない'}）",
                  flush=True)
            continue
        if not rows and had:
            kept += 1
            print(f"  [{i}/{len(targets)}] {ym}  ★ 0 件で返った"
                  f"（前の {had} 件を残す）", flush=True)
            continue
        rows_by_month[ym] = rows
        st["months"][ym] = {"at": datetime.now(timezone.utc).isoformat(
            timespec="seconds"), "n": len(rows)}
        ok += 1
        if i % 12 == 0 or len(rows):
            print(f"  [{i}/{len(targets)}] {ym}  {len(rows)} 件", flush=True)
        if i % 10 == 0:
            _flush(st, rows_by_month)
    return ok, fail, kept


def cmd_crawl(args) -> int:
    st = load_state()
    by_month = {}
    for r in load_index():
        by_month.setdefault(r["month"], []).append(r)
    targets = [m for m in months()
               if args.all or m not in st["months"]]
    print(f"# 取得 {len(targets)} 月分")
    ok, fail, kept = crawl(targets, st, by_month)
    rows = [r for m in sorted(by_month) for r in by_month[m]]
    write_index(rows)
    save_state(st)
    print(f"\n成功 {ok} / 失敗 {fail} / 0 件で返って前を残した {kept}"
          f" / 索引 {len(rows):,} 件 -> {index_path()}")
    return 1 if (fail or kept) else 0


def feed_months() -> list:
    body = fetch(FEED)
    out = []
    for it in re.findall(r"<item>(.*?)</item>", body, re.S):
        t = re.search(r"<title>(.*?)</title>", it, re.S)
        d = re.search(r"<pubDate>(.*?)</pubDate>", it, re.S)
        if not t:
            continue
        m = _FEED_TITLE.match(_text(t.group(1)))
        if m:
            out.append((f"{m.group(2)}/{int(m.group(3)):02d}",
                        _text(d.group(1)) if d else ""))
    return out


def cmd_update(args) -> int:
    st = load_state()
    by_month = {}
    for r in load_index():
        by_month.setdefault(r["month"], []).append(r)

    want = {ym for ym, _ in feed_months()}
    if not want:
        print("★ feed が読めなかった")

    now = datetime.now()
    for k in range(-3, 5):
        m = now.month + k
        y = now.year + (m - 1) // 12
        want.add(f"{y}/{(m - 1) % 12 + 1:02d}")

    targets = sorted(want)
    print(f"# 更新 {len(targets)} 月分（feed + 今月±）")
    ok, fail, kept = crawl(targets, st, by_month)
    rows = [r for m in sorted(by_month) for r in by_month[m]]
    write_index(rows)
    st["last_feed"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    save_state(st)
    print(f"\n成功 {ok} / 失敗 {fail} / 0 件で返って前を残した {kept}"
          f" / 索引 {len(rows):,} 件")
    return 1 if (fail or kept) else 0


def cmd_status(args) -> int:
    st = load_state()
    rows = load_index()
    done = set(st["months"])
    allm = months()
    miss = [m for m in allm if m not in done]
    print(f"索引     {len(rows):,} 件")
    print(f"取得済み  {len(done)} / {len(allm)} 月")
    print(f"最終 feed {st.get('last_feed') or '-'}")
    if miss:
        print(f"未取得   {len(miss)} 月: {miss[:12]}{' …' if len(miss) > 12 else ''}")
    labels = {}
    for r in rows:
        labels[r.get("label", "")] = labels.get(r.get("label", ""), 0) + 1
    print(f"レーベル  {len(labels)} 種")
    for k, v in sorted(labels.items(), key=lambda x: -x[1])[:10]:
        print(f"   {k:<28} {v:>6}")
    return 0


def _search_online(word: str) -> list:
    body = fetch(f"{SEARCH}?IncludeBlogs=1&search="
                 + urllib.parse.quote(word))
    return parse(body, "0000/00") if body else []


# 杜の側だけに付く飾り。デビュー巻の題名に受賞の但し書きが入る（実測 1,172 件）
#   例 「ムーンスペル!![第16回ファンタジア長編小説大賞＜佳作＞]」
_AWARD = re.compile(r"[\[［][^\[\]［］]*(?:賞|大賞)[^\[\]［］]*[\]］]\s*$")

# 読み仮名の括弧。**中身が仮名だけ**のものに限る（実測-32）
# ★ `-` を入れる。**norm が長音符 ー を - に直す**（_DASH）ので、
#   norm のあとの「アンコール」は「アンコ-ル」になっている。
#   仮名だけを見ていたぶん、読みの括弧が長音を含むと当たっていなかった
_RUBY = re.compile(r"[（(＜<〈《【]\s*[ぁ-んァ-ヶー・ｰ\-]+\s*[）)＞>〉》】]")

# 括弧の種類と巻号のゼロ埋めを揃える（実測-40）。**書名の意味を変えない差**だけ。
# ★ 括弧そのものを消さない。「猫物語(黒)」と「猫物語(白)」を潰してしまう。
#   潰すのは**種類**だけで、括弧が在るという事実は残す
# ★ ASCII の [ ] を忘れない。**norm の NFKC が ［ を [ に直したあと**なので、
#   全角だけ書いても一件も当たらない（「猫物語［黒］」がそれで素通りした）
_BRACKET = dict.fromkeys(map(ord, "［[【〔〖《〈＜<{"), "(")
_BRACKET.update(dict.fromkeys(map(ord, "］]】〕〗》〉＞>}"), ")"))
_ZERO = re.compile(r"\d+")


def _shape(k: str) -> str:
    """norm 済みの文字列から、括弧の種類とゼロ埋めの差を落とす。"""
    return _ZERO.sub(lambda m: str(int(m.group())), (k or "").translate(_BRACKET))


# 括弧そのものを外す（実測-42）。_shape のあとなので括弧の種類は揃っている。
# ★ **中身が数字だけの括弧は外さない**（実測-43）。ラノベでは `(1)` が
#   漫画版の巻、裸の `1` が小説の巻という書き分けが広く使われていて、
#   外すと**小説とそのコミカライズが同じ一冊になる**:
#       手元「嘆きの亡霊は引退したい… 1」（小説）
#         → 電撃コミックスNEXT「嘆きの亡霊は引退したい… (1)」（漫画）
#   `(黒)` `(下)` のように中身が数字でないものは外して良い。
_NO_BRACKET = re.compile(r"\(([^()]*[^\d()][^()]*)\)")


def _debracket(k: str) -> str:
    """中身が数字でない括弧だけを外す。中身は残す。"""
    return _NO_BRACKET.sub(lambda m: m.group(1), k or "")


# 題名の**末尾**に付いた叢書の標（実測-41）。
# ★ 中身に 上中下前後完・数字 を含むものは触らない。「〈下〉」を落とすと
#   巻を取り違える（壊れ方 1-9）。頭に来る括弧にも触らない
_SERIES = re.compile(
    r"[(<〈《【]\s*(?![^)>〉》】]*[上中下前後完零一二三四五六七八九十0-9])"
    r"[^)>〉》】]{1,10}\s*[)>〉》】]\s*$")


# 杜のレーベル欄に文庫名ではなく**判型**が入っている行がある（索引 981 件）。
# 文庫を持たない単行本なので杜には書きようが無いのだが、「B6判」は棚で
# 何もまとめない。レーベルとして使わず、奥付か RDB へ譲る（実測-26）。
_FORMATS = frozenset(("単行本", "B6判", "四六判", "A4判", "A5判", "新書", "その他"))


def is_format(label: str) -> bool:
    """そのレーベル欄が文庫名ではなく判型か。**完全一致だけで見る。**"""
    return (label or "").strip() in _FORMATS


def title_of(row: dict) -> str:
    """棚に出す題名。**受賞の但し書きは本の名前ではない**ので落とす。

    索引には杜が返したままを残してある（source of truth を書き換えない）。
    落とすのはここだけ。
    """
    t = _TAG_FRAG.sub("", (row or {}).get("title", "") or "")
    return _AWARD.sub("", t).strip()


def index_key(title: str) -> str:
    # 既に索引に入ってしまった壊れた題名もここで揃える（_text の直しは
    # 次に crawl したときに効くが、それを待たなくてよいように）
    return norm(_AWARD.sub("", _TAG_FRAG.sub("", title or "")))


def labels_of(rows: list) -> set:
    return {r.get("_lk") or norm(r.get("label", ""))
            for r in rows if r.get("label")}


def by_label_month(label: str, yymm: str, rows: list | None = None) -> list:
    """レーベルと発売月で絞る。**判断ではなく、候補を小さくするだけ。**

    奥付から取れる二つの事実だけを使うので、候補集合そのものは確定している。
    どれかを選ぶのは読む側。
    """
    rows = rows if rows is not None else load_index()
    lk, mk = norm(label), (yymm or "")[:4]
    if not lk or len(mk) != 4:
        return []
    return [r for r in rows
            if (r.get("_lk") or norm(r.get("label", ""))) == lk
            and (r.get("date") or "")[:4] == mk]


def find(word: str, rows: list | None = None) -> dict:
    """完全一致と、示唆（含む・含まれる）を分けて返す。

    完全一致は二段 — そのままの題名と、電子版の飾りを落とした題名。
    どちらも外れたら示唆しか出さない。
    """
    rows = rows if rows is not None else load_index()
    k = norm(word)
    if not k:
        return {"exact": [], "hint": [], "経路": ""}
    keys = [(_key_of(r), r) for r in rows]
    exact = [r for kk, r in keys if kk == k]
    if exact:
        return {"exact": exact, "hint": [], "経路": "題名"}

    k2 = norm(strip_decor(word, labels_of(rows)))
    if k2 and k2 != k:
        exact = [r for kk, r in keys if kk == k2]
        if exact:
            return {"exact": exact, "hint": [], "経路": "飾りを落として"}

    # ★ 読み仮名を**両側から**落として、もう一度だけ見る。
    #   手元が「優雅な生活(スローライフ)」で杜が「優雅な生活」のように、
    #   片方だけに読みが付いていることが繰り返し起きる（実測-32）。
    #   落とすのは**中身が仮名だけの括弧**に限る — 巻号は数字、副題は漢字を
    #   含むので巻き込まない。索引 500 件が該当し、落とすと重なる組が
    #   495 → 497 に増えるので、**一件に絞れたときだけ答える**。
    # ★ `k3 != k` を条件にしない。この道は**索引の側も落として**比べるので、
    #   手元に読みが無くても（k3 == k でも）杜の側に読みが有れば当たる。
    #   条件を付けていたせいで、その形が丸ごと通らなかった
    k3 = norm(_RUBY.sub("", word))
    if k3:
        exact = [r for kk, r in keys if _RUBY.sub("", kk) == k3]
        if len(exact) == 1:
            return {"exact": exact, "hint": [], "経路": "読みを落として"}

    # ★ 括弧の種類と巻号の桁を揃えて、もう一度だけ見る（実測-40）。
    #   同じ一冊が、出しどころによって書き方が割れる:
    #       手元「猫物語［黒］」           杜「猫物語 (黒)」
    #       手元「ハイスクールD×D 03 …」  杜「ハイスクールD×D３ …」
    #   括弧の**種類**も巻号の**ゼロ埋め**も書名の意味を変えない。
    #   ただし揃えるほど別の一冊と重なりやすくなるので、
    #   **一件に絞れたときだけ答える**（「読みを落として」と同じ構え）。
    k4 = _shape(k2 or k)
    if k4:
        exact = [r for kk, r in keys if _shape(kk) == k4]
        if len(exact) == 1:
            return {"exact": exact, "hint": [], "経路": "括弧と桁を揃えて"}

    # ★ **題名の末尾に付いた叢書の標**を落として、もう一度だけ見る（実測-41）。
    #   手元「化物語（上） <物語> (講談社ＢＯＸ)」  杜「化物語 (上)」
    #   `<物語>` は叢書の名前で、その一冊の題名ではない。
    #   落とすのは**末尾のもの**だけ — 「<Infinite Dendrogram>-インフィニット…」の
    #   ように、頭に来る括弧は題名そのものなので触れない。
    #   中身に 上中下前後完 や数字を含むものも触れない（〈下〉を落とすと
    #   巻を取り違える。壊れ方 1-9 がまさにその形）。
    #   索引 424 行が該当し、落とすと 69 組が重なる — その多くは
    #   **【新装版】や(初回限定特装版)という本当に別の版**なので、
    #   ここでも **一件に絞れたときだけ答える**。
    k5 = _SERIES.sub("", k2 or k)
    if k5:
        exact = [r for kk, r in keys if _SERIES.sub("", kk) == k5]
        if len(exact) == 1:
            return {"exact": exact, "hint": [], "経路": "叢書の標を落として"}

    # ★ 最後に、括弧そのものを落として見る（実測-42）。
    #   手元「終物語 下」  杜「終物語 (下)」— 括弧が**在るか無いか**の差。
    #   中身は残るので「猫物語黒」と「猫物語白」は分かれたまま。
    #   索引 5,280 組が重なるが、その大半は**杜が同じ一冊を括弧違いで
    #   二度載せている**もの。二行あればこの道は黙るので、
    #   重なりが増えること自体は取り違えにならない。
    #   一番弱い道なので**一番最後**に置き、やはり一件のときだけ答える。
    k6 = _debracket(_shape(k2 or k))
    if k6:
        exact = [r for kk, r in keys if _debracket(_shape(kk)) == k6]
        if len(exact) == 1:
            return {"exact": exact, "hint": [], "経路": "括弧を落として"}

    hint = ([r for kk, r in keys if k in kk or kk in k]
            if len(k) >= 6 else [])
    return {"exact": [], "hint": hint[:12], "経路": ""}


def by_isbn(isbn: str, rows: list | None = None) -> list:
    isbn = re.sub(r"\D", "", isbn or "")
    if not isbn:
        return []
    rows = rows if rows is not None else load_index()
    return [r for r in rows if r.get("isbn") == isbn]


def cmd_find(args) -> int:
    rows = load_index()
    if args.isbn:
        got = by_isbn(args.isbn, rows)
        print(f"# ISBN {args.isbn} -> {len(got)} 件")
        for r in got:
            print("  " + json.dumps(r, ensure_ascii=False))
        return 0
    res = find(args.word, rows)
    print(f"# 「{args.word}」  完全一致 {len(res['exact'])} / 示唆 {len(res['hint'])}")
    for r in res["exact"]:
        print(f"  [一致] {r['label']} {r['date']} 「{r['title']}」"
              f" 著:{r.get('author','-')} 絵:{r.get('artist','-')}"
              f" {r.get('isbn') or ('電子専売' if r.get('digital_only') else '-')}")
    for r in res["hint"]:
        print(f"  [示唆] {r['label']} {r['date']} 「{r['title']}」"
              f" 著:{r.get('author','-')} 絵:{r.get('artist','-')}")
    if not res["exact"] and args.online:
        got = _search_online(args.word)
        print(f"\n# 網で検索 -> {len(got)} 行（entry 単位で返るので要絞り込み）")
        k = norm(args.word)
        for r in got:
            if k in norm(r["title"]) or norm(r["title"]) in k:
                print(f"  [網] {r['label']} 「{r['title']}」"
                      f" 著:{r.get('author','-')} 絵:{r.get('artist','-')}"
                      f" {r.get('isbn','-')}")
    return 0


def main(argv=None) -> int:
    import argparse
    ap = argparse.ArgumentParser(prog="mori")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("crawl", help="月ページを全部くだす")
    p.add_argument("--all", action="store_true", help="取得済みも取り直す")
    p.set_defaults(fn=cmd_crawl)

    p = sub.add_parser("update", help="feed と今月±で差分だけ")
    p.set_defaults(fn=cmd_update)

    p = sub.add_parser("status", help="索引の状態")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("find", help="索引を引く")
    p.add_argument("word", nargs="?", default="")
    p.add_argument("--isbn")
    p.add_argument("--online", action="store_true", help="無ければ網も引く")
    p.set_defaults(fn=cmd_find)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    raise SystemExit(main())
