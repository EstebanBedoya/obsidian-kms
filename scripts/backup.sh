#!/bin/bash
# Daily backup of the CouchDB data volume for obsidian-kms (runs on the VPS, as root).
# CouchDB files are append-only, so copying them while the server runs is safe.
# Install: see README ("Backup y restauración"). Config via env or the defaults below.
set -euo pipefail

VOL="${VOL:-compose-navigate-neural-alarm-rmwayh_couchdb_data}"
DEST="${DEST:-/var/backups/obsidian-kms}"
KEEP_DAYS="${KEEP_DAYS:-14}"
SRC="/var/lib/docker/volumes/${VOL}/_data"

umask 077
mkdir -p "$DEST"

if [ ! -d "$SRC" ]; then
  echo "ERROR: volume data not found: $SRC (did the Dokploy appName change?)" >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$DEST/couchdb-$TS.tgz"

tar czf "$OUT.tmp" -C "$SRC" .
tar tzf "$OUT.tmp" >/dev/null          # integrity check before keeping it
mv "$OUT.tmp" "$OUT"
( cd "$DEST" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )

# Retention: only this script's own files, only inside $DEST.
find "$DEST" -maxdepth 1 -type f \( -name 'couchdb-*.tgz' -o -name 'couchdb-*.tgz.sha256' \) -mtime +"$KEEP_DAYS" -delete

echo "$(date -u +%FT%TZ) ok $OUT $(du -h "$OUT" | cut -f1) (kept: $(find "$DEST" -maxdepth 1 -name 'couchdb-*.tgz' | wc -l))"
