```
 _______    ________   ________        ___    ___
|\  ___ \  |\   __  \ |\   ____\      |\  \  /  /|
\ \   __/| \ \  \|\  \\ \  \___|_     \ \  \/  / /
 \ \  \_|/__\ \   __  \\ \_____  \     \ \    / /
  \ \  \_|\ \\ \  \ \  \\|____|\  \     \/  /  /
   \ \_______\\ \__\ \__\ ____\_\  \  __/  / /
    \|_______| \|__|\|__||\_________\|\___/ /
                         \|_________|\|___|/
 ________   ___       __    ________   ___  ___
|\   __  \ |\  \     |\  \ |\   ____\ |\  \|\  \
\ \  \|\  \\ \  \    \ \  \\ \  \___|_\ \  \\\  \
 \ \   ____\\ \  \  __\ \  \\ \_____  \\ \   __  \
  \ \  \___| \ \  \|\__\_\  \\|____|\  \\ \  \ \  \
   \ \__\     \ \____________\ ____\_\  \\ \__\ \__\
    \|__|      \|____________||\_________\\|__|\|__|
                              \|_________|



                                       _            _                                _      _
                                      | | __  ___  | |__    __ _  _   _   __ _  ___ | |__  (_)
                         _____        | |/ / / _ \ | '_ \  / _` || | | | / _` |/ __|| '_ \ | |
                        |_____|       |   < | (_) || |_) || (_| || |_| || (_| |\__ \| | | || |
                                      |_|\_\ \___/ |_.__/  \__,_| \__, | \__,_||___/|_| |_||_|
                                                                  |___/
```

# Project structure

`easy-pwsh.ps1 -i` hooks `core/init.ps1` into your `$PROFILE`; every session then
runs the loader, which wires up the pieces below in order.

Listed in load order:

| Path | Purpose |
|------|---------|
| `core/` | The loader; sources everything and builds `PATH`. |
| `start/` | Base shell environment. |
| `apps/` | Installs and initializes external CLI tools. |
| `modules/` | Loads third-party PowerShell modules. |
| `functions/` | In-session helper functions. |
| `utils/` | Standalone scripts, callable by name and grouped by author. |
| `test/` | Scratch scripts. |
| `config/` | Configs for the bundled tools. |

# Usage

- Before you start, you should set your ExecutionPolicy to `RemoteSigned` or `AllSigned`:

```powershell
set-executionpolicy -scope currentuser -executionpolicy remotesigned
# or
set-executionpolicy -scope currentuser -executionpolicy allsigned
```

- Then download easy-pwsh to your local directory, and run it:

```powershell
> cd easy-pwsh
> ./easy-pwsh.ps1 -i
```

# Remote (clone-free) usage

On a fresh machine you can use the `utils` scripts without cloning the repo. Run the bootstrap once, then call any util by name — its script is downloaded from GitHub on first use, cached on disk, and run like a local script (a proxy, RPC-style):

```powershell
# Lazy (default): nothing is defined up front; an unknown util is
# resolved against the manifest and fetched on first call.
irm https://raw.githubusercontent.com/Kobayashi2003/EasyPwsh/main/remote-init.ps1 | iex

moon          # downloaded + cached + run on first call; instant afterwards
```

```powershell
# Discoverable: pre-defines a lightweight proxy for every util so
# Get-Command and tab-completion list them immediately (bodies still
# download lazily on first call).
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Kobayashi2003/EasyPwsh/main/remote-init.ps1))) -Discoverable
```

Notes:

- Pin a version with `-Ref <commit-sha|tag>` (or `$env:EZ_REF`) for reproducible, trusted downloads. This executes remote code, so prefer a commit SHA you trust.
- Scripts are cached under `%LOCALAPPDATA%\EasyPwsh\cache\<ref>`.
- The available utils come from `utils/manifest.json`, regenerated with `utils/build-manifest.ps1`.