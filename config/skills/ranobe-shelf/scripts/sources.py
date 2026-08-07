"""RanobeDB と BookWalker に問う。**返ってきたものをそのまま渡す**。

巻号を読む・名前を作る・どれが当たりかを選ぶ — どれもしない。
それは読む側（AI）の仕事。ここは取得と、源ごとの言葉の対応付けだけ。

## 源の癖

    RanobeDB    title は英語のことがある（43%）。**title_orig が日本語**
                bookwalker_id を必ず持つので、語で検索せず系列頁へ直行できる
                book_type が本篇かを答えている。題名で選り分けない
                c_end_date が 99999999 でなければ完結（publication_status と等価）
                反映が遅れる（新しい巻が載っていない）
    BookWalker  出版社が付けた系列名が取れる唯一の源
                **著者が載らない**（空は「不明」であって「著者なし」ではない）
                取り下げがある。本編と派生を同じ頁に並べる
                検索頁のタグ comp=完結 / gift=特典 / comic=マンガ / 分冊版

## ISBN

`/releases?q=<isbn>` は正確（実在で 1 件、架空で 0 件）。
`/books?isbn=` は**効かない** — 架空の ISBN でも同じ 24 件を返す。使うな。

## 控え

一度取ったものはディスクに残す。障害（500 番台・切断）は残さない。
"""

from __future__ import annotations

import hashlib
import html
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

import ledger as L

UA_API = "ranobe-shelf/1.0 (personal library maintenance)"
UA_WEB = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# ★ 一冊につき RanobeDB へ三度問う。100 冊の批を 0.34 秒間隔で回したら
#   途中から**続けて落ちる**ようになり、78 件のうち 57 件が「源が答えない」
#   に落ちた（次に走らせたら全部通ったので、控えは汚れていない）。
#   小さな相手なので、こちらが遅くする（実測-28）
INTERVAL = {"ranobedb": 0.8, "bookwalker": 1.2}
NAMES = ("ranobedb", "bookwalker")
RDB = "https://ranobedb.org/api/v0"
BW = "https://bookwalker.jp"

_last = {}
failures = {}


def _fetch(url: str, *, bucket: str, ua: str = UA_API, as_json: bool = False,
           refresh: bool = False):
    h = hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]
    p = L.cache_dir() / bucket / (h + (".json" if as_json else ".html"))
    if p.exists() and not refresh:
        t = p.read_text(encoding="utf-8", errors="replace")
        return json.loads(t) if (as_json and t.strip()) else t

    req = urllib.request.Request(url)
    req.add_header("User-Agent", ua)
    if as_json:
        req.add_header("Accept", "application/json")

    body = None
    for attempt in range(3):
        dt = time.monotonic() - _last.get(bucket, 0.0)
        if dt < INTERVAL.get(bucket, 1.0):
            time.sleep(INTERVAL[bucket] - dt)
        _last[bucket] = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read().decode("utf-8", errors="replace")
            break
        except urllib.error.HTTPError as e:
            # ★ 403 をここに入れてはいけない。**断りは答えではない。**
            #   混ぜ込みで断られたときに「この ISBN は存在しない」が
            #   控えに焼き付き、以後どれだけ走らせても取り直せなくなる。
            #   400/404 だけが「そんなものは無い」という答え
            if e.code in (400, 404):
                body = ""
                break
            time.sleep(2 * (attempt + 1))
        except Exception:
            time.sleep(2 * (attempt + 1))

    if body is None:               # 障害。控えに残さない
        failures[bucket] = failures.get(bucket, 0) + 1
        return {} if as_json else ""

    # ★ 一度で入れ替える。途中で切れた控えは JSON として壊れ、
    #   次に読むと「見つからない」と区別が付かないまま焼き付く
    L.write_atomic(p, body)
    if not as_json:
        return body
    try:
        return json.loads(body) if body.strip() else {}
    except json.JSONDecodeError:
        return {}


def _yymmdd(raw) -> str:
    s = str(raw or "").replace("-", "")
    return s[2:] if len(s) == 8 and s.isdigit() else ""


def _ja(d: dict) -> str:
    return d.get("title_orig") or d.get("title") or ""


# ---------------------------------------------------------------- RanobeDB

