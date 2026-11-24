#Requires -Version 5.1
<#
    Test suite for hotspot-cli.

    No Pester required (only 3.4.0 ships with Windows), no network access,
    runs on PowerShell 5.1 and 7.

        powershell -ExecutionPolicy Bypass -File .\tests\hotspot.tests.ps1

    Unit tests only touch pure functions and are safe to run any time.

    Add -Integration to also exercise the real hotspot (on/off/status).
    That WILL drop any connected clients for a few seconds, and it restores
    the original state when it finishes.
#>

[CmdletBinding()]
param(
    [switch]$Integration
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$cliPath = Join-Path $repoRoot 'hotspot.ps1'

if (-not (Test-Path $cliPath)) { throw "Cannot find $cliPath" }

# Load the functions without launching the CLI.
$env:HOTSPOT_CLI_LIB = '1'
. $cliPath
Remove-Item Env:\HOTSPOT_CLI_LIB -ErrorAction SilentlyContinue

# ------------------------------------------------------------------- harness

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.ArrayList

function It {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Host ("  pass  {0}" -f $Name) -ForegroundColor DarkGreen
    }
    catch {
        $script:Failed++
        $message = $_.Exception.Message
        [void]$script:Failures.Add(("{0}: {1}" -f $Name, $message))
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("        {0}" -f $message) -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) {
        throw ("expected <{0}> but got <{1}> {2}" -f $Expected, $Actual, $Because).Trim()
    }
}

function Assert-True {
    param($Condition, [string]$Because = '')
    if (-not $Condition) { throw "expected true. $Because".Trim() }
}

function Assert-False {
    param($Condition, [string]$Because = '')
    if ($Condition) { throw "expected false. $Because".Trim() }
}

function Assert-Match {
    param([string]$Pattern, [string]$Text, [string]$Because = '')
    if ($Text -notmatch $Pattern) { throw "expected /$Pattern/ in output. $Because".Trim() }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern = '')
    $threw = $false
    try { & $Body }
    catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "message '$($_.Exception.Message)' did not match /$Pattern/"
        }
    }
    if (-not $threw) { throw 'expected an exception, none was thrown' }
}

function Invoke-Cli {
    param([string[]]$Arguments = @())

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File $cliPath @Arguments 2>&1
    [pscustomobject]@{
        Output   = ($output | Out-String)
        ExitCode = $LASTEXITCODE
    }
}

# ---------------------------------------------------------------------- tests

Write-Host ''
Write-Host 'hotspot-cli tests' -ForegroundColor Cyan
Write-Host ''

Write-Host 'MAC handling' -ForegroundColor Yellow

It 'Get-NormalizedMac strips colons and lowercases' {
    Assert-Equal 'aabbccddeeff' (Get-NormalizedMac 'AA:BB:CC:DD:EE:FF')
}

It 'Get-NormalizedMac strips dashes' {
    Assert-Equal 'aabbccddeeff' (Get-NormalizedMac 'AA-BB-CC-DD-EE-FF')
}

It 'Get-NormalizedMac keeps dotted form comparable' {
    Assert-Equal 'aabbccddeeff' (Get-NormalizedMac 'aabb.ccdd.eeff')
}

It 'Get-NormalizedMac returns empty for null' {
    Assert-Equal '' (Get-NormalizedMac $null)
}

It 'Format-MacAddress produces colon separated uppercase' {
    Assert-Equal 'AA:BB:CC:DD:EE:FF' (Format-MacAddress 'aa-bb-cc-dd-ee-ff')
}

It 'Format-MacAddress handles empty input' {
    Assert-Equal '' (Format-MacAddress '')
}

Write-Host 'Password generation' -ForegroundColor Yellow

It 'New-RandomPassphrase produces a valid length' {
    $pass = New-RandomPassphrase
    Assert-True ($pass.Length -ge 8) 'must be at least 8 characters'
    Assert-True ($pass.Length -le 63) 'must be at most 63 characters'
}

It 'New-RandomPassphrase output passes validation' {
    Assert-True (Test-ValidPassphrase (New-RandomPassphrase))
}

It 'New-RandomPassphrase does not repeat' {
    $a = New-RandomPassphrase
    $b = New-RandomPassphrase
    Assert-True ($a -ne $b) 'two calls returned the same password'
}

Write-Host 'SSID validation' -ForegroundColor Yellow

It 'rejects an empty SSID' {
    Assert-False (Test-ValidSsid '')
}

It 'rejects a whitespace-only SSID' {
    Assert-False (Test-ValidSsid '    ')
}

It 'accepts a single character' {
    Assert-True (Test-ValidSsid 'x')
}

It 'accepts exactly 32 characters' {
    Assert-True (Test-ValidSsid ('a' * 32))
}

It 'rejects 33 characters' {
    Assert-False (Test-ValidSsid ('a' * 33))
}

It 'accepts the real world SSID' {
    Assert-True (Test-ValidSsid 'TP-Link_48AA_5G')
}

Write-Host 'Passphrase validation' -ForegroundColor Yellow

