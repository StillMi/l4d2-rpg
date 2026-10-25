# L4D2 RPG 插件 - 编译脚本
#
# 用法:
#   .\build.ps1                      # 用默认路径编译
#   .\build.ps1 -Compiler "D:\sm\spcomp.exe" -Include "D:\sm\include"
#
# 说明: SourcePawn 编译器要求 -o / -i 的参数与选项**连成一个 token**，
#       否则 PowerShell 不会展开变量，spcomp 会把字面量当成输出文件名。

param(
    [string]$Compiler = "F:\DeepseekWork\l4d2_tools\_tools\sm111\addons\sourcemod\scripting\spcomp.exe",
    [string]$Include  = "F:\DeepseekWork\l4d2_tools\_tools\sm111\addons\sourcemod\scripting\include"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root "scripting\l4d2_rpg.sp"
$smx  = Join-Path $root "scripting\l4d2_rpg.smx"

if (-not (Test-Path $Compiler)) { throw "找不到编译器: $Compiler" }
if (-not (Test-Path $Include))  { throw "找不到 include 目录: $Include" }
if (-not (Test-Path $src))      { throw "找不到源码: $src" }

Write-Host "编译 $src ..." -ForegroundColor Cyan
& $Compiler $src "-o$smx" "-i$Include" 2>&1
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Host "编译失败 (exit $code)" -ForegroundColor Red
    exit $code
}

$item = Get-Item $smx
Write-Host ("编译成功: {0} ({1} 字节)" -f $item.Name, $item.Length) -ForegroundColor Green
