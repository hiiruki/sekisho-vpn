#!/bin/sh
# Removes Sekisho's helper (and the pre-rename one, if still there). Run as root.
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for LABEL in moe.hiiruki.sekisho.helper com.sstpvpn.sstpd; do
  launchctl bootout system/$LABEL 2>/dev/null
  rm -f /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL
done
rm -f /var/run/sekisho.sock /var/run/sstpd.sock
echo "Sekisho helper removed"