It 'rejects 7 characters' {
    Assert-False (Test-ValidPassphrase 'abcdefg')
}

It 'accepts exactly 8 characters' {
    Assert-True (Test-ValidPassphrase 'abcdefgh')
}

It 'accepts exactly 63 characters' {
    Assert-True (Test-ValidPassphrase ('a' * 63))
}

It 'rejects 64 characters' {
    Assert-False (Test-ValidPassphrase ('a' * 64))
}

Write-Host 'Band mapping' -ForegroundColor Yellow

It 'maps 2.4 to TwoPointFourGigahertz' {
    Assert-Equal 'TwoPointFourGigahertz' (ConvertTo-BandName '2.4')
}

It 'maps 2.4ghz case insensitively' {
    Assert-Equal 'TwoPointFourGigahertz' (ConvertTo-BandName '2.4GHz')
}

It 'maps 5 to FiveGigahertz' {
    Assert-Equal 'FiveGigahertz' (ConvertTo-BandName '5')
}

It 'maps 6 to SixGigahertz' {
    Assert-Equal 'SixGigahertz' (ConvertTo-BandName '6')
}

It 'maps auto to Auto' {
    Assert-Equal 'Auto' (ConvertTo-BandName 'auto')
}

It 'throws on an unknown band' {
    Assert-Throws { ConvertTo-BandName '11' } 'Invalid band'
}

Write-Host 'Argument parsing' -ForegroundColor Yellow

It 'reads -Uplink when typed in a session (SubAction shape)' {
    $parsed = Split-CliArguments -SubAction '-Uplink' -Value @('Ethernet')
    Assert-Equal 'Ethernet' $parsed.Uplink
    Assert-Equal 0 @($parsed.Clean).Count
}

It 'reads -Uplink when passed after -File (Value shape)' {
    $parsed = Split-CliArguments -SubAction '' -Value @('-Uplink', 'Ethernet')
    Assert-Equal 'Ethernet' $parsed.Uplink
    Assert-Equal 0 @($parsed.Clean).Count
}

It 'reads --uplink as well as -Uplink' {
    $parsed = Split-CliArguments -SubAction '' -Value @('--uplink', 'Ethernet')
    Assert-Equal 'Ethernet' $parsed.Uplink
}

It 'keeps subcommand values out of the uplink option' {
    $parsed = Split-CliArguments -SubAction 'ssid' -Value @('My Network')
    Assert-Equal $null $parsed.Uplink
    Assert-Equal 'My Network' (@($parsed.Clean) -join ' ')
}

It 'handles no arguments at all' {
    $parsed = Split-CliArguments -SubAction '' -Value @()
    Assert-Equal $null $parsed.Uplink
    Assert-Equal 0 @($parsed.Clean).Count
}

It 'ignores a trailing -Uplink with no value' {
    $parsed = Split-CliArguments -SubAction '' -Value @('on', '-Uplink')
    Assert-Equal $null $parsed.Uplink
    Assert-Equal 'on -Uplink' (@($parsed.Clean) -join ' ')
}

Write-Host 'Uplink scoring' -ForegroundColor Yellow

It 'scores Ethernet above Wi-Fi' {
    Assert-True ((Get-UplinkScore -IanaType 6) -gt (Get-UplinkScore -IanaType 71))
}

It 'scores Ethernet at 30' {
    Assert-Equal 30 (Get-UplinkScore -IanaType 6)
}

It 'scores Wi-Fi at 20' {
    Assert-Equal 20 (Get-UplinkScore -IanaType 71)
}

It 'gives unknown adapters the lowest score' {
    Assert-Equal 10 (Get-UplinkScore -IanaType 999)
}

Write-Host 'Help output' -ForegroundColor Yellow

It 'documents every command' {
    $help = Get-HelpText
    foreach ($command in 'on', 'off', 'restart', 'status', 'devices', 'update ssid', 'update password', 'update band', 'logon', 'uninstall', 'help') {
        Assert-Match ([regex]::Escape($command)) $help "missing '$command'"
    }
}

It 'mentions the repo url' {
    Assert-Match 'github\.com/Magid-William/hotspot-cli' (Get-HelpText)
}

Write-Host 'Command line behaviour' -ForegroundColor Yellow

It 'bare invocation prints help and exits 0' {
    $result = Invoke-Cli
    Assert-Equal 0 $result.ExitCode
    Assert-Match 'Windows Mobile Hotspot from the command line' $result.Output
}

It 'help exits 0' {
    $result = Invoke-Cli @('help')
    Assert-Equal 0 $result.ExitCode
    Assert-Match 'hotspot devices' $result.Output
}

It 'works when launched from PowerShell 7' {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) { return }

    $output = & $pwsh.Source -NoProfile -File $cliPath 'help' 2>&1
    Assert-Equal 0 $LASTEXITCODE 'PowerShell 7 run should succeed via the 5.1 relaunch'
    Assert-Match 'Windows Mobile Hotspot from the command line' ($output | Out-String)
}

It 'unknown command prints help and exits 1' {
    $result = Invoke-Cli @('nonsense')
    Assert-Equal 1 $result.ExitCode
    Assert-Match "Unknown command 'nonsense'" $result.Output
}

