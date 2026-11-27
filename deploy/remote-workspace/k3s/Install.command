#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ "$(id -u)" != 0 ]; then exec /usr/bin/sudo /bin/sh "./$(basename "$0")"; fi
dest=/Library/KolmogorWorker
label=com.kolmogor.vm-worker
plist=/Library/LaunchDaemons/$label.plist
for f in worker ssh_config known_hosts key token; do test -s "$f"; done
launchctl bootout "system/$label" 2>/dev/null || :
install -d -o root -g wheel -m 0755 "$dest"
for f in ssh_config known_hosts worker; do install -o root -g wheel -m 0555 "$f" "$dest/$f"; done
for f in token key; do install -o nobody -g nobody -m 0400 "$f" "$dest/$f"; done
cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.kolmogor.vm-worker</string>
<key>ProgramArguments</key><array><string>/Library/KolmogorWorker/worker</string></array>
<key>UserName</key><string>nobody</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
PLIST
chown root:wheel "$plist"; chmod 0644 "$plist"; plutil -lint "$plist"
launchctl bootstrap system "$plist"
launchctl print "system/$label" | head -12
printf 'Guest boot UUID: %s\n' "$(/usr/sbin/sysctl -n kern.bootsessionuuid)"
