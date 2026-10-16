#!/bin/bash
# Pull the VPS CouchDB backups to Disk X (runs on the Mac, scheduled by launchd).
# Skips quietly when the disk is not mounted; it catches up on the next run.
set -euo pipefail

REMOTE="${REMOTE:-vps}"                                  # ssh alias from ~/.ssh/config
REMOTE_DIR="${REMOTE_DIR:-/var/backups/obsidian-kms/}"
DISK="${DISK:-/Volumes/Disk X}"
DEST="${DEST:-$DISK/Backups/obsidian-kms}"
KEEP_DAYS="${KEEP_DAYS:-60}"

log() { echo "$(date '+%F %T') $*"; }

if [ ! -d "$DISK" ]; then
  log "SKIP: $DISK not mounted"
  exit 0
fi

mkdir -p "$DEST"
rsync -rt -e "ssh -o BatchMode=yes -o ConnectTimeout=20" "$REMOTE:$REMOTE_DIR" "$DEST/"

# Verify every copy against its checksum (files are small).
cd "$DEST"
bad=0
for s in couchdb-*.tgz.sha256; do
  [ -e "$s" ] || continue
  shasum -a 256 -c "$s" >/dev/null 2>&1 || { log "ERROR: checksum failed for $s"; bad=1; }
done
[ "$bad" -eq 0 ] || exit 1

# Retention: only this script's own files, only inside $DEST.
find "$DEST" -maxdepth 1 -type f \( -name 'couchdb-*' -o -name '._couchdb-*' \) -mtime +"$KEEP_DAYS" -delete

log "ok: $(find "$DEST" -maxdepth 1 -name 'couchdb-*.tgz' | wc -l | tr -d ' ') copies in $DEST, latest: $(basename "$(ls -t "$DEST"/couchdb-*.tgz | head -1)")"
