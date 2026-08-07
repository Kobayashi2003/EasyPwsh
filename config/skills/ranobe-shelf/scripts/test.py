"""道具が壊れていないか確かめる。**仮の場所だけを使う。網にも触らない。**

    python test.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

bad = []
total = 0


def check(note, got, want=True):
    global total
    total += 1
    ok = got == want
    if not ok:
        bad.append(note)
    print(f"{'ok ' if ok else 'NG '} {note}")
    if not ok:
        print(f"       得 {got!r}\n       期 {want!r}")


def unit():
    import epub as E
    import ledger as L
    import mori as M
    import place as P

    print("# 状態は時間の関数")
    T = date(2026, 8, 5)
    check("完結は最終巻を見ない",
          L.state_of(L.Work("w", 完結=True, 最終巻="200001"), T), "3. 完結")
    check("★ 12 か月以内は連載中",
          L.state_of(L.Work("w", 最終巻="20250910"), T), "1. 連載中")
    check("★ 12 か月を過ぎたら打ち切り",
          L.state_of(L.Work("w", 最終巻="20250307"), T), "2. 打ち切り")
    check("ちょうど 12 か月は連載中",
          L.state_of(L.Work("w", 最終巻="20250805"), T), "1. 連載中")
    check("13 か月は打ち切り",
          L.state_of(L.Work("w", 最終巻="20250705"), T), "2. 打ち切り")
    check("最終巻が無ければ未分類",
          L.state_of(L.Work("w"), T), "4. 未分類")
    check("作品そのものが無ければ未分類", L.state_of(None, T), "4. 未分類")
    check("yymmdd でも読める",
          L.state_of(L.Work("w", 最終巻="250910"), T), "1. 連載中")

    print("\n# 置き場の決まり方")
    import paths as P0
    check("三つある", [k for k, *_ in P0.ITEMS], ["shelf", "inbox", "var"])
    check("環境変数の名前", [e for _, e, *_ in P0.ITEMS],
          ["RANOBE_SHELF", "RANOBE_INBOX", "RANOBE_VAR"])
    check("★ .env は var の外に置く（var 自身がそこに書いてある）",
          P0.ENV_FILE.parent.name, "ranobe-shelf")
    var_default = dict((k, old) for k, _, _, _, old in P0.ITEMS)["var"]
    check("   作業の既定はスキルの直下",
          Path(var_default).parent, P0.ENV_FILE.parent)
    gi = P0.ENV_FILE.parent / ".gitignore"
    check("★ その var は .gitignore で外してある",
          gi.exists() and "var/" in gi.read_text(encoding="utf-8"))
    check("   .env も外してある",
          gi.exists() and "\n.env\n" in gi.read_text(encoding="utf-8"))
    src = P0.ENV_FILE.read_text(encoding="utf-8") if P0.ENV_FILE.exists() else ""
    check("   注釈が付いている（人が直に開いて直せる）", "#" in src)

    # ★ 外の環境に頼らず、その場で作って確かめる
    keep = os.environ.get("RANOBE_VAR")
    try:
        os.environ["RANOBE_VAR"] = r"C:\これは環境変数の値"
        check("★ 環境変数が .env より優先される",
              str(P0.get("var")), r"C:\これは環境変数の値")
        os.environ.pop("RANOBE_VAR")
        in_env = P0.load().get("var")
        check("   環境変数が無ければ .env を読む",
              str(P0.get("var")) if in_env else None,
              in_env if in_env else None)
    finally:
        if keep is None:
            os.environ.pop("RANOBE_VAR", None)
        else:
            os.environ["RANOBE_VAR"] = keep
    check("   注釈の行は設定として読まない", P0.load().get("#"), None)

    print("\n# 台帳")
    v = L.Vol("V1", "甲", "GA文庫", "塩本", "秋乃える", "240809")
    check("タグは レーベル 著者 絵師 発売日 の順",
          v.tags(), ["GA文庫", "塩本", "秋乃える", "240809"])
    check("★ 著者が無ければ絵師を繰り上げない",
          L.Vol("V1", "甲", "GA文庫", "", "秋乃える", "240809").tags(),
          ["GA文庫", "240809"])
    check("鍵は巻ID そのもの（暗黙に衝突しない）", v.key(), "V1")
    try:
        L.decision("agent", " ")
        check("★ agent の判断は理由なしを拒む", False)
    except ValueError:
        check("★ agent の判断は理由なしを拒む", True)
    check("源の判断は理由が要らない", L.decision("mori", "")["by"], "mori")

    print("\n# 名前の揃え方")
    check("★ 全角数字は半角へ", P.safe("家事代行２"), "家事代行2")
    check("★ 全角英字は半角へ", P.safe("恋愛ＲＰＧ"), "恋愛RPG")
    check("★ 全角記号は半角へ", P.safe("Ｎｏ．１！"), "No.1!")
    check("半角カナは全角へ（NFKC）", P.safe("ｶﾞﾝﾀﾞﾑ"), "ガンダム")
    check("波ダッシュを揃える", P.safe("あ〜い～う"), "あ~い~う")
    check("★ 長音符は日本語の字。潰さない", P.safe("コーヒー"), "コーヒー")
    check("★ Windows が拒む字は似た全角へ逃がす",
          P.safe("これはゾンビですか?"), "これはゾンビですか？")
    check("   9 字ぜんぶ", P.safe('a\\b/c:d*e?f"g<h>i|j'),
          "a＼b／c：d＊e？f”g＜h＞i｜j")
    check("   全角で来ても全角のまま揃う", P.safe("これはゾンビですか？"),
          "これはゾンビですか？")
    check("制御文字を落とす", P.safe("あ\x01い"), "あい")
    check("末尾の点と空白は落とす", P.safe("題名. "), "題名")
    check("★ 揃えると何も残らない題名がある", P.safe(".."), "")
    check("平らな名前", P.file_name(v, ".epub"),
          "[GA文庫][塩本][秋乃える][240809] 甲.epub")
    check("タグを読む", P.tags_of("[GA文庫][塩本][秋乃える][240809] 甲.epub"),
          ["GA文庫", "塩本", "秋乃える", "240809"])
    check("★ 削除という種類は無い",
          any("知らない種類" in x
              for x in P.check([P.Op("削除", "/x", "/y", "V1")])))
    check("★ 元が無い移動は門①が弾く",
          any("元が無い" in x for x in P.check([P.Op(P.MOVE, "", "/x/a.epub", "V1")])))
    check("根拠の無い操作は弾く",
          any("根拠が無い" in x
              for x in P.check([P.Op(P.MOVE, "/x/a.epub", "/y/a.epub", "")])))
    check("★ 門② タグの数が減る付け直しを弾く",
          any("タグが" in x for x in P.check_format(
              [P.Op(P.RENAME, r"C:\a\[文庫][著者][絵師][240809] 甲.epub",
                    r"C:\a\[文庫][著者][240809] 甲.epub", "V1")])[0]))
    check("   タグが増えるのは通す",
          P.check_format([P.Op(P.RENAME, r"C:\a\[文庫][240809] 甲.epub",
                               r"C:\a\[文庫][著者][240809] 甲.epub",
                               "V1")])[0], [])
    check("★ 日付が入れ替わるのは減ったことにしない",
          P.check_format([P.Op(P.RENAME, r"C:\a\[180511] 甲.epub",
                               r"C:\a\[文庫][著者][絵師][181010] 甲.epub",
                               "V1")])[0], [])
    check("★ 日付が消えるのは止める",
          any("日付が消える" in x for x in P.check_format(
              [P.Op(P.RENAME, r"C:\a\[文庫][240809] 甲.epub",
                    r"C:\a\[文庫] 甲.epub", "V1")])[0]))
    # ★ 値が入れ替わるのは正しいことの方が多い（B6判 → KADOKAWA、実測-26）。
    #   止めずに「知らせる」方へ出す
    _swap = [P.Op(P.RENAME, r"C:\a\[B6判][著者][絵師][240809] 甲.epub",
                  r"C:\a\[KADOKAWA][著者][絵師][240809] 甲.epub", "V1")]
    check("★ 値が入れ替わるだけなら止めない", P.check_format(_swap)[0], [])
    # ★ [000000] は旧い流れの「分からない」のしるし。日付でも書誌でもない
    #   空札なので、落としても門②は何も言わない
    check("★ [000000] は日付にも書誌にも数えない",
          P.check_format([P.Op(P.RENAME, r"C:\a\[000000] 甲.epub",
                               r"C:\a\甲.epub", "V1")])[0], [])
    check("   ちゃんとした日付が消えるのは止める",
          any("日付が消える" in x for x in P.check_format(
              [P.Op(P.RENAME, r"C:\a\[150427] 甲.epub",
                    r"C:\a\甲.epub", "V1")])[0]))
    check("   その入れ替わりは知らせる方に出る",
          any("B6判" in x for x in P.check_format(_swap)[1]))
    check("★ 門③ 印が違えば止まる",
          any("台帳が変わっている" in x for x in P.check_fresh("0:ちがう")))

    # 入れ替え: B の行き先を A が塞いでいる。A を先に退かせば通る
    swap = [P.Op(P.MOVE, r"C:\新\b.epub", r"C:\棚\x.epub", "V1"),
            P.Op(P.MOVE, r"C:\棚\x.epub", r"C:\隔離\x.epub", "V1")]
    order, cyc = P.order_ops(swap)
    check("★ 塞いでいる相手を先に動かす", order[0].元, r"C:\棚\x.epub")
    check("   堂々巡りでなければ報告しない", cyc, [])
    _, cyc2 = P.order_ops([P.Op(P.MOVE, "/a", "/b", "V1"),
                           P.Op(P.MOVE, "/b", "/a", "V2")])
    check("★ 堂々巡りは動かさずに報告する",
          any("堂々巡り" in x for x in cyc2))

    print("\n# 杜の解析")
    HTML = """<div class="entry"><h2 class="entry-header"><a>GA文庫</a></h2>
    <div class="entry-content"><table class="book-list11">
    <tr class="book-header"><th>発売日</th><th>タイトル</th><th>著者</th>
      <th>イラスト</th><th>定価</th><th>ISBN</th></tr>
    <tr class="book-info"><td>9</td><td><a>家事代行２</a></td><td>塩本</td>
      <td>秋乃える</td><td>858</td><td>978-4-8156-2585-6</td></tr>
    <tr class="book-info"><td>9</td><td><a>電子だけの本('25/03より延期)</a></td>
      <td>甲</td><td>乙</td><td>1430</td><td>電子専売</td></tr>
    <tr class="book-header"><th>GAノベル</th></tr>
    <tr class="book-info"><td>20</td><td><a>別レーベルの本</a></td><td>丙</td>
      <td>丁</td><td>1320</td><td>978-4-8156-1111-1</td></tr>
    </table></div></div>"""
    rows = M.parse(HTML, "2024/08")
    check("三行とも取れる", len(rows), 3)
    check("列は名前で対応づく", rows[0]["author"], "塩本")
    check("絵師が独立して取れる", rows[0]["artist"], "秋乃える")
    check("ISBN の区切りを落とす", rows[0]["isbn"], "9784815625856")
    check("発売日は年月＋日", rows[0]["date"], "240809")
    # ★ 発売日のセルは素直な数字とは限らない（実測 2,044 件が複合値）
    check("★ 月をまたぐ表記 8/29 を 829 に潰さない",
          M._date("2008", "09", "8/29"), "080829")
    check("   12 月の頁の 1/10 は翌年", M._date("2008", "12", "1/10"), "090110")
    check("   全角の区切りも読む", M._date("2008", "09", "8／29"), "080829")
    check("★ 読めない日は 00（桁を崩さない）",
          M._date("2008", "09", "8・29・30"), "080900")
    check("   空でも 6 桁", M._date("2008", "09", ""), "080900")
    check("   在り得ない日は 00", M._date("2008", "09", "99"), "080900")
    check("★ 見えない制御文字が頭に付いていても読む",
          M._date("2021", "07", "‎16"), "210716")
    check("   区切りの前後にも付く", M._date("2021", "07", "‎6/24"), "210624")
    check("★ 電子専売は欠値ではなく信号", rows[1]["digital_only"])
    check("   そのとき ISBN は空", rows[1]["isbn"], "")
    check("延期の履歴を題名から外す", rows[1]["title"], "電子だけの本")
    check("   履歴は残す", rows[1]["delayed"], "'25/03より延期")
    check("★ 途中の見出しで小レーベルに切り替わる", rows[2]["label"], "GAノベル")
    check("   それより前は親レーベルのまま", rows[0]["label"], "GA文庫")

    got = M.find("家事代行２", rows)
    check("完全一致は一致として返る", len(got["exact"]), 1)
    check("   そのとき示唆は出さない", got["hint"], [])
    got = M.find("家事代行", rows)
    check("★ 部分一致は示唆にしかならない", got["exact"], [])
    check("   短い語では示唆も出さない", M.find("家事", rows)["hint"], [])
    check("ISBN で引ける", len(M.by_isbn("978-4-8156-2585-6", rows)), 1)
    check("★ 山括弧の書き方を揃える（NFKC は半分しか揃えない）",
          M.norm("〈Infinite Dendrogram〉"), M.norm("＜Infinite Dendrogram＞"))
    check("   《》≪≫«» も同じ扱い",
          M.norm("《甲》"), M.norm("≪甲≫"))
    check("   中身は区別する", M.norm("〈甲〉") == M.norm("〈乙〉"), False)
    check("★ 受賞の但し書きは棚に出さない",
          M.title_of({"title": "ムーンスペル!![第16回ファンタジア長編小説大賞＜佳作＞]"}),
          "ムーンスペル!!")
    check("   本物の角括弧は残す",
          M.title_of({"title": "俺の【日記帳】を読んで秘密を知ったらしい"}),
          "俺の【日記帳】を読んで秘密を知ったらしい")
    check("   末尾以外の括弧は触らない",
          M.title_of({"title": "[電子版] 甲"}), "[電子版] 甲")

    print("\n# 読み取り")
    check("ISBN の区切りを落とす",
          E.find_isbn("ISBN978-4-04-865042-1"), "9784048650421")
    oku = E._colophon([("OEBPS/p-colophon.xhtml", (
        "<p>電撃文庫『86―エイティシックス―』</p>"
        "<p>2017年2月10日 初版発行</p><p>2017年3月17日 電子版発行</p>"
        "<p>ISBN 978-4-04-892535-9</p>"))])
    check("★ 『題名』の直前をレーベルとする", oku["レーベル"], "電撃文庫")
    check("★ 初版が付くほうが紙", oku["紙の日付"], "170210")
    check("★ 付かないほうが電子", oku["電子の日付"], "170317")
    check("語が足りない頁は奥付としない",
          E._colophon([("OEBPS/t01.xhtml", "<p>発行</p>")])["読めた"], False)
    check("名前が目印なら語が少なくても拾う",
          E._colophon([("OEBPS/colophon.xhtml", "<p>発行</p>")])["読めた"])

    # ---------------------------------------------------------- 同定
    import same as SM

    print("\n# 同定 — この実体は台帳のどの巻か")
    V = [L.Vol("V001", "終物語 （上）", "講談社BOX", "西尾維新", "VOFAN",
               "131021", "", "本篇", "rdb:1", 16.0),
         L.Vol("V002", "猫物語 （黒）", "講談社BOX", "西尾維新", "VOFAN",
               "100728", "9784062837484", "本篇", "rdb:1", 7.0),
         L.Vol("V003", "猫物語 （白）", "講談社BOX", "西尾維新", "VOFAN",
               "101027", "", "本篇", "rdb:1", 8.0),
         L.Vol("V004", "声優ラジオのウラオモテ #15 夕陽とやすみは隠しきれない！",
               "電撃文庫", "二月公", "さばみぞれ", "260710", "", "本篇",
               "rdb:2", 16.0),
         L.Vol("V005", "声優ラジオのウラオモテ #16 夕陽とやすみは続きたい!?",
               "電撃文庫", "二月公", "さばみぞれ", "261010", "", "本篇",
               "rdb:2", 17.0)]
    idx = SM.index(V)

    check("ISBN で当たる", SM.volume_of(idx, isbn="9784062837484")[0].巻ID, "V002")
    check("★ ISBN が無い行でも題名で当たる",
          SM.volume_of(idx, title="終物語 (上)")[0].巻ID, "V001")
    check("★ 括弧の有無は同じものとして扱う",
          SM.volume_of(idx, title="終物語 上")[0].巻ID, "V001")
    check("★ 括弧の中身が違えば別の巻のまま",
          SM.volume_of(idx, title="猫物語 (白)")[0].巻ID, "V003")
    check("作品と巻号で当たる",
          SM.volume_of(idx, work="rdb:1", num=7)[0].巻ID, "V002")
    check("当たらなければ None", SM.volume_of(idx, title="存在しない本")[0], None)

    print("# 表紙の巻号と、作品の中での位次は別のもの")
    check("題名に印刷された号を読む",
          SM.printed_number("声優ラジオのウラオモテ #15 夕陽とやすみは隠しきれない！"),
          15.0)
    check("副題の中の数字は拾わない",
          SM.printed_number("嘆きの亡霊は引退したい ～最弱ハンター～"), None)
    check("★ 特典の親は**表紙の号**で決める（巻号 16 の V004 ではない）",
          SM.parent_of(idx, "声優ラジオのウラオモテ", 16.0)[0].巻ID, "V005")
    check("★ 号を書いていなければ、同じ題名が二つ在るとき決めない",
          SM.parent_of(idx, "声優ラジオのウラオモテ")[0], None)
    check("親を持っていなければ決めない",
          SM.parent_of(idx, "持っていない作品の題名", 1.0)[0], None)

    print("# 規則 7-4 — 同じ巻の実体が二つあるとき")
    check("epub を優先する", SM.better("a.epub", 10, "b.pdf", 999999))
    check("同じ形なら大きい方", SM.better("a.epub", 20, "b.epub", 10))
    check("★ 同じ大きさなら先に在った方を動かさない",
          SM.better("a.epub", 10, "b.epub", 10), False)


def make_epub(p: Path, title: str, chars: int = 90000) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(p, "w") as z:
        z.writestr("META-INF/container.xml",
                   '<?xml version="1.0"?><container version="1.0" '
                   'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                   '<rootfiles><rootfile full-path="OEBPS/c.opf" '
                   'media-type="application/oebps-package+xml"/></rootfiles>'
                   '</container>')
        z.writestr("OEBPS/c.opf",
                   f'<?xml version="1.0"?><package version="3.0" '
                   f'xmlns="http://www.idpf.org/2007/opf"><metadata '
                   f'xmlns:dc="http://purl.org/dc/elements/1.1/">'
                   f'<dc:title>{title}</dc:title>'
                   f'<dc:creator>山田太郎</dc:creator></metadata>'
                   f'<manifest><item id="a" href="p%20a.xhtml" '
                   f'media-type="application/xhtml+xml"/></manifest>'
                   f'<spine><itemref idref="a"/></spine></package>')
        z.writestr("OEBPS/p a.xhtml",
                   "<html><body>" + "あ" * chars + "</body></html>")
    return p


def run(env, *args):
    r = subprocess.run([sys.executable, str(HERE / "cli.py"), *args],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=env, cwd=str(HERE))
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def cycle():
    with tempfile.TemporaryDirectory() as d:
        t = Path(d)
        shelf, inbox, var = t / "shelf", t / "inbox", t / "var"
        env = dict(os.environ, RANOBE_SHELF=str(shelf), RANOBE_INBOX=str(inbox),
                   RANOBE_VAR=str(var), PYTHONIOENCODING="utf-8")
        make_epub(inbox / "とある作品 1.epub", "とある作品 1")
        make_epub(inbox / "とある作品 2.epub", "とある作品 2")

        print("\n# 置き場")
        code, out = run(env, "status")
        check("環境変数だけで動く", code, 0)
        check("置き場を数える", "置き場に      2 件" in out)

        print("\n# 材料")
        code, out = run(env, "materials", "--count", "5")
        check("材料が出る", code, 0)
        fp = {}
        for ln in out.splitlines():
            if ln.startswith("── "):
                _, b, c = ln.split(None, 2)
                fp[c.strip()] = b
        check("二冊ぶん出た", len(fp), 2)
        check("URL エンコードされた href の本文を読めている", "90,000字" in out)
        check("★ 調査記録が残る",
              len(list((var / "survey").glob("*.json"))), 2)

        print("\n# 記録")
        for name, num in (("とある作品 1.epub", 1), ("とある作品 2.epub", 2)):
            code, _ = run(env, "record", "--fp", fp[name],
                          "--path", str(inbox / name),
                          "--title", f"とある作品 {num}",
                          "--label", "とある文庫", "--author", "山田太郎",
                          "--artist", "絵師花子", "--date", "230101",
                          "--work", "rdb:99", "--why", "試し")
            check(f"{num} 巻を記録できる", code, 0)
        code, _ = run(env, "work", "rdb:99", "--last", "20260101",
                      "--name", "とある作品", "--why", "試し")
        check("作品の最終巻を書ける", code, 0)

        print("\n# 門")
        code, out = run(env, "plan")
        check("計画が作れる", code, 0)
        check("★ plan はディスクを触らない（隔離を作らない）",
              (var / "quarantine").exists(), False)
        check("移動が二件", "移動 2" in out)
        plan1 = out.split("-> ")[1].splitlines()[0].strip()

        keep = t / "keep.epub"
        shutil.copy2(inbox / "とある作品 1.epub", keep)
        (inbox / "とある作品 1.epub").unlink()
        code, out = run(env, "apply", plan1)
        check("★ 門① 元が無ければ止まる", code, 1)
        check("   止まったときは一件も動いていない",
              (inbox / "とある作品 2.epub").exists())
        shutil.copy2(keep, inbox / "とある作品 1.epub")

        code, _ = run(env, "record", "--fp", "dummy0000", "--title", "特典",
                      "--kind", "特典", "--why", "門③の試し")
        code, out = run(env, "apply", plan1)
        check("★ 門③ 古い計画は流れない", code, 1)
        check("   理由を言う", "台帳が変わっている" in out)

        print("\n# 実行")
        code, _ = run(env, "plan")
        code, out = run(env, "apply")
        check("★ 三つの門を通れば動く", code, 0)
        moved = sorted((shelf / "1. 連載中").rglob("*.epub"))
        check("★ 棚は二段（作品フォルダが無い）", len(moved), 2)
        check("名前が [レーベル][著者][絵師][発売日]",
              moved[0].name.startswith("[とある文庫][山田太郎][絵師花子][230101]"))
        check("置き場は空になった", len(list(inbox.rglob("*.epub"))), 0)

        code, out = run(env, "plan")
        check("★ 二度目の計画は空（path が書き戻っている）", "計画 0 件" in out)

        check("★ 空になったフォルダを畳む",
              (inbox / "とある作品 1.epub").parent == inbox)

        print("\n# 取消")
        up = sorted((var / "undos").glob("*.jsonl"))[-1]
        code, out = run(env, "undo", str(up))
        check("取消が動く", code, 0)
        check("置き場に戻った", len(list(inbox.rglob("*.epub"))), 2)
        check("★ 棚の空フォルダも畳まれる",
              (shelf / "1. 連載中").exists() and
              not any((shelf / "1. 連載中").iterdir()))
        code, out = run(env, "plan")
        check("★ 取消のあとも計画が作れる", "移動 2" in out)

        print("\n# 同じ巻に実体が二つ")
        code, out = run(env, "apply")          # 置き場へ戻した状態から置き直す
        # ★ 中身が違うから指紋も違う。同じ中身の写しは指紋で弾かれる
        make_epub(inbox / "とある作品 1 別版.epub", "とある作品 1", 120000)
        code, out = run(env, "materials", "--count", "5")
        fp2 = {}
        for ln in out.splitlines():
            if ln.startswith("── "):
                _, b, c = ln.split(None, 2)
                fp2[c.strip()] = b
        check("別版が材料に出る", "とある作品 1 別版.epub" in fp2)
        code, out = run(env, "record", "--id", "V000001",
                        "--fp", fp2["とある作品 1 別版.epub"],
                        "--path", str(inbox / "とある作品 1 別版.epub"),
                        "--title", "とある作品 1", "--label", "とある文庫",
                        "--author", "山田太郎", "--artist", "絵師花子",
                        "--date", "230101", "--work", "rdb:99",
                        "--why", "同じ巻の別版")
        check("★ 別版を足しても前の実体が消えない", "実体が 2 個" in out)
        # ★ 同じ path を指す行は置き換わる（指紋を書き間違えて入れ直すとき）
        code, out = run(env, "record", "--id", "V000001",
                        "--fp", "まちがえた指紋",
                        "--path", str(inbox / "とある作品 1 別版.epub"),
                        "--title", "とある作品 1", "--label", "とある文庫",
                        "--author", "山田太郎", "--artist", "絵師花子",
                        "--date", "230101", "--work", "rdb:99",
                        "--why", "指紋を書き間違えた")
        check("★ 同じ path の古い行は置き換わる（増えない）",
              "実体が 3 個" not in out)
        # 元に戻す（後の検めが指紋を見るため）
        run(env, "record", "--id", "V000001",
            "--fp", fp2["とある作品 1 別版.epub"],
            "--path", str(inbox / "とある作品 1 別版.epub"),
            "--title", "とある作品 1", "--label", "とある文庫",
            "--author", "山田太郎", "--artist", "絵師花子",
            "--date", "230101", "--work", "rdb:99", "--why", "戻す")
        code, out = run(env, "plan")
        check("★ 採用しない方は隔離へ向かう", "重複版" in out)
        code, out = run(env, "apply")
        check("   実行できる", code, 0)
        spare = list((var / "quarantine").rglob("*.epub"))
        check("   隔離に一つ移った", len(spare), 1)
        check("★ なぜそこに在るかを残す",
              (spare[0].parent / "README.txt").exists() if spare else False)
        check("   名前の頭のタグは残っている",
              spare[0].name.startswith("[とある文庫]") if spare else False)
        check("   棚には採用した方だけ",
              len(list((shelf / "1. 連載中").rglob("*.epub"))), 2)
        code, out = run(env, "plan")
        check("★ 二度目は空（両方の path が書き戻っている）",
              "計画 0 件" in out)

        print("\n# 棚外 — 持っているが棚に並べない")
        v0 = next(iter(json.loads(x) for x in
                       (var / "volumes.jsonl").read_text("utf-8").splitlines()
                       if x.strip()))
        here = next((shelf / "1. 連載中").glob("*.epub"))
        away = inbox / "棚から外したもの" / here.name
        away.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(here), str(away))
        code, out = run(env, "record", "--id", v0["巻ID"], "--fp", "x" * 16,
                        "--path", str(away), "--title", v0["題名"],
                        "--label", v0["レーベル"], "--date", v0["発売日"],
                        "--kind", v0["種類"],
                        "--off-shelf", "作品が引けないので棚に並べない",
                        "--why", "試験")
        check("棚外を付けられる", code, 0)
        code, out = run(env, "plan")
        check("★ 棚外の巻は棚へ引き戻されない", "計画 0 件" in out)
        code, out = run(env, "audit")
        check("★ 検めが棚外の巻を挙げる", "棚に置かないと決めた巻" in out)
        code, out = run(env, "record", "--id", v0["巻ID"], "--fp", "x" * 16,
                        "--path", str(away), "--title", v0["題名"],
                        "--label", v0["レーベル"], "--date", v0["発売日"],
                        "--kind", v0["種類"], "--why", "一欄だけ直す")
        code, out = run(env, "plan")
        check("★ 書き直しても棚外は落ちない（承知と同じ）", "計画 0 件" in out)
        shutil.move(str(away), str(here))

        print("\n# 検め")
        code, out = run(env, "audit")
        check("audit が動く", code, 0)
        check("其他 の節が出る", "其他" in out)
        check("   写しの節も出る", "中身の写し" in out)
        # ★ 置いたあとは plan が何も言わないので、消えた本はここでしか出ない
        victim = next((shelf / "1. 連載中").glob("*.epub"))
        keep2 = t / "victim.epub"
        shutil.copy2(victim, keep2)
        victim.unlink()
        code, out = run(env, "plan")
        check("★ 置いたあとに消えた本は plan には出ない", "計画 0 件" in out)
        code, out = run(env, "audit")
        check("★ audit が「台帳にあるのに実体が無い」を見つける",
              "台帳にあるのに実体が無い" in out and "（採用）" in out)
        shutil.copy2(keep2, victim)
        shutil.copy2(next((shelf / "1. 連載中").glob("*.epub")),
                     inbox / "まったく同じ写し.epub")
        code, out = run(env, "audit")
        check("★ 置き場に残る同じ中身の写しを見つける",
              "まったく同じ写し.epub" in out)


if __name__ == "__main__":
    unit()
    cycle()
    print(f"\n{'★ 失敗 ' + str(len(bad)) if bad else '全部通った'}"
          f"（{total} 件）")
    for x in bad:
        print("   " + x)
    raise SystemExit(1 if bad else 0)
