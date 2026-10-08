# Run in a fresh -NoProfile process; no Pester or network dependency.
[CmdletBinding()]
param([string]$PSReadLineVersion, [switch]$ModuleOnly, [int]$ExpectedMajor, [switch]$StartupOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$global:CURRENT_SCRIPT_DIRECTORY = $root
# Load only function definitions; do not run initialization or request elevation.
foreach ($helper in @(
    @{ Path = 'easy-pwsh.ps1'; Name = 'Set-EasyPwshProfileStartup' },
    @{ Path = 'apps/init-apps.ps1'; Name = 'global:Invoke-EasyPwshUtf8Command' },
    @{ Path = 'start/sudo.ps1'; Name = 'New-EasyPwshSudoStartInfo' }
)) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $helper.Path), [ref]$tokens, [ref]$parseErrors)
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helper.Name }, $true)
    if (-not $definition) { throw "Missing helper definition: $($helper.Name)" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}
if ($ExpectedMajor) { Assert ($PSVersionTable.PSVersion.Major -eq $ExpectedMajor) 'Unexpected engine version' }
if ($StartupOnly) {
    # Opt-in: application initialization can link user configuration for installed tools.
    . (Join-Path $root 'core/init.ps1')
    Assert ([bool](Get-Module PSReadLine)) 'PSReadLine missing after full startup'
    Assert ([bool](Get-Command cc,sh,uptime -ErrorAction Stop)) 'Core functions missing after full startup'
    Assert ([bool](prompt)) 'Prompt missing after full startup'
    Write-Host "PASS: full core/init.ps1 startup on PS $($PSVersionTable.PSVersion)."
    exit 0
}

if (-not $ModuleOnly) {
    $files = @(Get-ChildItem $root -Recurse -File -Filter *.ps1 |
        Where-Object FullName -NotMatch '\\(\.git|downloads)\\')
    foreach ($file in $files) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "UTF-8 BOM missing: $file"
        [void][IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
        $tokens = $null; $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert ($parseErrors.Count -eq 0) "Parse failed: $file : $($parseErrors.Message -join '; ')"
    }
    Write-Host "Parsed $($files.Count) scripts and checked UTF-8 BOM."
}