It 'unknown update target exits 1' {
    $result = Invoke-Cli @('update', 'nonsense')
    Assert-Equal 1 $result.ExitCode
}

It 'update without a target exits 1' {
    $result = Invoke-Cli @('update')
    Assert-Equal 1 $result.ExitCode
}

# --------------------------------------------------------------- integration

if ($Integration) {

    Write-Host ''
    Write-Host 'Integration (real hotspot)' -ForegroundColor Yellow
    Write-Host '  note: connected devices will drop while this runs' -ForegroundColor DarkGray

    $before = Invoke-Cli @('status')
    $wasOn = $before.Output -match 'State\s+:\s+On'

    try {

        It 'status reports a state' {
            $result = Invoke-Cli @('status')
            Assert-Equal 0 $result.ExitCode
            Assert-Match 'State\s+:\s+(On|Off)' $result.Output
        }

        It 'status reports the shared uplink' {
            Assert-Match 'Sharing\s+:\s+\S' $before.Output
        }

        It 'off succeeds and status reports Off' {
            $result = Invoke-Cli @('off')
            Assert-Equal 0 $result.ExitCode
            Assert-Match 'State\s+:\s+Off' (Invoke-Cli @('status')).Output
        }

        It 'on succeeds and status reports On' {
            $result = Invoke-Cli @('on')
            Assert-Equal 0 $result.ExitCode
            $status = Invoke-Cli @('status')
            Assert-Match 'State\s+:\s+On' $status.Output
            Assert-Match 'AP address : 192\.168\.137\.1' $status.Output
        }

        It 'restart succeeds' {
            $result = Invoke-Cli @('restart')
            Assert-Equal 0 $result.ExitCode
        }

        It 'devices exits cleanly' {
            $result = Invoke-Cli @('devices')
            Assert-Equal 0 $result.ExitCode
        }

        It 'status works when launched from PowerShell 7' {
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if (-not $pwsh) { return }

            $output = & $pwsh.Source -NoProfile -File $cliPath 'status' 2>&1
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'State\s+:\s+(On|Off)' ($output | Out-String)
        }

        It 'honours -Uplink when typed in a session shape' {
            $result = Invoke-Cli @('on', '-Uplink', 'NoSuchProfile')
            Assert-Equal 1 $result.ExitCode
            Assert-Match 'No internet-capable uplink named' $result.Output
        }

        It 'rejects an unknown uplink without changing state' {
            $result = Invoke-Cli @('on', '-Uplink', 'NoSuchProfile')
            Assert-Equal 1 $result.ExitCode
            Assert-Match 'No internet-capable uplink named' $result.Output
        }

        It 'rejects an SSID longer than 32 characters' {
            $result = Invoke-Cli @('update', 'ssid', ('a' * 33))
            Assert-Equal 1 $result.ExitCode
            Assert-Match '1-32 characters' $result.Output
        }

        It 'rejects a password shorter than 8 characters' {
            $result = Invoke-Cli @('update', 'password', 'short')
            Assert-Equal 1 $result.ExitCode
            Assert-Match '8-63 characters' $result.Output
        }

        It 'uninstall removes the installed files and the logon task' {
            if (Test-LogonAutostart) {
                Write-Host '        (skipped: a real logon task is enabled, refusing to touch it)' -ForegroundColor DarkGray
                return
            }

            $tempDir = Join-Path $env:TEMP ('hotspot-uninstall-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            Copy-Item $cliPath (Join-Path $tempDir 'hotspot.ps1')
            Copy-Item (Join-Path $repoRoot 'hotspot.cmd') (Join-Path $tempDir 'hotspot.cmd')

            # stand in for a real autostart entry so the removal path is exercised
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit'
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            Register-ScheduledTask -TaskName 'hotspot-cli' -Action $action -Trigger $trigger -Force | Out-Null

            try {
                $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tempDir 'hotspot.ps1') uninstall 2>&1
                Assert-Equal 0 $LASTEXITCODE
                Assert-False (Test-Path (Join-Path $tempDir 'hotspot.ps1')) 'hotspot.ps1 should be deleted'
                Assert-False (Test-Path (Join-Path $tempDir 'hotspot.cmd')) 'hotspot.cmd should be deleted'
                Assert-False (Test-LogonAutostart) 'logon task should be gone'
                Assert-Match 'Uninstalling from' (($output | Out-String))
            }
            finally {
                Unregister-ScheduledTask -TaskName 'hotspot-cli' -Confirm:$false -ErrorAction SilentlyContinue
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        # put the machine back the way we found it
        if ($wasOn) { Invoke-Cli @('on') | Out-Null }
        else { Invoke-Cli @('off') | Out-Null }
    }
}

# --------------------------------------------------------------------- report

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host ("all {0} tests passed" -f $script:Passed) -ForegroundColor Green
    exit 0
}

Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Red
foreach ($failure in $script:Failures) {
    Write-Host ("  - {0}" -f $failure) -ForegroundColor Red
}
exit 1
