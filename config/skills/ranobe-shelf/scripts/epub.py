"""ファイル自身を読む。**測るだけ。判断しない**。

    OPF   名乗っている題名・著者・発売日・出版社
    奥付  レーベル・紙の発売日・電子版の配信日・ISBN
    本文  字数・画像・頁

閾値は一つも持たない。読めなければ「読めなかった」と言う。
探し方を決めた実測は 記録/2-実測.md。
"""

from __future__ import annotations

import re
import unicodedata
import zipfile
from html import unescape
from pathlib import Path
from urllib.parse import unquote

_TAG = re.compile(r"<[^>]+>")
_SCRIPT = re.compile(r"<(script|style)\b.*?</\1>", re.S | re.I)
_ENTITY = re.compile(r"&[#0-9a-zA-Z]{1,8};")
_SPACE = re.compile(r"[\s　]+")
_IMG = re.compile(r"<(?:img|image)\b", re.I)

_OPF_PATH = re.compile(r'full-path="([^"]+)"')
_DC = {
    "title": re.compile(r"<dc:title[^>]*>(.*?)</dc:title>", re.S | re.I),
    "creator": re.compile(r"<dc:creator[^>]*>(.*?)</dc:creator>", re.S | re.I),
    "date": re.compile(r"<dc:date[^>]*>(.*?)</dc:date>", re.S | re.I),
    "publisher": re.compile(r"<dc:publisher[^>]*>(.*?)</dc:publisher>", re.S | re.I),
}
_SPINE = re.compile(r"<itemref[^>]*idref=\"([^\"]+)\"", re.I)
_ITEM = re.compile(r"<item\b[^>]*>", re.I)
_ATTR = re.compile(r'(\w[\w:-]*)="([^"]*)"')

NAME_HINT = re.compile(r"colophon|okuduke|okuzuke|奥付|copyright|caution", re.I)
WORDS = ("Ⓒ", "発行", "イラスト", "株式会社", "カバー", "禁じ", "配信",
         "電子書籍", "発行者", "©", "初版", "転載", "著作権", "印刷",
         "刊行", "電子版", "発行所", "Printed in Japan", "複写", "定価",
         "落丁", "乱丁", "ISBN")
WORDS_MIN = 3

_LABEL_TAIL = (r"文庫|ノベルス|ノベルズ|ブックス|BOOKS|novels|新書|"
               r"コミックス|文芸|ノベル")
_L_BEFORE = re.compile(
    rf"([一-龥ぁ-んァ-ヶーA-Za-z0-9・＆&]{{2,16}}(?:{_LABEL_TAIL}))\s*[『「]")
_L_ALONE = re.compile(
    rf"(?:^|\s)([一-龥ぁ-んァ-ヶーA-Za-z0-9・＆&]{{2,16}}(?:{_LABEL_TAIL}))(?:\s|$)")

_D_PAPER = re.compile(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日"
                      r"[^\d]{0,12}?(?:初版|第一刷|第１刷)")
