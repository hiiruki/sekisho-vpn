#!/bin/sh
# Installs Sekisho's helper (sstpd) as a root launchd daemon. Run as root: sudo scripts/install-daemon.sh .build/release/sstpd
set -e
SRC="${1:?usage: install-daemon.sh /path/to/sstpd}"
LABEL=moe.hiiruki.sekisho.helper
DEST=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
LOG=/var/log/sekisho.log
OLD=com.sstpvpn.sstpd # helper label before the Sekisho rename

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# remove the pre-rename helper; stopping it reverts its routes/DNS/pf first
if [ -f /Library/LaunchDaemons/$OLD.plist ]; then
  launchctl bootout system/$OLD 2>/dev/null || true
  i=0
  while launchctl print system/$OLD >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  rm -f /Library/LaunchDaemons/$OLD.plist /Library/PrivilegedHelperTools/$OLD /var/run/sstpd.sock
fi

# root-owned copy: a user-writable daemon binary would be a local privilege escalation
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$SRC" "$DEST"

# Only the app this script ships in may control the helper: pin its designated requirement (code signature).
# A dev install from the repo (no enclosing .app) keeps the old rule: any process of the console user.
ARGS="<string>$DEST</string>"
APP=$(cd "$(dirname "$0")/../.." && pwd)
case "$APP" in *.app)
  REQ=$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')
  [ -n "$REQ" ] || { echo "cannot read the code signature of $APP" >&2; exit 1; }
  ARGS="$ARGS<string>--client-requirement</string><string>$REQ</string>" ;;
esac

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>$ARGS</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>StandardOutPath</key><string>$LOG</string>
</dict></plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# bootout returns before the old daemon exits (it tears the tunnel down first, up to ~3s);
# bootstrapping while it is still registered fails with "5: Input/output error".
launchctl bootout system/$LABEL 2>/dev/null || true
i=0
while launchctl print system/$LABEL >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
launchctl bootstrap system "$PLIST"
echo "Sekisho helper installed; log: $LOG"
