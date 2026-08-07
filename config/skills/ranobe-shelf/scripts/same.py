"""同定 — この実体は**台帳のどの巻か**を突き合わせる。**判断しない**。

置き場から来た一冊が、既に棚に在る巻と同じものかどうか。特典なら
どの巻に付くものか。どちらも「照らして一つに絞れたか」だけを返し、
**絞れなければ絞れないと言う**。推測はしない。

ここに在って良いもの / 良くないもの
--------------------------------
    良い   完全一致・ISBN・（作品, 巻号）といった**照らせば決まる**突合
           規則 7-4 のような**文書に書いてある**優先順位
    良くない  証拠の強さの見積り、閾値、「たぶんこれだろう」
           — それは人と AI が材料を見て決めること（記録/1-壊れ方.md 1-9）

★ 前方一致も編集距離も使わない。同じ作品の巻はどれも頭が同じなので、
  前方一致は**必ず別の巻を掴む**。九件の取り違えはその形だった。

★ 突合の順は **強い証拠から**:
      ① ISBN            一冊を名指しする
      ② 作品 と 巻号     源が同じ巻だと言っている
      ③ 題名の完全一致   ①②が無い古い行のための最後の砦
  ①が有るのに②③を見る必要は無い。逆に①が無いことは珍しくない
  （棚の古い行は ISBN を持たないことがあり、物語シリーズ 24 冊が
  まるごとそれで二重に書かれた）。
"""

from __future__ import annotations

import re
import unicodedata

import mori as M

def key(title: str) -> str:
    """突合に使う題名の鍵。**杜を引くときと同じ揃え方**を使う。

    別々の揃え方を持つと、杜では当たるのに台帳では当たらない、という
    食い違いが出る（記録/1-壊れ方.md 五章 — 同じ規則が二か所にある）。
    """
    return M._debracket(M._shape(M.norm(M.strip_decor(title or "", None))))


# 題名に**印刷されている**巻号。副題の手前まで見る
_SUB = re.compile(r"[~〜―—].*$")
_PRINTED = re.compile(r"[#＃]?\s*(\d{1,3}(?:\.\d)?)\s*(?:$|[ 　])")


def printed_number(title: str):
    """題名に印刷された巻号を読む。無ければ None。

    ★ これは `巻号`（RanobeDB の順＝作品の中での位置）とは**別物**。
      「ようこそ実力至上主義の教室へ 3年生編３」は表紙が 3 で巻号が 32、
      「声優ラジオのウラオモテ #15」は表紙が 15 で巻号が 16。
      特典に書かれている数字は**表紙の数字**なので、こちらと比べる
      （記録/1-壊れ方.md 5-8）。
    """
    return head_number(title)[1]


def head_number(title: str) -> tuple:
    """`(巻号より手前の頭, 表紙の巻号)` に割る。巻号が無ければ `(題名, None)`。

        「声優ラジオのウラオモテ #15 夕陽とやすみは隠しきれない！」
            -> ("声優ラジオのウラオモテ", 15.0)
        「幼馴染たちが人気アイドルになった２ ～甘々な彼女たちは～」
            -> ("幼馴染たちが人気アイドルになった", 2.0)

    ★ 頭だけで**巻を決めてはいけない**。同じ作品の巻はどれも頭が同じ。
      これは特典の親を探すときに、巻号と**組にして**使うためのもの。
    """
    t = _SUB.sub("", unicodedata.normalize("NFKC", title or "")).strip()
    m = _PRINTED.search(t)
    if not m:
        return t, None
    head = t[:m.start()].strip()
    head = re.sub(r"[#＃]\s*$", "", head).strip()
    return head, float(m.group(1))