def _series_detail(sid, refresh=False) -> dict:
    d = (_fetch(f"{RDB}/series/{sid}", bucket="ranobedb", as_json=True,
                refresh=refresh) or {}).get("series") or {}
    if not d:
        return {}
    label = ""
    for want in ("imprint", "publisher"):
        for p in (d.get("publishers") or []):
            if p.get("lang") == "ja" and not label \
                    and p.get("publisher_type") == want:
                label = p.get("name") or ""
    staff = d.get("staff") or []
    author = next((x["name"] for x in staff
                   if x.get("role_type") == "author"), "")
    artist = next((x["name"] for x in staff
                   if x.get("role_type") == "artist"
                   and not (x.get("note") or "").strip()), "")
    books = sorted(d.get("books") or [], key=lambda x: x.get("sort_order") or 0)
    vols = [{"順": b.get("sort_order"), "題名": _ja(b),
             "発売日": _yymmdd((b.get("c_release_dates") or {}).get("ja")),
             "型": b.get("book_type") or ""} for b in books]
    # ★ 最終巻は**既に出た**巻の最新。予告の巻を入れると、
    #   止まった作品が先の日付のおかげで連載中に見えてしまう
    today = datetime.now().strftime("%y%m%d")
    released = [v["発売日"] for v in vols if v["発売日"] and v["発売日"] <= today]
    end = d.get("c_end_date")
    return {
        "source": "ranobedb", "id": str(d.get("id") or ""),
        "題名": _ja(d), "著者": author, "絵師": artist, "レーベル": label,
        "完結": bool(end and end != 99999999),
        "最終巻": max(released) if released else "",
        "bookwalker_id": str(d.get("bookwalker_id") or ""),
        "派生": [{"id": c.get("id"), "関係": c.get("relation_type"),
                "題名": _ja(c)} for c in (d.get("child_series") or [])],
        "巻": vols,
    }


def work(wid: str, refresh: bool = False) -> dict:
    """作品 id（rdb:NNNN）から巻一覧を引く。欠巻の標を引くのに使う。"""
    wid = (wid or "").strip()
    if not wid.startswith("rdb:"):
        return {}
    return _series_detail(wid[4:], refresh)


def ranobedb(q: str, refresh: bool = False) -> list:
    if not q.strip():
        return []
    hits = (_fetch(f"{RDB}/series?q={urllib.parse.quote(q)}",
                   bucket="ranobedb", as_json=True, refresh=refresh)
            or {}).get("series") or []
    out = []
    for hit in hits[:3]:
        d = _series_detail(hit.get("id"), refresh)
        if d:
            out.append(d)
    return out


def by_isbn(isbn: str, refresh: bool = False) -> dict:
    """ISBN から巻と作品を引く。**当たれば確定**。"""
    isbn = re.sub(r"\D", "", isbn or "")
    if len(isbn) not in (10, 13):
        return {}
    rs = (_fetch(f"{RDB}/releases?q={isbn}", bucket="ranobedb", as_json=True,
                 refresh=refresh) or {}).get("releases") or []
    rel = next((r for r in rs if re.sub(r"\D", "", str(r.get("isbn13") or ""))
                == isbn), None)
    if not rel:
        return {}
    one = _fetch(f"{RDB}/release/{rel['id']}", bucket="ranobedb",
                 as_json=True, refresh=refresh) or {}
    r = one.get("release") or one
    books = r.get("books") or []
    if not books:
        return {}
    b = books[0]
    book = (_fetch(f"{RDB}/book/{b['id']}", bucket="ranobedb", as_json=True,
                   refresh=refresh) or {}).get("book") or {}
    # ★ 半端な答えを返さない。ここが障害で空になると、作品も著者も絵師も
    #   欠けたまま「確定した」形で返り、台帳に作品の無い巻が入る。
    #   **取れなかったなら何も返さない**（次に走らせれば取り直す）
    if not book:
        failures["ranobedb"] = failures.get("ranobedb", 0) + 1
        return {}
    ser = book.get("series") or {}
    dates = {}
    for x in (book.get("releases") or []):
        if x.get("lang") == "ja" and x.get("format") in ("print", "digital"):
            dates.setdefault(x["format"], _yymmdd(x.get("release_date")))
    staff = []
    for ed in (book.get("editions") or []):
        staff += ed.get("staff") or []
    # ★ **imprint は採らない。** ここは杜が「文庫を持たない本だ」と言った
    #   ときの逃げ道なので、そこで RDB の文庫名を採ると嘘が入る。
    #   佐々木とピーちゃん — 杜 単行本（小説 13 行すべて）/ BookWalker 新文芸
    #   に対し RDB の imprint は「MF文庫J」。三源で一対二、RDB が誤り。
    #   出版社なら粗いが嘘ではないので、まとまる単位として使える（実測-27）
    press = next((p.get("name") for p in (r.get("publishers") or [])
                  if p.get("publisher_type") == "publisher"), "")
    return {
        "source": "ranobedb", "isbn": isbn, "レーベル": press,
        "book_id": str(b.get("id") or ""), "順": b.get("sort_order"),
        "題名": _ja(b), "作品": f"rdb:{ser.get('id')}" if ser.get("id") else "",
        "作品題名": _ja(ser),
        "著者": next((s["name"] for s in staff
                    if s.get("role_type") == "author"), ""),
        "絵師": next((s["name"] for s in staff
                    if s.get("role_type") == "artist"
                    and not (s.get("note") or "").strip()), ""),
        "紙の発売日": dates.get("print", ""),
        "電子の発売日": dates.get("digital", ""),
        "頁": r.get("pages"),
    }


