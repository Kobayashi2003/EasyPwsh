"""文書とコードの食い違いを探す。

    python check.py

見るもの — 死んだ関数・使わない import・誰も読まない台帳の欄・
書き込まれた絶対パス・行の長さ・末尾空白・壊れたリンク（**アンカーも**）・
記録への参照・文書に載っている命令と引数が実在するか（**逆向きも**）・試験。

**道具か文書を直したら、試験と一緒にこれも通す。**
"""
import ast
import collections
import pathlib
import re
import subprocess
import sys
sys.stdout.reconfigure(encoding="utf-8")

R = pathlib.Path(__file__).resolve().parent.parent
S = R / "scripts"
bad = []


def anchor(h: str) -> str:
    s = h.strip().lower()
    s = re.sub(r"[^\w\s\u3000-\u9fff\uff00-\uffef-]", "", s)
    return re.sub(r"\s+", "-", s.strip())


# 1 死んだ関数・未使用 import
defs, uses = {}, collections.Counter()
for p in S.glob("*.py"):
    t = ast.parse(p.read_text(encoding="utf-8"))
    for n in ast.walk(t):
        if isinstance(n, ast.FunctionDef):
            defs.setdefault(n.name, p.name)
        elif isinstance(n, ast.Name):
            uses[n.id] += 1
        elif isinstance(n, ast.Attribute):
            uses[n.attr] += 1
    imp = {a.asname or a.name.split(".")[0] for n in ast.walk(t)
           if isinstance(n, ast.Import) for a in n.names}
    imp |= {a.asname or a.name for n in ast.walk(t)
            if isinstance(n, ast.ImportFrom) for a in n.names}
    u = {n.id for n in ast.walk(t) if isinstance(n, ast.Name)}
    u |= {n.value.id for n in ast.walk(t)
          if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name)}
    if imp - u - {"annotations"}:
        bad.append(f"{p.name}: 未使用 import {sorted(imp - u - {'annotations'})}")
for k, v in defs.items():
    if uses[k] == 0 and not k.startswith("cmd_") and k != "main":
        bad.append(f"{v}: 呼ばれない関数 {k}")

# 2 使われない dataclass の欄
for p in S.glob("*.py"):
    src = p.read_text(encoding="utf-8")
    for m in re.finditer(r"^@dataclass\s*\nclass (\w+):(.*?)(?=\n\S)", src,
                         re.S | re.M):
        for fm in re.finditer(r"^    (\w+):", m.group(2), re.M):
            f = fm.group(1)
            pat = rf"\b{re.escape(f)}\b"
            n = sum(len(re.findall(pat, q.read_text(encoding="utf-8")))
                    for q in S.glob("*.py"))
            if n <= 2:      # 宣言と from_dict だけ
                bad.append(f"{p.name}: {m.group(1)}.{f} が誰にも読まれない（{n} 箇所）")

# 2.5 書き込まれた絶対パス（置き場は .env から引くのが決まり）
#     除く: test.py の作り物、paths.py の ITEMS（そこが既定値の置き場）
for p in R.rglob("*.py"):
    if "var" in p.parts or "__pycache__" in p.parts or p.name == "test.py":
        continue
    src = p.read_text(encoding="utf-8")
    if p.name == "paths.py":
        src = re.sub(r"ITEMS = \[.*?\n\]", "", src, flags=re.S)
    for i, l in enumerate(src.splitlines(), 1):
        if re.search(r'["\'][A-Za-z]:[\\/]', l) \
                and not l.lstrip().startswith("#"):
            bad.append(f"{p.name}:{i} 絶対パスが書き込まれている: {l.strip()[:60]}")

# 3 書式
for p in list(R.rglob("*.py")) + list(R.rglob("*.md")):
    txt = p.read_text(encoding="utf-8")
    if p.suffix == ".py":
        for i, l in enumerate(txt.splitlines(), 1):
            if len(l) > 88:
                bad.append(f"{p.name}:{i} 88 桁超")
    if any(l != l.rstrip() for l in txt.splitlines()):
        bad.append(f"{p.name}: 末尾空白")
    if "\t" in txt:
        bad.append(f"{p.name}: タブ")
    if not txt.endswith("\n"):
        bad.append(f"{p.name}: 末尾改行なし")

# 4 リンク（ファイルとアンカーの両方）
for p in R.rglob("*.md"):
    txt = p.read_text(encoding="utf-8")
    heads = {anchor(m.group(1)) for m in re.finditer(r"^#{1,6}\s+(.+)$", txt, re.M)}
    for m in re.finditer(r"\]\(([^)]+)\)", txt):
        tgt = m.group(1)
        if tgt.startswith(("http", "mailto")):
            continue
        f, _, a = tgt.partition("#")
        if f and not (p.parent / f).exists():
            bad.append(f"{p.name}: 壊れたリンク {f}")
        elif not f and a and a not in heads:
            bad.append(f"{p.name}: 壊れたアンカー #{a}")

# 5 記録への参照
files = {f.name for f in (R / "記録").iterdir()}
for p in list(S.glob("*.py")) + [R / "SKILL.md"]:
    for m in re.finditer(r"記録/([^\s）)、。]+\.(?:md|jsonl))",
                         p.read_text(encoding="utf-8")):
        if m.group(1) not in files:
            bad.append(f"{p.name}: 記録に無い {m.group(1)}")

# 6 文書の命令・引数
cli = (S / "cli.py").read_text(encoding="utf-8")
mo = (S / "mori.py").read_text(encoding="utf-8")
have = set(re.findall(r'add_parser\("([^"]+)"', cli + mo))
flags = set(re.findall(r'add_argument\("(--[\w-]+)"', cli + mo))
sk = (R / "SKILL.md").read_text(encoding="utf-8")
for m in re.finditer(r"scripts/(?:cli|mori)\.py (\w+)", sk):
    if m.group(1) not in have:
        bad.append(f"SKILL.md: 無い命令 {m.group(1)}")
for f in set(re.findall(r"(--[a-z][\w-]*)", sk)):
    if f not in flags:
        bad.append(f"SKILL.md: 無い引数 {f}")
# 逆向き: あるのに文書に無い引数
for f in flags:
    if f not in sk and f not in ("--verbose", "--refresh", "--show",
                                 "--include-pending", "--all", "--online",
                                 "--isbn", "--force", "--no-isbn"):
        bad.append(f"cli.py: 文書に載っていない引数 {f}")

r = subprocess.run([sys.executable, str(S / "test.py")], capture_output=True,
                   text=True, encoding="utf-8", errors="replace")
if r.returncode:
    bad.append("試験が落ちている")
print(r.stdout.strip().splitlines()[-1])
print(f"\n見つかったもの {len(bad)} 件")
for b in bad:
    print("  ★", b)