_D_ANY = re.compile(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日")

ISBN_RE = re.compile(
    r"ISBN[\s:：]*((?:97[89])[-\s]?(?:\d[-\s]?){9}\d)"
    r"|ISBN[\s:：]*((?:\d[-\s]?){9}[\dXx])", re.I)


def _text_of(html: str) -> str:
    s = _SCRIPT.sub(" ", html)
    s = _TAG.sub(" ", s)
    s = _ENTITY.sub(" ", s)
    return _SPACE.sub("", s)


def _flat(html: str) -> str:
    t = unicodedata.normalize("NFKC", _TAG.sub(" ", html))
    return re.sub(r"[\s　]+", " ", t)


def _clean(s: str) -> str:
    """★ 実体参照をほどく。ほどかないと OPF の題名に `&lt;物語&gt;` が
      そのまま残り、杜のどの行とも当たらない。本文を読む `_text_of` は
      実体参照を落としていたのに、**題名を読むここだけ落としていなかった**
      — 同じ規則が二か所にあり、片方だけ直っていた形（壊れ方 5 章）。
      落とすのではなく**ほどく**。`&amp;` は本当に `&` を意味するので、
      落とすと「ビルド&クラフト」が「ビルドクラフト」に化ける。
    """
    return _SPACE.sub(" ", unescape(_TAG.sub("", s))).strip()


def _first(pat, s: str) -> str:
    m = pat.search(s)
    return m.group(1) if m else ""


def _ymd(m) -> str:
    return f"{m.group(1)[2:]}{int(m.group(2)):02d}{int(m.group(3)):02d}"


def find_isbn(text: str) -> str:
    for m in ISBN_RE.finditer(text):
        v = re.sub(r"[-\s]", "", m.group(1) or m.group(2) or "")
        if len(v) in (10, 13):
            return v
    return ""


def _read_opf(z: zipfile.ZipFile) -> tuple:
    try:
        c = z.read("META-INF/container.xml").decode("utf-8", "replace")
    except KeyError:
        return {}, []
    m = _OPF_PATH.search(c)
    if not m:
        return {}, []
    try:
        opf = z.read(m.group(1)).decode("utf-8", "replace")
    except KeyError:
        return {}, []

    meta = {
        "題名": _clean(_first(_DC["title"], opf)),
        "著者": [_clean(x) for x in _DC["creator"].findall(opf) if _clean(x)],
        "日付": _clean(_first(_DC["date"], opf)),
        # dc:publisher は出版社。レーベルではない（実測 261 件で一致 0）
        "出版社": _clean(_first(_DC["publisher"], opf)),
    }

    href = {}
    for tag in _ITEM.findall(opf):
        a = dict(_ATTR.findall(tag))
        if a.get("id") and a.get("href"):
            href[a["id"]] = a["href"]
    base = m.group(1).rsplit("/", 1)[0] if "/" in m.group(1) else ""
    order = []
    for idref in _SPINE.findall(opf):
        h = href.get(idref)
        if h:
            h = unquote(h)      # href は URL エンコードされていることがある
            order.append(f"{base}/{h}" if base else h)
    return meta, order


def _colophon(pages: list) -> dict:
    out = {"読めた": False, "レーベル": "", "紙の日付": "", "電子の日付": "",
           "ISBN": "", "頁": ""}
    for name, raw in reversed(pages):
        t = _flat(raw)
        hinted = bool(NAME_HINT.search(name))
        n_words = sum(1 for w in WORDS
                      if unicodedata.normalize("NFKC", w) in t)
        if not hinted and n_words < WORDS_MIN:
            continue
        if not out["読めた"]:
            out["読めた"] = True
            out["頁"] = name
        if not out["ISBN"]:
            out["ISBN"] = find_isbn(t)
        if not out["レーベル"]:
            m = _L_BEFORE.search(t) or _L_ALONE.search(t)
            if m:
                out["レーベル"] = m.group(1)
        paper = _D_PAPER.search(t)
        if paper and not out["紙の日付"]:
            out["紙の日付"] = _ymd(paper)
        if not out["電子の日付"]:
            # 最初の一つで諦めない。頁の先頭に来るのはたいてい紙のほう
            skip = {out["紙の日付"]} | ({_ymd(paper)} if paper else set())
            for m in _D_ANY.finditer(t):
                if _ymd(m) not in skip:
                    out["電子の日付"] = _ymd(m)
                    break
    if out["電子の日付"] == out["紙の日付"]:
        out["電子の日付"] = ""
    return out


# 目次・奥付・扉など、柱を探すのに邪魔な頁
_NOT_BODY = re.compile(r"目次|contents|navigation|奥付|colophon|表紙|cover", re.I)
# 本文の前に挟まる断り書き。ここに柱は出ない。
# ★ **実測で集めた一覧**（調べ 3,300 件のうち 251 件が断り書きで始まっていた）。
#   多いのは二つ — 「本書（電子版）に掲載されている…」30 件、
#   「本作品の全部または一部を無断で…」24 件。括弧の中身は版元で違うので
#   `本書（…）に掲載されて` と幅を持たせる。
_NOTICE = re.compile(r"^(?:ご利用上の注意|本作品を示す|本電子書籍を示す"
                     r"|本書[（(][^）)]{0,8}[）)]?に掲載されて|本書に掲載されて"
                     r"|本作品の全部|本作品は、?縦書き"
                     r"|本コンテンツは|この作品の全部"
                     r"|この作品はフィクション|著作権)")
# 柱の頭に付く組版の記号。`c1A` `c9` のほか `part0007` の形もある
_HEAD_MARK = re.compile(r"^(?:part\d+|c[0-9A-Za-z]{1,4}|[※◆■])")


def _running_head(pages: list) -> str:
    """**本文の頁の頭に出る書名**（柱）を返す。

    ★ これが「その本が自分を何と呼んでいるか」の一番強い証拠。
      ファイル名は旧い整理が付けたもので、一冊ずれていることがある
      （魔術師の杖・最果てのパラディン。壊れ方 1-9）。OPF と奥付も
      出版社が writing する側なので写し間違いが混じるが、柱は本文と
      一緒に組まれるので、三つの中では一番ずれにくい。
    """
    for n, raw in pages:
        t = _text_of(raw).strip()
        if len(t) < 40 or _NOT_BODY.search(n) or _NOT_BODY.search(t[:40]):
            continue
        bare = _HEAD_MARK.sub("", t).lstrip()
        if _NOTICE.match(t) or _NOTICE.match(bare):
            continue
        # 柱は行頭に一度だけ出るので、最初の一行を採る
        first = bare.splitlines()[0].strip() if bare.splitlines() else ""
        return (first or bare)[:80]
    return ""


def read(p: Path) -> dict:
    """一冊読む。暗号化 zip の RuntimeError なども全部ここで受ける。"""
    out = {
        "ファイル名": p.name,
        "opf": {}, "奥付": {"読めた": False}, "柱": "",
        "本文": {"読めた": False, "字数": 0, "画像": 0, "頁": 0},
        "表紙あり": False, "読めない理由": "",
    }
    if p.suffix.lower() != ".epub":
        out["読めない理由"] = f"{p.suffix} は中身を読めない"
        return out
    try:
        with zipfile.ZipFile(p) as z:
            meta, order = _read_opf(z)
            names = set(z.namelist())
            if not order:
                order = sorted(n for n in names
                               if n.lower().endswith((".xhtml", ".html", ".htm")))
            pages, chars, images = [], 0, 0
            for n in order:
                if n not in names:
                    continue
                try:
                    raw = z.read(n).decode("utf-8", "replace")
                except Exception:
                    continue
                pages.append((n, raw))
                chars += len(_text_of(raw))
                images += len(_IMG.findall(raw))
            out["opf"] = meta
            out["奥付"] = _colophon(pages)
            out["本文"] = {"読めた": bool(pages), "字数": chars,
                          "画像": images, "頁": len(pages)}
            out["柱"] = _running_head(pages)
            out["表紙あり"] = any(
                n.lower().endswith((".jpg", ".jpeg", ".png")) for n in names)
    except Exception as e:
        out["読めない理由"] = f"{type(e).__name__}: {e}"
    return out

