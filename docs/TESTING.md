# Release test

CI runs `selftest` (protocol and validation) and `e2e` (a real tunnel against a local SoftEther server). What needs a
real VPN server, Wi-Fi changes or a person at the Mac is below: about 15 minutes, after installing the new build.

| # | Do | Expect |
|---|---|---|
| 1 | Open the new version | **Update the helper?** appears once; after the admin prompt the window shows no helper banner |
| 2 | Connect (full tunnel) | Notification *Connected to …*; latency in the window and menu bar; ↑/↓ speeds in the menu bar |
| 3 | Split tunnel: `intranet.example.com` (an internal host), DNS domains empty; connect | Log `intranet.example.com → 10.…`; `route -n get intranet.example.com` shows `utunN`; `route -n get 1.1.1.1` shows your Wi-Fi; the internal site opens |
| 4 | Health check: an internal `host:443` | ✓ in window and menu bar. Change it to `host:1`: ✗, and after ~90 s the log says *Health check failed* and it reconnects |
| 5 | Full tunnel + kill switch; connect, then turn Wi-Fi off and on | While reconnecting: *Can't reach the VPN server…* with **Open Login Page**; clicking it opens captive.apple.com and shows *paused until …*; `sudo pfctl -a com.apple/sekisho.killswitch -sr` is empty until the VPN is back |
| 6 | **Diagnostics…** | One `.log` with Status (including `certExpires`), profile, `netstat`, `scutil --dns`, `ifconfig`, log; `grep -i password` finds only the empty field |
| 7 | Quit the app while connected, disconnect with the hotkey from a relaunched app, then reopen **Session History** | Sessions from while the app was closed are listed; *Dropped: …* for drops, with the reason |
| 8 | **File → Export Profile…**, then **Import Profile…** the file | The file has no password; import asks for confirmation (showing a pinned certificate, if any) and adds *… (imported)* |
| 9 | `open "sekisho://toggle"`, then `open "sekisho://connect?profile=nope"` | The VPN toggles; then a notification *Unknown profile* |
| 10 | ⌃⌥⌘V in another app | The VPN toggles |
| 11 | VoiceOver (⌘F5) over the profile buttons and the menu bar item | *Add profile*, *Remove this profile*, *Share profiles*; the menu bar item reads its state and speeds |
| 12 | System Settings → General → Language & Region → Applications: Sekisho → Indonesian; relaunch | Window, menu bar, alerts and notifications in Bahasa Indonesia |
| 13 | **Sekisho → Uninstall Helper…** | After confirming and the admin prompt: *Install Helper…* banner; `/var/db/sekisho.sessions.json` is gone; install again |
| 14 | On the previous version: **Check for Updates…** | The update dialog lists the release notes |
