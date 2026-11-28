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
| 9 | While connected: `open "sekisho://toggle"`, then `open "sekisho://connect?profile=nope"` | *Disconnect the VPN?* first (Cancel keeps it up; *Don't ask again for links* skips it later); then a notification *Unknown profile* |
| 10 | ⌃⌥⌘V in another app | The VPN toggles |
| 11 | VoiceOver (⌘F5) over the profile buttons and the menu bar item | *Add profile*, *Remove this profile*, *Share profiles*; the menu bar item reads its state and speeds |
| 12 | System Settings → General → Language & Region → Applications: Sekisho → Indonesian, then Japanese; relaunch each time | Window, menu bar, alerts and notifications in that language |
| 13 | **Sekisho → Uninstall Helper…** | After confirming and the admin prompt: *Install Helper…* banner; `/var/db/sekisho.sessions.json` is gone; install again |
| 14 | On the previous version: **Check for Updates…** | The update dialog lists the release notes |
| 15 | Turn off **Remember password**, connect | The password is asked for; `security find-generic-password -s com.sstpvpn.client -a <profile id>` finds nothing |
| 16 | Turn on **Ask for a one-time code** (server with OTP), connect | Password (if not remembered) and code are asked for; the server accepts password + code |
| 17 | Two profiles; connected to one, menu bar → **Switch to** the other | It disconnects, then connects to the other |
| 18 | **Auto-connect on Wi-Fi**: the current Wi-Fi name on a second profile; turn auto-connect off and on | It connects with that profile |
| 19 | Stop the server or block it while connected (or enter a wrong password and connect) | Notification with **Connect Again**; on a kill-switch profile, *Connection lost* with **Open Login Page** |
| 20 | **Session History → Export CSV…** | One line per session, oldest first; opens in Numbers or Excel |
| 21 | `DYLD_INSERT_LIBRARIES=<any dylib> /Applications/Sekisho.app/Contents/MacOS/SSTPClient` | The library is not loaded (hardened runtime) |
| 22 | Connected (full tunnel), then **Quit** from the menu bar, and again with ⌘Q | The VPN disconnects before the app exits: no `utunN` with an address in `ifconfig`, `netstat -rn` has no `0/1` route |
| 23 | Window → **Shortcut**: record a new one (e.g. ⌃⌥⌘K), use it in another app; then **Turn Off** | The new shortcut toggles the VPN and ⌃⌥⌘V no longer does; turned off, neither does |
| 24 | Connect, watch the menu bar; then lose the network on a kill-switch profile | Half shield while connecting, speeds when connected, exclamation shield while the kill switch holds |
| 25 | On an Intel Mac: install the DMG, install the helper, connect | Same as on Apple silicon (`lipo -archs` lists x86_64 arm64) |
| 26 | Connected, then `killall -9 SSTPClient` (do not reopen) | After ~30 s the VPN is down: no `utunN` with an address, the helper log says *No Sekisho app connected for 30 s*. Reopening within 30 s keeps it up |
| 27 | Connected, then log out (or fast-switch to another user) | The VPN is down for the next user; the helper log says *no longer at the console* |
| 28 | Full tunnel, **Bypass the VPN**: a subnet and a hostname (e.g. `zoom.us`); connect | `route -n get <an address in the subnet>` and `route -n get zoom.us` show your Wi-Fi, `route -n get 1.1.1.1` shows `utunN`; a Discord or Zoom call over a bypassed range sounds normal. With the kill switch on, the profile shows an error instead |
