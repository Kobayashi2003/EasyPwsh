# computer-use memory

Notes about **this machine** and **the apps on it**. Only this file and `.gitignore` are tracked —
everything else is local (see `.gitignore`, and note that this repo's origin is public).

Read them with `-Action profile`, which prints live detection **and** these notes side by side and
shouts when they disagree. That cross-check is the point: a note that has rotted gets caught by the
detector rather than believed.

## What belongs here — all three, or it doesn't go in

1. **Live detection can't find it.** Monitor layout, DPI, current IME mode, running processes,
   window rects: `profile` measures these every run at ~zero cost. Recording them just creates
   something that can go stale and lie. (The design notes for this skill recorded the OS as
   Windows 10; the machine was Windows 11. It was wrong before it was ever saved.)
2. **It isn't general knowledge.** "A key combo must go in one `SendInput` call", "Chromium builds
   its accessibility tree on first AT connection" — true everywhere, so they belong in `SKILL.md`
   and in code comments, which *are* version-controlled. Filling this directory with general
   knowledge is the standard way a memory system rots.
3. **Not knowing it makes you repeat a mistake.** The value of a note is the number of times it
   stops you re-learning something the hard way. "Interesting but harmless" is not enough.

The sweet spot is **app-level quirks**: a custom `keybindings.json` in Cursor/VS Code, a vim
extension in Chrome swallowing bare letters, a shortcut the app itself eats. Those are invisible to
detection, they bite on every fresh session, and they fail *silently*.

System-wide remappings usually do **not** qualify: PowerToys Keyboard Manager, for one, ignores
injected input entirely, so its bindings cannot affect this skill.

## Format

```markdown
---
scope: machine          # machine | app
match: chrome           # app only: regex tried against find-window's Process and Title
updated: 2026-08-08
---

- ✓ 08-08 <fact confirmed by an experiment>
- ? 08-08 <observed, not explained>
- ~ 08-08 <inferred, not tested>

## Detail
Evidence, and how to reproduce it.

## Invalidated by
What would make the entries above false.
```

`profile` prints the front matter plus the bullets above the first `##`. Detail is read on demand.

| Mark | Meaning | Safe to act on |
|---|---|---|
| `✓` | An experiment confirmed it | yes |
| `?` | Seen, not explained | **no — reproduce it first** |
| `~` | Inferred, untested | **no** |

`?` and `~` are the whole defence. While fixing this skill, three plausible-sounding mechanisms were
written down as fact and all three were wrong; a fourth was found only by printing the parsed value.
Had those been saved as `✓`, they would be three actively harmful notes today.

## Writing rules

1. Write `✓` only after the diagnosis is confirmed **and** the fix is verified. First encounter is `?`.
2. One fact per bullet. Update the existing bullet; don't append a near-duplicate.
3. **A note you discover is wrong gets deleted, not annotated.** A wrong memory is worse than none.
4. App files are named by a slug you choose; matching is by the `match:` regex, so `code.md` and
   `cursor.md` can coexist even though both processes are called `Code`.
