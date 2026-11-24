#Requires -Version 5.1
<#
    hotspot - control the Windows Mobile Hotspot from the command line.

    Windows 11 exposes no CLI for the built-in Mobile Hotspot, and the old
    "netsh wlan start hostednetwork" path is dead on modern WLAN drivers
    (this machine reports "Hosted network supported: No"). This script drives
    the same WinRT API the Settings page uses:

        Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager

    Requires an interactive desktop session. There is no boot-time start:
    the API needs a logged-in user with a running Wi-Fi stack.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action = 'status',
    [Parameter(Position = 1)][string]$SubAction,
    [Parameter(Position = 2, ValueFromRemainingArguments = $true)][string[]]$Value
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ApAddress = '192.168.137.1'
$script:RepoUrl = 'https://github.com/Magid-William/hotspot-cli'

# ---------------------------------------------------------------- WinRT glue

function Initialize-WinRT {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.TetheringWiFiBand, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime] | Out-Null
}

function Get-AwaitMethod {
    if (-not $script:AwaitMethod) {
        $script:AwaitMethod = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            })[0]
    }
    $script:AwaitMethod
}

function Await($operation, $resultType) {
    $asTask = (Get-AwaitMethod).MakeGenericMethod($resultType)
    $task = $asTask.Invoke($null, @($operation))
    $task.Wait(-1) | Out-Null
    $task.Result
}

function Get-AwaitActionMethod {
    if (-not $script:AwaitActionMethod) {
        $script:AwaitActionMethod = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
            })[0]
    }
    $script:AwaitActionMethod
}

# ConfigureAccessPointAsync returns IAsyncAction (no result), unlike
# start/stop which return IAsyncOperation<OperationResult>.
function Await-Action($action) {
    $task = (Get-AwaitActionMethod).Invoke($null, @($action))
    $task.Wait(-1) | Out-Null
}

# ------------------------------------------------------------------- uplinks

function Get-UplinkCandidates {
    $profiles = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
    $out = @()

    foreach ($profile in $profiles) {
        if (-not $profile) { continue }
        $adapter = $profile.NetworkAdapter
        if (-not $adapter) { continue }

        # 53 = tunnel. This is what keeps Cloudflare WARP and Tailscale from
        # silently becoming the thing the hotspot shares.
        if ($adapter.IanaInterfaceType -eq 53) { continue }
        if ($profile.GetNetworkConnectivityLevel() -ne 'InternetAccess') { continue }

        $score = switch ($adapter.IanaInterfaceType) {
            6 { 30 }   # Ethernet
            71 { 20 }  # Wi-Fi
            default { 10 }
        }

        $out += [pscustomobject]@{
            Name    = $profile.ProfileName
            Profile = $profile
            Type    = $adapter.IanaInterfaceType
            Score   = $score
        }
    }

    , $out
}

function Resolve-Uplink {
    param([string]$Name)

    $candidates = Get-UplinkCandidates

    if ($Name) {
        $match = $candidates | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $match) {
            $available = if ($candidates) { ($candidates | ForEach-Object { "'$($_.Name)'" }) -join ', ' } else { 'none' }
            throw "No internet-capable uplink named '$Name'. Available: $available"
        }
        return $match
    }

    if (-not $candidates) {
        throw 'No internet-capable uplink found. Is the network cable plugged in and the link up?'
    }

    $candidates | Sort-Object -Property Score -Descending | Select-Object -First 1
}

# ------------------------------------------------------------------ tethering

function Get-TetheringManager {
    param($Uplink)
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($Uplink.Profile)
}

function Get-HotspotState {
    param($Manager)
    [string]$Manager.TetheringOperationalState
}

function Wait-HotspotState {
    param($Manager, [string]$Wanted, [int]$TimeoutSeconds = 20)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-HotspotState -Manager $Manager) -eq $Wanted) { return $true }
        Start-Sleep -Milliseconds 400
    }
    $false
}

function Test-ApAddress {
    [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $script:ApAddress })
}

