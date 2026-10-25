# 把本仓库推送到 GitHub（自动创建远程仓库）
#
# 用法:
#   .\push-to-github.ps1 -User "你的GitHub用户名" -Token "ghp_xxx" [-RepoName "l4d2-rpg"] [-Private]
#
# 说明:
#   - 需要 token 具备 repo 权限（classic）或 Contents: Read and write（fine-grained）
#   - token 只在本次进程内存里使用，不写入任何文件、不写进 git 配置
#   - 已存在的远程仓库会直接复用，不会报错
#
# ⚠️ 安全提醒: 命令行参数会留在 PowerShell 历史里（$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt）。
#    推送完成后建议到 GitHub 设置里把这个 token 删掉，或者改用 `git credential-manager` 交互登录。

param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$RepoName = "l4d2-rpg",
    [switch]$Private,
    [string]$Description = "Left 4 Dead 2 RPG plugin for SourceMod: account/password login, XP leveling, money, shop, database persistence"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root

try {
    $headers = @{
        Authorization          = "token $Token"
        Accept                 = "application/vnd.github+json"
        "User-Agent"           = "l4d2-rpg-push"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    # 1. 校验 token 并拿到真实用户名（防止用户名拼错）
    Write-Host "[1/4] 校验 token ..." -ForegroundColor Cyan
    $me = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $headers -Method Get
    Write-Host "      认证为: $($me.login)" -ForegroundColor Green
    if ($me.login -ne $User) {
        Write-Host "      提示: 你填的 User=$User, 实际 token 属于 $($me.login)，以 token 为准" -ForegroundColor Yellow
    }
    $User = $me.login

    # 2. 创建仓库（已存在则复用）
    Write-Host "[2/4] 创建仓库 $User/$RepoName ..." -ForegroundColor Cyan
    $exists = $false
    try {
        $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$User/$RepoName" -Headers $headers -Method Get
        $exists = $true
        Write-Host "      仓库已存在, 直接复用" -ForegroundColor Yellow
    } catch {
        $exists = $false
    }

    if (-not $exists) {
        $body = @{
            name        = $RepoName
            description = $Description
            private     = [bool]$Private
            has_issues  = $true
            has_wiki    = $false
            auto_init   = $false
        } | ConvertTo-Json
        $repo = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Headers $headers -Method Post -Body $body -ContentType "application/json"
        Write-Host "      已创建: $($repo.html_url)" -ForegroundColor Green
    }

    # 3. 配置 remote 并推送
    Write-Host "[3/4] 推送 ..." -ForegroundColor Cyan
    $remoteUrl = "https://github.com/$User/$RepoName.git"
    $existing = git remote 2>$null
    if ($existing -contains "origin") { git remote remove origin }
    git remote add origin $remoteUrl

    # 用一次性的凭据推送，不落盘
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$User`:$Token"))
    git -c http.extraheader="AUTHORIZATION: basic $basic" push -u origin main 2>&1 | ForEach-Object { Write-Host "      $_" }
    if ($LASTEXITCODE -ne 0) { throw "git push 失败 (exit $LASTEXITCODE)" }

    Write-Host "[4/4] 完成" -ForegroundColor Cyan
    Write-Host "      仓库地址: https://github.com/$User/$RepoName" -ForegroundColor Green
}
finally {
    Pop-Location
}