# ---------------------------------------------------------------- BookWalker

_ITEM = re.compile(r'class="m-book-item\s*"(.*?)(?=class="m-book-item\s*"|\Z)',
                   re.DOTALL)
_SID = re.compile(r'data-series-id="(\d+)"')
_IMG_TITLE = re.compile(r'<img[^>]*\stitle="([^"]+)"')
_TAG = re.compile(r'<span class="a-tag-([a-z]+)">([^<]+)</span>')
_H1 = re.compile(r"<h1[^>]*>\s*『(.+?)』の電子書籍一覧", re.DOTALL)
_OG = re.compile(r'<meta property="og:title" content="([^"]+)"')
_GENRE = re.compile(r"[(（]\s*(?:文芸・小説|ライトノベル|新文芸|マンガ|実用"
                    r"|ゲーム|写真集|雑誌|画集・写真集|その他)[^)）]*[)）]\s*$")
_LABEL_TAIL = re.compile(r"[（(]([^（）()]{2,20})[）)]\s*$")
_QUOTED = re.compile(r"^「(.+)」シリーズ$")


def _bw_items(body: str) -> list:
    out, seen = [], set()
    for blk in _ITEM.findall(body):
        t = _IMG_TITLE.search(blk)
        if not t:
            continue
        title = html.unescape(t.group(1)).strip()
        if title in seen:
            continue
        seen.add(title)
        sid = _SID.search(blk)
        tags = [html.unescape(v) for _, v in _TAG.findall(blk)]
        out.append({"series_id": sid.group(1) if sid else "", "題名": title,
                    "タグ": tags})
    return out


def _bw_series(sid: str, refresh: bool = False) -> dict:
    page = _fetch(f"{BW}/series/{sid}/list/", bucket="bookwalker",
                  ua=UA_WEB, refresh=refresh) or ""
    m = _H1.search(page) or _OG.search(page)
    name, label = "", ""
    if m:
        name = html.unescape(m.group(1)).strip()
        name = re.sub(r"の電子書籍.*$", "", name).strip()
        for _ in range(4):
            before = name
            name = _GENRE.sub("", name).strip()
            lm = _LABEL_TAIL.search(name)
            if lm:
                label = label or lm.group(1).strip()
                name = name[:lm.start()].strip()
            if name == before:
                break
        qm = _QUOTED.match(name)
        if qm:
            name = qm.group(1).strip()
    items = _bw_items(page)
    tags = sorted({t for x in items for t in x["タグ"]})
    return {"source": "bookwalker", "id": sid, "題名": name, "レーベル": label,
            "タグ": tags, "著者": "",
            "巻": [{"題名": x["題名"], "タグ": x["タグ"]} for x in items]}


def bookwalker(q: str, refresh: bool = False, series_id: str = "") -> list:
    """series_id が分かっているなら検索しない（RDB の bookwalker_id を使う）。"""
    if series_id:
        d = _bw_series(series_id, refresh)
        return [d] if d.get("題名") or d.get("巻") else []
    if not q.strip():
        return []
    body = _fetch(f"{BW}/search/?word=" + urllib.parse.quote(q),
                  bucket="bookwalker", ua=UA_WEB, refresh=refresh) or ""
    out, seen = [], set()
    for h in _bw_items(body):
        if not h["series_id"] or h["series_id"] in seen:
            continue
        seen.add(h["series_id"])
        out.append(_bw_series(h["series_id"], refresh))
        if len(out) >= 3:
            break
    return out


def ask(word: str, sources: tuple = NAMES, refresh: bool = False) -> dict:
    """空でも鍵を立てる。鍵が無い＝問うていない、[]＝問うたが見つからなかった。"""
    out = {}
    if "ranobedb" in sources:
        out["ranobedb"] = ranobedb(word, refresh)
    if "bookwalker" in sources:
        bwid = next((r["bookwalker_id"] for r in out.get("ranobedb") or []
                     if r.get("bookwalker_id")), "")
        out["bookwalker"] = bookwalker(word, refresh, series_id=bwid)
    return out


def report() -> str:
    if not failures:
        return ""
    n = "、".join(f"{k} {v} 件" for k, v in sorted(failures.items()))
    return (f"★ 障害で取れなかったものがある（{n}）。"
            f"控えに残していないので、次に走らせれば取り直す")