function Start-Hotspot {
    param($Manager, [switch]$Quiet)

    if ((Get-HotspotState -Manager $Manager) -eq 'On' -and (Test-ApAddress)) {
        if (-not $Quiet) { Write-Host 'Hotspot is already on.' }
        return $false
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $result = Await ($Manager.StartTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        if ($result.Status -ne 'Success') {
            throw "Start failed: $($result.Status) $($result.AdditionalErrorMessage)"
        }

        if (Wait-HotspotState -Manager $Manager -Wanted 'On') {
            # Windows occasionally reports success but never assigns the
            # 192.168.137.1 gateway; a single stop/start cycle fixes it.
            $assigned = $false
            for ($i = 0; $i -lt 25; $i++) {
                if (Test-ApAddress) { $assigned = $true; break }
                Start-Sleep -Milliseconds 200
            }
            if ($assigned) { return $true }
        }

        if ($attempt -eq 1) {
            if (-not $Quiet) { Write-Host 'Hotspot came up without an address, retrying once...' }
            Await ($Manager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]) | Out-Null
            Wait-HotspotState -Manager $Manager -Wanted 'Off' | Out-Null
        }
    }

    throw 'Hotspot did not come up (no 192.168.137.1 assigned). Try disabling and re-enabling the Wi-Fi adapter.'
}

function Stop-Hotspot {
    param($Manager, [switch]$Quiet)

    if ((Get-HotspotState -Manager $Manager) -eq 'Off') {
        if (-not $Quiet) { Write-Host 'Hotspot is already off.' }
        return
    }

    $result = Await ($Manager.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    if ($result.Status -ne 'Success') {
        throw "Stop failed: $($result.Status) $($result.AdditionalErrorMessage)"
    }
    Wait-HotspotState -Manager $Manager -Wanted 'Off' | Out-Null
}

# --------------------------------------------------------------------- output

function Write-Status {
    param($Manager, $Uplink)

    $state = Get-HotspotState -Manager $Manager
    $config = $Manager.GetCurrentAccessPointConfiguration()

    $clientCount = 0
    try { $clientCount = @($Manager.GetTetheringClients() | Where-Object { $_.MacAddress }).Count } catch { }

    Write-Host ''
    Write-Host "  State      : $state"
    Write-Host "  SSID       : $($config.Ssid)"
    Write-Host "  Password   : $($config.Passphrase)"
    Write-Host "  Band       : $($config.Band)"
    Write-Host "  Sharing    : $($Uplink.Name)"
    Write-Host "  AP address : $(if (Test-ApAddress) { $script:ApAddress } else { 'not assigned' })"
    Write-Host "  Clients    : $clientCount"
    Write-Host "  Logon task : $(if (Test-LogonAutostart) { 'on' } else { 'off' })"
    Write-Host ''
}

function Get-NormalizedMac {
    param([string]$Mac)
    if (-not $Mac) { return '' }
    ($Mac -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
}

function Write-Devices {
    param($Manager)

    if ((Get-HotspotState -Manager $Manager) -eq 'Off') {
        Write-Host 'Hotspot is off. No devices.'
        return
    }

    $clients = @()
    try { $clients = @($Manager.GetTetheringClients() | Where-Object { $_.MacAddress }) } catch { }

    if (-not $clients) {
        Write-Host 'No devices connected.'
        return
    }

    $apIndex = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $script:ApAddress } |
        Select-Object -First 1).InterfaceIndex

    $neighbours = @()
    if ($apIndex) {
        $neighbours = Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $apIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne 'FF-FF-FF-FF-FF-FF' }
    }

    $rows = foreach ($client in $clients) {
        $mac = Get-NormalizedMac $client.MacAddress
        $ip = ($neighbours | Where-Object { (Get-NormalizedMac $_.LinkLayerAddress) -eq $mac } | Select-Object -First 1).IPAddress
        $names = ''
        try {
            # HostNames usually contains both the name and the assigned IP.
            $names = (@($client.HostNames) | Where-Object { $_ -and -not ($_ -as [System.Net.IPAddress]) }) -join ', '
        }
        catch { }

        [pscustomobject]@{
            MAC      = ($mac.ToUpperInvariant() -replace '(.{2})(?!$)', '$1:')
            IP       = if ($ip) { $ip } else { '-' }
            Hostname = if ($names) { $names } else { '-' }
        }
    }

    $rows | Format-Table -AutoSize | Out-String -Width 120 | Write-Host
}

# ---------------------------------------------------------------------- setup