& {
    # User configuration may enable Scoop discovery; keep tests independent of it.
    function scoop { [pscustomobject]@{ Name = 'main' } }
    & (Join-Path $root 'start/variables.ps1')
}
$global:IMPORT_MODULES = $true
$global:CHECK_MODULES = $false
$global:MODULE_OPTIONAL_FLAG = $false
Assert ($global:PSVERSION -is [version]) 'Engine version must be a version object'
if ($PSReadLineVersion) {
    $global:MODULES = @{ PSReadLine = "==$PSReadLineVersion" }
}
& (Join-Path $root 'modules/init-modules.ps1')
$module = Get-Module PSReadLine
Assert ($null -ne $module) 'PSReadLine did not load'
if ($PSReadLineVersion) { Assert ($module.Version -eq [version]$PSReadLineVersion) 'Wrong PSReadLine version loaded' }
Assert ([bool](Get-PSReadLineKeyHandler -Bound | Where-Object Key -EQ 'Tab')) 'Tab binding missing'
Assert ((Get-PSReadLineOption).MaximumHistoryCount -eq 100000) 'History options not configured'
Assert ((Get-EasyPwshPredictionSource ([version]'5.1') @('None','History','HistoryAndPlugin') $true) -eq 'History') '5.1 must use history prediction'
Assert ((Get-EasyPwshPredictionSource ([version]'7.0') @('None','History','HistoryAndPlugin') $true) -eq 'History') '7.0 must use history prediction'
Assert ((Get-EasyPwshPredictionSource ([version]'7.2') @('None','History','HistoryAndPlugin') $true) -eq 'HistoryAndPlugin') '7.2 must retain plugin prediction'
Assert ((Get-EasyPwshPredictionSource ([version]'7.6') @('None','History') $true) -eq 'History') 'Old module must fall back to history'
Assert ((Get-EasyPwshPredictionSource ([version]'7.6') @('None','History','HistoryAndPlugin') $false) -eq 'None') 'Redirected host must disable prediction'
Assert ((Get-EasyPwshPredictionSource ([version]'5.1') @('None') $true) -eq 'None') 'Module without prediction must degrade safely'
if ([Console]::IsOutputRedirected -and (Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionSource')) {
    Assert ((Get-PSReadLineOption).PredictionSource.ToString() -eq 'None') 'Prediction still enabled with redirected output'
}
if ($ModuleOnly) {
    Write-Host "PASS: PS $($PSVersionTable.PSVersion), PSReadLine $($module.Version), $script:passed assertions (module only)."
    exit 0
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('EasyPwsh-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$originalLocation = Get-Location
try {
    . (Join-Path $root 'functions/cc.ps1')
    $script:clearCount = 0
    function Clear-Host { $script:clearCount++ }
    $target = Join-Path $sandbox '[Unicode-目录]'
    New-Item -ItemType Directory -Path $target | Out-Null
    cc $target
    Assert ($PWD.Path -eq $target -and $script:clearCount -eq 1) 'cc must handle literal Unicode/bracket paths and clear once'
    $ErrorActionPreference = 'Continue'
    cc (Join-Path $sandbox 'missing') 2>$null
    $ErrorActionPreference = 'Stop'
    Assert ($PWD.Path -eq $target -and $script:clearCount -eq 1) 'cc must not clear after a failed location change'
    cc
    Assert ($PWD.Path -eq $env:USERPROFILE -and $script:clearCount -eq 2) 'cc without arguments must go home'

    & (Join-Path $root 'start/prompt.ps1')
    Assert ($global:__PromptSpecialIcons[$env:USERPROFILE] -ceq ([string][char]0x2302)) 'Home glyph decoded incorrectly'
    Assert ((prompt) -match [regex]::Escape([string][char]0x2302)) 'Prompt must render Unicode home glyph'

    . (Join-Path $root 'functions/sh.ps1')
    $childVersion = sh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    Assert ($LASTEXITCODE -eq 0 -and $childVersion -eq $PSVersionTable.PSVersion.ToString()) 'sh must launch the current engine even when absent from PATH'

    . (Join-Path $root 'functions/uptime.ps1')
    # A fixed DateTime fixture catches accidental parsing of localized net output.
    function Get-CimInstance { param($ClassName) [pscustomobject]@{ LastBootUpTime = (Get-Date).AddHours(-1) } }
    $uptimeText = uptime 6>&1 | Out-String
    Assert ($uptimeText -match 'Uptime: 0 days, 1 hours') 'uptime must accept CIM DateTime'
    Remove-Item Function:\Get-CimInstance

    $global:__RECORD_FILE = Join-Path $sandbox 'record.txt'
    [IO.File]::WriteAllText($global:__RECORD_FILE, '', [Text.Encoding]::UTF8)
    $global:__RECORDING = $true
    $handler = (Get-PSReadLineOption).AddToHistoryHandler
    [void]$handler.Invoke("Write-Host '中文'`nGet-Date")
    [void]$handler.Invoke("Write-Host '中文'`nGet-Date")
    $global:__RECORDING = $false
    $recorded = @(__record_read)
    Assert ($recorded.Count -eq 2 -and $recorded[0] -ceq "Write-Host '中文'`nGet-Date" -and $recorded[0] -ceq $recorded[1]) 'Recording must preserve Unicode, newlines and duplicate commands'

    # Exercise the comparison function without the standalone script's exit.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'utils/kobayashi/compare-files.ps1'), [ref]$tokens, [ref]$parseErrors)
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-StringSimilarity' }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    Assert ((Get-StringSimilarity 'abc' 'abc') -eq 1) 'Identical file lines must match'
    Assert ([math]::Abs((Get-StringSimilarity 'abc' 'axc') - (2.0 / 3)) -lt 0.00001) 'File similarity matrix calculation failed'

    # Profile, native UTF-8 capture, sudo payload, and runner regressions.
    & {
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('EasyPwsh-native-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
$shellPath = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
try {
    $initPath = Join-Path $sandbox "目录's config\core\init.ps1"
    [void][IO.Directory]::CreateDirectory((Split-Path $initPath -Parent))
    [IO.File]::WriteAllText($initPath, '$script:profileInitCalls++', [Text.Encoding]::UTF8)
    $profilePath = Join-Path $sandbox 'profile.ps1'
    # C2 A9 is legal both as UTF-8 and in several ANSI code pages.
    [byte[]]$ambiguous = [Text.Encoding]::ASCII.GetBytes("# ANSI: ") + [byte[]]@(0xC2,0xA9)
    [IO.File]::WriteAllBytes($profilePath, $ambiguous)
    $rejected = $false
    try { Set-EasyPwshProfileStartup $profilePath $initPath | Out-Null } catch { $rejected = $_ -match 'ambiguous encoding' }
    Assert $rejected 'Ambiguous profile must require explicit encoding'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($profilePath)) -eq [Convert]::ToBase64String($ambiguous)) 'Rejected profile must remain byte-for-byte unchanged'
    $update = Set-EasyPwshProfileStartup $profilePath $initPath -SourceEncoding 'windows-1252'
    Assert ([IO.File]::ReadAllText($profilePath).Contains([Text.Encoding]::GetEncoding(1252).GetString($ambiguous))) 'Explicit ANSI selection must preserve text'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($update.BackupPath)) -eq [Convert]::ToBase64String($ambiguous)) 'Profile backup must preserve original bytes'

    foreach ($encoding in @([Text.UTF8Encoding]::new($false), [Text.Encoding]::Unicode, [Text.Encoding]::BigEndianUnicode)) {
        $body = '$script:profileUnicode = ''中文⌂''' + "`r`n. $initPath`r`n"
        [IO.File]::WriteAllText($profilePath, $body, $encoding)
        $original = [IO.File]::ReadAllBytes($profilePath)
        $sourceEncoding = if ($encoding.CodePage -eq 65001) { 'UTF8' } else { 'Auto' }
        $update = Set-EasyPwshProfileStartup $profilePath $initPath -SourceEncoding $sourceEncoding
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($update.BackupPath)) -eq [Convert]::ToBase64String($original)) 'Unicode profile backup changed bytes'
        $second = Set-EasyPwshProfileStartup $profilePath $initPath
        Assert (-not $second.Changed -and -not $second.BackupPath) 'Profile migration must be idempotent'
        $script:profileInitCalls = 0
        . $profilePath
        Assert ($script:profileInitCalls -eq 1 -and $script:profileUnicode -ceq '中文⌂') 'Migrated profile must preserve Unicode and quoted path'
        $bytes = [IO.File]::ReadAllBytes($profilePath)
        Assert ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'Migrated profile must include UTF-8 BOM'
    }
    [IO.File]::WriteAllText($profilePath, "# . '$($initPath.Replace("'", "''"))'", [Text.Encoding]::UTF8)
    Set-EasyPwshProfileStartup $profilePath $initPath | Out-Null
    $script:profileInitCalls = 0
    . $profilePath
    Assert ($script:profileInitCalls -eq 1) 'Commented startup must not suppress installation'

    # A real .NET Framework executable supplies bytes independently of PowerShell.
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    $fixtureDirectory = Join-Path $sandbox "native 目录's tools"
    [void][IO.Directory]::CreateDirectory($fixtureDirectory)
    $fixture = Join-Path $fixtureDirectory 'Utf8Emitter.exe'
    $fixtureSource = Join-Path $sandbox 'Utf8Emitter.cs'
    [IO.File]::WriteAllText($fixtureSource, @'
using System;
using System.Text;

public static class Utf8Emitter
{
    private static void Write(bool error, string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        var stream = error ? Console.OpenStandardError() : Console.OpenStandardOutput();
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--echo")
        {
            Write(false, args[1]);
        }
        else if (args.Length > 0 && args[0] == "--environment")
        {
            Write(false, Environment.GetEnvironmentVariable("EASYPWSH_UTF8_FIXTURE"));
        }
        else if (args.Length > 0 && args[0] == "--fail")
        {
            Write(true, "失败 中文");
            return 23;
        }
        else if (args.Length > 0 && args[0] == "--flood")
        {
            Write(true, new string('错', 65536));
            Write(false, new string('文', 65536));
        }
        else
        {
            Write(false, "$script:generatedUnicode = '中文⌂'");
        }
        return 0;
    }
}
'@, [Text.UTF8Encoding]::new($true))
    Invoke-EasyPwshUtf8Command $csc @('/nologo','/target:exe',"/out:$fixture",$fixtureSource) | Out-Null
    $oldOutputEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(936)
        foreach ($value in @('中文⌂', "空格 path's `$value; data", 'embedded "quotes" and trailing\', '', '\\server\path with spaces\')) {
            $output = Invoke-EasyPwshUtf8Command $fixture @('--echo',$value)
            Assert ($output -ceq $value) 'Native UTF-8 output or Windows argument quoting failed'
        }
        $output = Invoke-EasyPwshUtf8Command $fixture @('--environment') -Environment @{ EASYPWSH_UTF8_FIXTURE = '中文环境'; PYTHONIOENCODING = 'utf-8' }
        Assert ($output -ceq '中文环境') 'Child environment override failed'
        Assert (-not $env:EASYPWSH_UTF8_FIXTURE) 'Child environment must not leak into parent'
        $failed = $false
        try { Invoke-EasyPwshUtf8Command $fixture @('--fail') | Out-Null } catch { $failed = $_ -match '23' -and $_ -match '失败 中文' }
        Assert $failed 'Native failure must preserve exit code and UTF-8 stderr'
        Assert ((Invoke-EasyPwshUtf8Command $fixture @('--flood')).Length -eq 65536) 'Concurrent stdout/stderr capture failed'
    } finally { [Console]::OutputEncoding = $oldOutputEncoding }

    # Execute each application's real generation statements against the executable.
    $__conda_exe = $__pixiExe = $__zoxideExe = $fixture
    $__conda_cache = Join-Path $sandbox 'conda.ps1'
    $__pixiCache = Join-Path $sandbox 'pixi.ps1'
    $__zoxideCache = Join-Path $sandbox 'zoxide.ps1'
    foreach ($app in @('conda','pixi','zoxide')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "apps/init-$app.ps1"), [ref]$tokens, [ref]$errors)
        $capture = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Right.Extent.Text -like 'Invoke-EasyPwshUtf8Command*' }, $true)
        $writer = $ast.Find({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'WriteAllText' }, $true)
        . ([scriptblock]::Create($capture.Extent.Text))
        . ([scriptblock]::Create($writer.Extent.Text))
    }
    foreach ($cache in @($__conda_cache,$__pixiCache,$__zoxideCache)) {
        $bytes = [IO.File]::ReadAllBytes($cache)
        Assert ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'Generated hook BOM missing'
        . $cache
        Assert ($script:generatedUnicode -ceq '中文⌂') 'Actual native hook Unicode round-trip failed'
    }

    # Use the exact elevation payload, but run without runas so no UAC is requested.
    $target = Join-Path $sandbox "space 目录's [file] `$literal; value.txt"
    $outputPath = Join-Path $sandbox "output 目录's [capture].txt"
    $info = New-EasyPwshSudoStartInfo 'New-Item' @('-Path',$target,'-ItemType','File','-Value',"中文's `$literal; value") $outputPath $shellPath
    Assert ($info.UseShellExecute -and $info.Verb -eq 'runas') 'Elevation settings missing'
    Assert ($info.Arguments -match 'EncodedCommand' -and $info.Arguments -notmatch '目录') 'Arguments must travel in the encoded payload'
    $info.UseShellExecute = $false
    $info.Verb = ''
    $info.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try { [void]$process.Start(); $process.WaitForExit(); Assert ($process.ExitCode -eq 0) 'Encoded sudo command failed' } finally { $process.Dispose() }
    Assert ([IO.File]::ReadAllText($target) -ceq "中文's `$literal; value") 'Sudo argument boundaries, quotes, or Unicode were lost'
    Assert ([IO.File]::Exists($outputPath)) 'Sudo capture path was not handled literally'

    # Missing environments must fail before any core suite runs. Both missing is
    # deliberate so AllowMissingEngine never recursively launches this suite.
    $runner = Join-Path $PSScriptRoot 'Invoke-CompatibilityTests.ps1'
    $runnerBody = "[Console]::OutputEncoding = New-Object Text.UTF8Encoding(`$false); & '{0}' -WindowsPowerShellPath '{1}' -PowerShell7Path '{2}'" -f $runner.Replace("'","''"), (Join-Path $sandbox 'missing-5.exe').Replace("'","''"), (Join-Path $sandbox 'missing-7.exe').Replace("'","''")
    function Invoke-RunnerFixture([string]$Body) {
        # PowerShell 5.1 host stderr may use its legacy encoding; only ASCII
        # status markers matter here. Keep this separate from UTF-8 CLI tests.
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $shellPath
        $info.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('try { ' + $Body + ' } catch { Write-Error $_; exit 1 }'))
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        try {
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            [pscustomobject]@{ ExitCode = $process.ExitCode; Text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
        } finally { $process.Dispose() }
    }
    $missing = Invoke-RunnerFixture $runnerBody
    Assert ($missing.ExitCode -ne 0 -and $missing.Text -match 'UNVERIFIED') 'Missing engines must produce nonzero exit status'
    $partial = Invoke-RunnerFixture ($runnerBody + ' -AllowMissingEngine')
    Assert ($partial.ExitCode -eq 0 -and $partial.Text -match 'Incomplete validation' -and $partial.Text -notmatch 'PASS: both') 'Explicit partial validation must remain labelled incomplete'
} finally {
    $resolved = [IO.Path]::GetFullPath($sandbox)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'EasyPwsh-native-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

    }

    & {
        # Exercise fnm session setup without requiring an installed Node manager.
        $global:__EasyPwshFnmTestAvailable = $false
        $global:__EasyPwshFnmTestEnvCalls = 0
        $global:__EasyPwshFnmTestHookCalls = 0
        function Get-Command {
            [CmdletBinding()] param($Name, $CommandType)
            if ($Name -eq 'fnm' -and $global:__EasyPwshFnmTestAvailable) { [pscustomobject]@{ Source = 'fixture-fnm.exe' } }
        }
        function Invoke-EasyPwshUtf8Command {
            param($FilePath, $ArgumentList)
            Assert ($FilePath -eq 'fixture-fnm.exe' -and ($ArgumentList -join ' ') -eq 'env --use-on-cd --shell powershell') 'fnm must request the PowerShell directory hook'
            $global:__EasyPwshFnmTestEnvCalls++
            '$global:__EasyPwshFnmTestHookCalls++'
        }
        & (Join-Path $root 'apps/init-fnm.ps1')
        Assert ($global:__EasyPwshFnmTestEnvCalls -eq 0) 'Absent fnm must skip initialization'
        $global:__EasyPwshFnmTestAvailable = $true
        & (Join-Path $root 'apps/init-fnm.ps1')
        & (Join-Path $root 'apps/init-fnm.ps1')
        Assert ($global:__EasyPwshFnmTestEnvCalls -eq 2 -and $global:__EasyPwshFnmTestHookCalls -eq 2) 'Each fnm initialization must generate and evaluate a fresh environment'
        Remove-Variable __EasyPwshFnmTestHookCalls,__EasyPwshFnmTestAvailable,__EasyPwshFnmTestEnvCalls -Scope Global
    }

    & (Join-Path $root 'start/symlink.ps1')
    $linkTarget = Join-Path $sandbox 'target.txt'
    $linkPath = Join-Path $sandbox 'link.txt'
    [IO.File]::WriteAllText($linkTarget, 'test')
    & {
        # Model the legacy Target property even when symlink privileges are absent.
        $script:fakeLink = [pscustomobject]@{ LinkType = 'SymbolicLink'; Target = $linkTarget }
        $script:removedLink = $null
        function Get-Item { [CmdletBinding()] param($LiteralPath, [switch]$Force) $script:fakeLink }
        function Remove-Item { [CmdletBinding()] param($LiteralPath, [switch]$Force) $script:removedLink = $LiteralPath }
        New-ManagedSymlink -Path $linkPath -Target $linkTarget -WarningAction Stop
        Remove-ManagedSymlink -Path $linkPath -Target (Join-Path $sandbox 'other.txt')
        Assert ($null -eq $script:removedLink) 'Mismatched legacy Target must not be removed'
        Remove-ManagedSymlink -Path $linkPath -Target $linkTarget
        Assert ($script:removedLink -eq $linkPath) 'Legacy Target must be recognized'
        $script:fakeLink.LinkType = 'HardLink'
        $script:removedLink = $null
        Remove-ManagedSymlink -Path $linkPath -Target $linkTarget
        Assert ($null -eq $script:removedLink) 'Hard links must not be removed'
    }
    $linkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Value $linkTarget | Out-Null
        $linkCreated = $true
    } catch { Write-Host 'SKIP: real symlink test requires Developer Mode or elevation.' }
    if ($linkCreated) {
        New-ManagedSymlink -Path $linkPath -Target $linkTarget -WarningAction Stop
        Remove-ManagedSymlink -Path $linkPath -Target (Join-Path $sandbox 'other.txt')
        Assert (Test-Path -LiteralPath $linkPath) 'Mismatched symlink target must be preserved'
        Remove-ManagedSymlink -Path $linkPath -Target $linkTarget
        Assert (-not (Test-Path -LiteralPath $linkPath) -and (Test-Path -LiteralPath $linkTarget)) 'Managed link removal must preserve its target'
    }

    # Compile and reload the DLL in a separate process (framework-specific cache).
    & (Join-Path $root 'start/WinAPI.ps1')
    Assert ($null -ne ('WinApi' -as [type])) 'WinAPI DLL did not load'
    . (Join-Path $root 'functions/init-functions.ps1')
    Assert ([bool](Get-Command cc,sh,uptime -ErrorAction Stop)) 'Function loader failed'
} finally {
    Set-Location -LiteralPath $originalLocation.Path
    $resolvedSandbox = [IO.Path]::GetFullPath($sandbox)
    if ($resolvedSandbox.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedSandbox -Leaf) -like 'EasyPwsh-tests-*') {
        Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force
    }
}
Write-Host "PASS: PS $($PSVersionTable.PSVersion), PSReadLine $($module.Version), $script:passed assertions."
