<#
.SYNOPSIS
    一个用于查找和清理 Windows 防火墙中重复规则的交互式脚本。

.DESCRIPTION
    该脚本提供一个菜单，允许用户选择检查入站、出站或所有规则。
    它会首先识别并列出所有内容完全一致的重复规则。在用户确认后，
    脚本会自动备份当前的防火墙设置，然后清理掉这些重复的规则（每个重复组仅保留一条）。
    最后，它会重新运行检查以验证清理效果。

.NOTES
    必须以管理员身份运行此脚本。
#>

# --- 前置检查：确保以管理员权限运行 ---
$currentUserPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentUserPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "错误：此脚本需要管理员权限才能修改防火墙规则。"
    Write-Host "请右键单击此脚本文件，然后选择 '以管理员身份运行'。" -ForegroundColor Yellow
    Start-Sleep -Seconds 7
    exit
}

# --- 核心函数定义 ---

function Get-DuplicateFirewallRules {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet('Inbound', 'Outbound', 'All')]
        [string]$Scope
    )

    Write-Host "正在检查重复规则，范围: $Scope..." -ForegroundColor Cyan

    # 定义用于精确判断重复的关键属性列表
    $comparisonProperties = @(
        'DisplayName', 'Direction', 'Action', 'Enabled', 'Profile', 'Protocol',
        'LocalPort', 'RemotePort', 'LocalAddress', 'RemoteAddress', 'Program', 'Service'
    )

    $rulesToProcess = switch ($Scope) {
        'Inbound'  { Get-NetFirewallRule -Direction Inbound  -ErrorAction SilentlyContinue }
        'Outbound' { Get-NetFirewallRule -Direction Outbound -ErrorAction SilentlyContinue }
        'All'      { Get-NetFirewallRule -ErrorAction SilentlyContinue }
    }

    # 根据关键属性分组，并筛选出数量大于1的组（即重复组）
    $duplicateGroups = $rulesToProcess | Group-Object -Property $comparisonProperties | Where-Object { $_.Count -gt 1 }

    return $duplicateGroups
}

function Display-DuplicateResults {
    [CmdletBinding()]
    param (
        # 修正：移除 [Parameter(Mandatory=$true)] 以优雅地处理空的输入
        $DuplicateGroups
    )

    if ($DuplicateGroups) {
        Write-Host "----------------- 检查结果 -----------------" -ForegroundColor Yellow
        Write-Host "发现 $($DuplicateGroups.Count) 组重复的防火墙规则。详情如下：" -ForegroundColor Yellow

        $totalRedundantCount = 0

        $DuplicateGroups | ForEach-Object {
            $group = $_
            $redundantInGroup = $group.Count - 1
            $totalRedundantCount += $redundantInGroup

            Write-Host " "
            Write-Host "规则组: '$($group.Group[0].DisplayName)' (共 $($group.Count) 条, 可清理 $redundantInGroup 条)" -ForegroundColor Green
            $group.Group | Select-Object Name, Description | Format-Table -AutoSize
        }

        Write-Host "========================================================" -ForegroundColor Yellow
        Write-Host "总计发现可清理的冗余规则数量: $totalRedundantCount" -ForegroundColor Yellow
        return $true
    } else {
        Write-Host "----------------- 检查结果 -----------------" -ForegroundColor Green
        Write-Host "恭喜！在指定范围内未发现任何重复的防火墙规则。" -ForegroundColor Green
        Write-Host "========================================================" -ForegroundColor Green
        return $false
    }
}

function Backup-FirewallRules {
    Write-Host " "
    Write-Host "正在执行清理前的备份操作..." -ForegroundColor Cyan

    try {
        $documentsPath = [Environment]::GetFolderPath('MyDocuments')
        $backupFolder = Join-Path -Path $documentsPath -ChildPath "Firewall_Backups"

        if (-not (Test-Path -Path $backupFolder)) {
            New-Item -ItemType Directory -Path $backupFolder | Out-Null
        }

        $backupFile = "firewall_backup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').wfw"
        $backupPath = Join-Path -Path $backupFolder -ChildPath $backupFile

        netsh advfirewall export $backupPath

        Write-Host "防火墙规则已成功备份到:" -ForegroundColor Green
        Write-Host $backupPath -ForegroundColor White
        return $true
    } catch {
        Write-Error "备份失败! 错误信息: $_"
        return $false
    }
}

function Clean-DuplicateFirewallRules {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        $DuplicateGroups
    )

    Write-Host " "
    Write-Host "开始执行清理操作..." -ForegroundColor Cyan
    $progress = 0
    $totalToDelete = ($DuplicateGroups | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum

    $DuplicateGroups | ForEach-Object {
        $group = $_
        # 跳过每个组的第一条规则（保留），将其余的全部删除
        $rulesToDelete = $group.Group | Select-Object -Skip 1

        foreach ($rule in $rulesToDelete) {
            $progress++
            Write-Progress -Activity "正在清理重复规则" -Status "正在删除 '$($rule.DisplayName)'" -PercentComplete (($progress / $totalToDelete) * 100)

            try {
                Remove-NetFirewallRule -InputObject $rule -ErrorAction Stop
            } catch {
                Write-Warning "删除规则 '$($rule.Name)' 时遇到错误: $_"
            }
        }
    }
    Write-Progress -Activity "清理完成" -Completed
    Write-Host "清理操作已完成。" -ForegroundColor Green
}

# --- 脚本主流程 ---

Clear-Host

# 1. 显示菜单并获取用户选择
$menuChoice = 0
while ($menuChoice -notin 1..4) {
    Write-Host @"

欢迎使用 Windows 防火墙重复规则清理工具
==========================================
请选择要检查的规则范围:

    1. 仅检查【入站】规则
    2. 仅检查【出站】规则
    3. 检查【入站和出站】所有规则

    4. 退出

==========================================
"@ -ForegroundColor White
    $input = Read-Host "请输入数字并按回车"
    if ($input -match "^\d+$") {
        $menuChoice = [int]$input
    }
}

if ($menuChoice -eq 4) {
    Write-Host "已退出。"
    exit
}

# 2. 根据选择确定范围
$scope = switch ($menuChoice) {
    1 { 'Inbound' }
    2 { 'Outbound' }
    3 { 'All' }
}

# 3. 首次执行检查
$duplicateGroups = Get-DuplicateFirewallRules -Scope $scope
$hasDuplicates = Display-DuplicateResults -DuplicateGroups $duplicateGroups

# 4. 如果有重复，询问是否清理
if ($hasDuplicates) {
    Write-Host " "
    $confirmation = Read-Host "是否要自动备份并清理这些重复规则? (请输入 Y 确认，其他任意键取消)"

    if ($confirmation -eq 'Y' -or $confirmation -eq 'y') {
        # 5. 执行备份
        if (Backup-FirewallRules) {
            # 6. 执行清理
            Clean-DuplicateFirewallRules -DuplicateGroups $duplicateGroups

            # 7. 再次执行检查以验证结果
            Write-Host " "
            Write-Host "--- 清理后验证 ---" -ForegroundColor Cyan
            $postCleanupGroups = Get-DuplicateFirewallRules -Scope $scope
            Display-DuplicateResults -DuplicateGroups $postCleanupGroups
        } else {
            Write-Host "由于备份失败，清理操作已中止。" -ForegroundColor Red
        }
    } else {
        Write-Host "操作已取消，未做任何更改。" -ForegroundColor Yellow
    }
}

# 8. 结束退出
Write-Host " "
Read-Host "所有操作已完成。按回车键退出。"