function Set-AccessPoint {
    param($Manager, [string]$Ssid, [string]$Passphrase, [string]$Band)

    $config = $Manager.GetCurrentAccessPointConfiguration()
    $changed = $false

    if ($Ssid) { $config.Ssid = $Ssid; $changed = $true }
    if ($Passphrase) { $config.Passphrase = $Passphrase; $changed = $true }
    if ($Band) {
        $config.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand]$Band
        $changed = $true
    }

    if (-not $changed) {
        Write-Host 'Nothing to change.'
        return
    }

    $wasOn = (Get-HotspotState -Manager $Manager) -eq 'On'
    if ($wasOn) { Stop-Hotspot -Manager $Manager -Quiet }

    Await-Action ($Manager.ConfigureAccessPointAsync($config))

    $applied = $Manager.GetCurrentAccessPointConfiguration()
    if ($Ssid -and $applied.Ssid -ne $Ssid) { throw "SSID did not change (still '$($applied.Ssid)')." }
    if ($Passphrase -and $applied.Passphrase -ne $Passphrase) { throw 'Password did not change.' }
    if ($Ssid) { Write-Host "SSID       -> $($applied.Ssid)" }
    if ($Passphrase) { Write-Host "Password   -> $($applied.Passphrase)" }
    if ($Band) { Write-Host "Band       -> $($applied.Band)" }

    if ($wasOn) {
        Start-Hotspot -Manager $Manager -Quiet | Out-Null
        Write-Host 'Hotspot restarted with the new settings.'
    }
}

function New-RandomPassphrase {
    $alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $chars = -join (1..14 | ForEach-Object { $alphabet[(Get-Random -Minimum 0 -Maximum $alphabet.Length)] })
    "$chars!7"
}

# ---------------------------------------------------------------- logon task

$script:LogonTaskName = 'hotspot-cli'

function Test-LogonAutostart {
    [bool](Get-ScheduledTask -TaskName $script:LogonTaskName -ErrorAction SilentlyContinue)
}

function Enable-LogonAutostart {
    $scriptPath = $PSCommandPath
    $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $pwsh)) { $pwsh = (Get-Command powershell.exe).Source }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" on' -f $scriptPath

    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trigger.Delay = 'PT45S'
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $script:LogonTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the Windows Mobile Hotspot at logon (hotspot-cli)' -Force | Out-Null
    Write-Host "Logon task '$($script:LogonTaskName)' enabled. The hotspot will start ~45s after you sign in."
}

function Disable-LogonAutostart {
    if (Test-LogonAutostart) {
        Unregister-ScheduledTask -TaskName $script:LogonTaskName -Confirm:$false
        Write-Host "Logon task '$($script:LogonTaskName)' removed."
    }
    else {
        Write-Host 'Logon task is not set.'
    }
}

# ----------------------------------------------------------------------- help

function Write-Help {
    @"

hotspot - Windows Mobile Hotspot from the command line

  hotspot on                     start the hotspot (shares the wired uplink)
  hotspot off                    stop the hotspot
  hotspot restart                stop, then start
  hotspot status                 state, SSID, password, band, uplink, clients
  hotspot devices                connected devices with MAC and IP
  hotspot update ssid <name>     rename the network
  hotspot update password [pass] set the password (random if omitted)
  hotspot update band <2.4|5|6|auto>
  hotspot logon on|off           start the hotspot automatically at logon
  hotspot help                   this text

Options
  hotspot on -Uplink "Ethernet"  force a specific uplink profile

Notes
  * Uplink is picked automatically: Ethernet first, then Wi-Fi. VPN and
    tunnel adapters (WARP, Tailscale) are never used for sharing.
  * There is no boot-time autostart. The tethering API needs a logged-in
    desktop session, so 'logon' is the earliest possible point.
  * A client that keeps asking for the password, or spins on "obtaining IP",
    usually needs the network forgotten and re-added on the phone.

  $($script:RepoUrl)

"@ | Write-Host
}

# ----------------------------------------------------------------------- main

