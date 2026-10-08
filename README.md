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

# PowerShell compatibility

EasyPwsh supports Windows PowerShell 5.1 and PowerShell 7.x on Windows.
Scripts use UTF-8 with BOM; keep this encoding when editing them. Prediction
and optional features are enabled according to engine, module and host capabilities.

Run the compatibility suites in fresh processes:

```powershell
./tests/Invoke-CompatibilityTests.ps1
# For a portable PowerShell 7 that is absent from PATH:
./tests/Invoke-CompatibilityTests.ps1 -PowerShell7Path 'C:\tools\pwsh\pwsh.exe'
```

Both engines are required by default. Use `-AllowMissingEngine` for explicitly
incomplete validation. Existing profiles are backed up before modification;
for a BOM-less non-ASCII profile, specify its known encoding with
`./easy-pwsh.ps1 -i -ProfileEncoding UTF8` (or `ANSI` / a code page name).

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
