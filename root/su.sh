#!/system/bin/sh
# root/su.sh — convenience wrapper for the GhostLock-rooted Honor X50
# Must run AFTER root_setup.ps1 has set up /data/local/tmp/su
#
# Usage:
#   adb shell sh /data/local/tmp/su.sh id
#   adb shell sh /data/local/tmp/su.sh    # interactive root shell via stdin
SU=/data/local/tmp/su
if [ ! -x "$SU" ]; then
    echo "ERROR: $SU not found. Run root_setup.ps1 first." >&2
    exit 1
fi
exec "$SU" "$@"