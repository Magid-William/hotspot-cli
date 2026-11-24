#Requires -Version 5.1
<#
    Installs hotspot.ps1 + hotspot.cmd into a folder on PATH.

    Default target is %USERPROFILE%\bin. Use -Link to create hard links
    instead of copies, so edits in this repo are picked up immediately.
#>

[CmdletBinding()]
param(
    [string]$Path = (Join-Path $env:USERPROFILE 'bin'),
    [switch]$Link,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
$files = 'hotspot.ps1', 'hotspot.cmd'

if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Write-Host "Created $Path"
}

foreach ($file in $files) {
    $from = Join-Path $source $file
    $to = Join-Path $Path $file

    if (-not (Test-Path $from)) { throw "Missing $from" }

    if (Test-Path $to) {
        if (-not $Force -and -not $Link) {
            Remove-Item $to -Force
        }
        elseif ($Force) {
            Remove-Item $to -Force
        }
        elseif ($Link) {
            Remove-Item $to -Force
        }
    }

    if ($Link) {
        New-Item -ItemType HardLink -Path $to -Target $from | Out-Null
        Write-Host "linked  $to"
    }
    else {
        Copy-Item $from $to -Force
        Write-Host "copied  $to"
    }
}

# make sure the folder is on the user PATH
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @()
if ($userPath) { $entries = $userPath -split ';' | Where-Object { $_ } }

if ($entries -notcontains $Path) {
    $newPath = (@($entries) + $Path) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "Added $Path to your user PATH."
    Write-Host 'Open a new terminal for the change to take effect.'
}
else {
    Write-Host "$Path is already on your user PATH."
}

Write-Host ''
Write-Host 'Try: hotspot status' -ForegroundColor Green