try {
    Initialize-WinRT

    $uplinkName = $null
    $arguments = @()
    if ($Value) { $arguments = @($Value) }

    # tiny option parser: --uplink / -Uplink
    $clean = @()
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        $arg = $arguments[$i]
        if ($arg -match '^--?uplink$' -and ($i + 1) -lt $arguments.Count) {
            $uplinkName = $arguments[$i + 1]
            $i++
            continue
        }
        $clean += $arg
    }

    switch ($Action.ToLowerInvariant()) {

        'on' {
            $uplink = Resolve-Uplink -Name $uplinkName
            $manager = Get-TetheringManager -Uplink $uplink
            Start-Hotspot -Manager $manager | Out-Null
            $config = $manager.GetCurrentAccessPointConfiguration()
            Write-Host "Hotspot on: $($config.Ssid)  (sharing $($uplink.Name), AP $($script:ApAddress))"
        }

        'off' {
            $uplink = Resolve-Uplink -Name $uplinkName
            $manager = Get-TetheringManager -Uplink $uplink
            Stop-Hotspot -Manager $manager
            Write-Host 'Hotspot off.'
        }

        'restart' {
            $uplink = Resolve-Uplink -Name $uplinkName
            $manager = Get-TetheringManager -Uplink $uplink
            Stop-Hotspot -Manager $manager -Quiet
            Start-Sleep -Milliseconds 500
            Start-Hotspot -Manager $manager -Quiet | Out-Null
            $config = $manager.GetCurrentAccessPointConfiguration()
            Write-Host "Hotspot restarted: $($config.Ssid)  (sharing $($uplink.Name))"
        }

        'status' {
            $uplink = Resolve-Uplink -Name $uplinkName
            $manager = Get-TetheringManager -Uplink $uplink
            Write-Status -Manager $manager -Uplink $uplink
        }

        'devices' {
            $uplink = Resolve-Uplink -Name $uplinkName
            $manager = Get-TetheringManager -Uplink $uplink
            Write-Devices -Manager $manager
        }

        'update' {
            if (-not $SubAction) { throw 'Usage: hotspot update <ssid|password|band> [value]' }

            $uplink = Resolve-Uplink -Name $uplinkName
            $manager = Get-TetheringManager -Uplink $uplink

            switch ($SubAction.ToLowerInvariant()) {
                'ssid' {
                    $newSsid = ($clean -join ' ').Trim()
                    if (-not $newSsid) { throw 'Usage: hotspot update ssid <name>  (1-32 characters)' }
                    if ($newSsid.Length -gt 32) { throw "SSID must be 1-32 characters (got $($newSsid.Length))." }
                    Set-AccessPoint -Manager $manager -Ssid $newSsid
                }
                'password' {
                    $newPass = ($clean -join ' ').Trim()
                    if (-not $newPass) {
                        $newPass = New-RandomPassphrase
                        Write-Host "Generated password: $newPass"
                    }
                    if ($newPass.Length -lt 8) { throw 'Password must be at least 8 characters.' }
                    if ($newPass.Length -gt 63) { throw 'Password must be at most 63 characters.' }
                    Set-AccessPoint -Manager $manager -Passphrase $newPass
                }
                'band' {
                    $bandArg = ($clean -join ' ').Trim()
                    $band = switch ($bandArg.ToLowerInvariant()) {
                        '2.4' { 'TwoPointFourGigahertz' }
                        '2.4ghz' { 'TwoPointFourGigahertz' }
                        '5' { 'FiveGigahertz' }
                        '5ghz' { 'FiveGigahertz' }
                        '6' { 'SixGigahertz' }
                        '6ghz' { 'SixGigahertz' }
                        'auto' { 'Auto' }
                        default { throw 'Usage: hotspot update band <2.4|5|6|auto>' }
                    }
                    Set-AccessPoint -Manager $manager -Band $band
                }
                default { throw "Unknown update target '$SubAction'. Use ssid, password or band." }
            }
        }

        'logon' {
            switch (("$SubAction").ToLowerInvariant()) {
                'on' { Enable-LogonAutostart }
                'off' { Disable-LogonAutostart }
                '' { Write-Host "Logon task: $(if (Test-LogonAutostart) { 'on' } else { 'off' })" }
                default { throw 'Usage: hotspot logon <on|off>' }
            }
        }

        'help' { Write-Help }
        '-h' { Write-Help }
        '--help' { Write-Help }

        default {
            Write-Host "Unknown command '$Action'."
            Write-Help
            exit 1
        }
    }

    exit 0
}
catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