def index(vols: list) -> dict:
    """台帳の巻を、三つの引き方で引けるようにする。

    `vols` は**統合済みを除いた**巻の一覧を渡すこと。統合した行を混ぜると、
    畳んだはずの巻に実体が戻る。
    """
    by_isbn, by_num, by_title, by_head = {}, {}, {}, {}
    for v in vols:
        if v.ISBN:
            by_isbn.setdefault(v.ISBN, v)
        if v.作品 and v.巻号 is not None and v.種類 == "本篇":
            by_num.setdefault((v.作品, float(v.巻号)), v)
        k = key(v.題名)
        if k:
            by_title.setdefault(k, []).append(v)
        # ★ 副題を落とした**緩い**引き方。**`parent_of` だけ**が使う。
        #   これで巻を決めてはいけない — 副題を落とすと同じ作品の
        #   第 3・6・12 巻が一つの鍵に潰れる（台帳 3,080 巻で 108 組が
        #   そうなった）。巻号と組にして初めて一冊に絞れる
        h = key(head_number(v.題名)[0])
        if h:
            by_head.setdefault(h, []).append(v)
    return {"isbn": by_isbn, "num": by_num, "title": by_title, "head": by_head}


def volume_of(idx: dict, isbn: str = "", work: str = "", num=None,
              title: str = "") -> tuple:
    """台帳のどの巻かを返す。`(巻 or None, どの証拠で当たったか)`。

    絞れなければ `(None, 理由)`。**候補を並べて返さない** — 候補が二つ
    在るということは決められないということで、選ぶのは人。
    """
    if isbn:
        v = idx["isbn"].get(isbn)
        if v is not None:
            return v, "ISBN"
    if work and num is not None:
        v = idx["num"].get((work, float(num)))
        if v is not None:
            return v, "作品と巻号"
    if title:
        c = idx["title"].get(key(title), [])
        if len(c) == 1:
            return c[0], "題名の完全一致"
        if len(c) > 1:
            return None, f"同じ題名の巻が台帳に {len(c)} 冊あり、絞れない"
    return None, "台帳に当たる巻が無い"


def parent_of(idx: dict, head: str, num=None, kind: str = "本篇") -> tuple:
    """特典の**親の巻**を返す。`(巻 or None, 理由)`。

    `head` は特典の名前から切り出した親の題名、`num` は表紙の巻号。

    ★ 親は「たまたま同じ作品の巻」ではなく**その巻**でなければならない。
      題名だけで当てると同じ作品の九冊すべてに当たってしまうので、
      巻号まで書かれているときは**必ず**巻号で絞る。
    """
    k = key(head)
    if not k or len(k) < 4:
        return None, "親の題名を切り出せない（短すぎる）"
    # 題名そのままで当たらなければ、副題を落とした緩い引き方も見る
    cand = [v for v in (idx["title"].get(k) or idx["head"].get(k, []))
            if v.種類 == kind]
    if not cand:
        return None, "台帳に同じ題名の巻が無い（親を持っていない）"
    if num is None:
        if len(cand) == 1:
            return cand[0], "題名の完全一致"
        return None, f"巻号が書かれておらず、同じ題名の巻が {len(cand)} 冊"
    hit = [v for v in cand if printed_number(v.題名) == num]
    if len(hit) == 1:
        return hit[0], "題名と表紙の巻号"
    if hit:
        return None, f"表紙の巻号 {num:g} の巻が台帳に {len(hit)} 冊"
    return None, f"表紙に巻号 {num:g} と書かれた巻が台帳に無い"


def better(a_path, a_size: int, b_path, b_size: int) -> bool:
    """規則 7-4 — 同じ巻の実体が二つあるとき、a を採るなら True。

        ① epub を優先する（他の形は棚に並べても開けないことがある）
        ② 大きい方を採る（画像の解像度・挿絵の有無で差が出る）
        ③ それでも同じなら先に在った方（b）を動かさない

    ★ ここに「新しい方」は入れない。配信し直しで日付だけ新しい、
      中身の薄い版が出回っている（実測 — 同じ巻で 1/4 の字数の
      試し読みが「新しい版」として来たことがある）。
    """
    ae = str(a_path).lower().endswith(".epub")
    be = str(b_path).lower().endswith(".epub")
    if ae != be:
        return ae
    return a_size > b_size
