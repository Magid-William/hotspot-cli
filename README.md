# hotspot-cli

A small command-line front end for the **Windows 11 Mobile Hotspot**, so you can stop clicking through Settings.

```powershell
hotspot on
hotspot off
hotspot status
hotspot devices
```

Windows ships no CLI for the built-in Mobile Hotspot, and the old `netsh wlan start hostednetwork` recipe is dead on modern WLAN drivers (most Intel/Qualcomm cards report `Hosted network supported: No`). This script drives the same WinRT API the Settings page uses:

```
Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager
```

**Requirements:** Windows 10/11, PowerShell 5.1, a Wi-Fi adapter that supports Mobile Hotspot (every adapter that shows the Mobile Hotspot toggle in Settings qualifies), and an interactive desktop session.

## Install

```powershell
git clone https://github.com/Magid-William/hotspot-cli.git
cd hotspot-cli
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That copies `hotspot.ps1` and `hotspot.cmd` into `%USERPROFILE%\bin` and adds that folder to your user `PATH`. Open a new terminal afterwards.

Use `-Link` to hard-link instead of copy, so repo edits are live:

```powershell
.\install.ps1 -Link
```

Or just run it in place:

```powershell
.\hotspot.ps1 on
```

## Commands

| Command | What it does |
|---|---|
| `hotspot on` | Starts the hotspot, sharing the wired uplink |
| `hotspot off` | Stops the hotspot |
| `hotspot restart` | Stop, then start (the fix for a stale AP) |
| `hotspot status` | State, SSID, password, band, uplink, AP address, client count |
| `hotspot devices` | Connected devices: MAC, IP, hostname |
| `hotspot update ssid <name>` | Rename the network (1-32 chars) |
| `hotspot update password [pass]` | Set the password; generates a random 15-char one if omitted |
| `hotspot update band <2.4\|5\|6\|auto>` | Pick the radio band |
| `hotspot logon on\|off` | Start the hotspot automatically ~45s after you sign in |
| `hotspot uninstall` | Remove the installed copy and the logon task |
| `hotspot help` | Usage (also what you get for bare `hotspot`) |

Force a specific uplink profile:

```powershell
hotspot on -Uplink "Ethernet"
```

## How it picks the uplink

This is the part that matters if you run a VPN. `GetInternetConnectionProfile()` happily returns a tunnel adapter, and sharing that gives clients either no internet or a weird double-NAT path.

The script instead enumerates connection profiles and:

1. skips anything with `IanaInterfaceType 53` (tunnels: Cloudflare WARP, Tailscale, OpenVPN...),
2. requires the profile to report `InternetAccess`,
3. prefers Ethernet (30), then Wi-Fi (20), then anything else (10).

So with WARP connected and a cable plugged in, it shares the cable.

## Autostart

`hotspot logon on` registers a Task Scheduler task named `hotspot-cli`:

- trigger: at logon for the current user, delayed 45 seconds
- runs hidden, `-WindowStyle Hidden`, current user privileges, no stored password
- harmless if the uplink is not ready yet: `hotspot on` is idempotent, and you can always run it again

There is deliberately **no boot-time ("at startup") option**. The tethering API needs a logged-in desktop session with a running Wi-Fi stack, so a SYSTEM/service context cannot start it. `logon` is the earliest point that actually works.

Remove it with `hotspot logon off`.

## Tests

No Pester needed (Windows only ships the ancient 3.4.0), no network access, works on PowerShell 5.1 and 7:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\hotspot.tests.ps1
```

36 unit tests covering MAC normalisation, password generation, SSID/passphrase validation, band mapping, uplink scoring, help text and CLI exit codes.

The integration suite actually stops and starts the hotspot, so it drops connected clients and is opt-in:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\hotspot.tests.ps1 -Integration
```

It captures the starting state and puts it back in a `finally` block, so you are left with the hotspot exactly as you found it.

## Troubleshooting

**"Hotspot is on, but the phone says connected, no internet"**
Check `hotspot status` and confirm `Sharing` is your real uplink and not a VPN. If it says `CloudflareWARP`, force the right one: `hotspot on -Uplink "Ethernet"`.

**Phone keeps asking for the password or hangs on "obtaining IP address"**
Windows stored credentials and the phone's saved entry disagree. Forget the network on the phone, then run `hotspot restart` and rejoin with the password from `hotspot status`.

**"Hotspot did not come up (no 192.168.137.1 assigned)"**
Windows sometimes reports success without assigning the gateway. The script already retries once; if it still fails, disable and re-enable the Wi-Fi adapter and run `hotspot on` again.

**`hotspot` is not recognized**
The `PATH` change only applies to terminals opened after `install.ps1` ran. Open a new window, or run `.\hotspot.ps1` directly.

**Started from a service or over SSH**
Will not work. Needs an interactive session.

## Uninstall

```powershell
hotspot uninstall
```

Removes the installed `hotspot.ps1` / `hotspot.cmd` and the `hotspot-cli` logon task if it exists. It leaves `%USERPROFILE%\bin` on your `PATH` (that folder is yours, not ours) and does not stop a hotspot that is currently running.

If you want to do it by hand, or the tool is already gone:

```powershell
schtasks /delete /tn hotspot-cli /f
Remove-Item "$env:USERPROFILE\bin\hotspot.ps1", "$env:USERPROFILE\bin\hotspot.cmd"
```

## License

MIT, see [LICENSE](LICENSE).
