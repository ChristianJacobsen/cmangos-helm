#!/usr/bin/env bash
# The mangosd init container in the chart waits for $DATA_DIR/.cmangos/ready.
set -euo pipefail

log() { printf '==> %s: %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

EXPANSION="${CMANGOS_EXPANSION:?CMANGOS_EXPANSION is required}"
CLIENT_DIR="${CLIENT_DIR:-/client}"
DATA_DIR="${DATA_DIR:-/opt/cmangos/data}"
DATA_URL="${DATA_URL:-}"
CLIENT_URL="${CLIENT_URL:-}"
SCRATCH_DIR="${SCRATCH_DIR:-/scratch}"
EXTRACT_VMAPS="${EXTRACT_VMAPS:-1}"
EXTRACT_MMAPS="${EXTRACT_MMAPS:-1}"
MMAP_THREADS="${MMAP_THREADS:-0}"
HIGH_RES_MAPS="${HIGH_RES_MAPS:-0}"
HIGH_RES_VMAPS="${HIGH_RES_VMAPS:-0}"
FORCE="${FORCE:-0}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-5}"
DOWNLOAD_RETRY_DELAY_SECONDS="${DOWNLOAD_RETRY_DELAY_SECONDS:-10}"

TOOLS=/opt/cmangos/bin/tools
STATE="$DATA_DIR/.cmangos"
REVISION="$(cat /opt/cmangos/REVISION 2>/dev/null || echo unknown)"

[ -d "$DATA_DIR" ] || die "DATA_DIR $DATA_DIR does not exist"
[ -w "$DATA_DIR" ] || die "DATA_DIR $DATA_DIR is not writable by uid $(id -u)"
mkdir -p "$STATE"

if [ "$FORCE" = 1 ]; then
  log "FORCE=1: discarding the markers of earlier runs"
  rm -f "$STATE"/*
fi

recorded=""
if [ -f "$STATE/expansion" ]; then
  recorded="$(cat "$STATE/expansion")"
elif [ -f "$STATE/maps" ] || [ -f "$STATE/download" ]; then
  # Volumes from before the expansion marker hold Classic data.
  recorded=classic
fi
if [ -n "$recorded" ] && [ "$recorded" != "$EXPANSION" ]; then
  die "the data volume holds $recorded data, but this image is for $EXPANSION. Use another data volume, or set FORCE=1 to extract again."
fi

done_step() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$REVISION" > "$STATE/$1"
  printf '%s\n' "$EXPANSION" > "$STATE/expansion"
}
has_step() { [ -f "$STATE/$1" ]; }

# tar cannot detect the compression of a stream, so take it from the URL.
tar_flags() {
  case "${1%%\?*}" in
    *.tar.gz|*.tgz)   echo "-xzf" ;;
    *.tar.xz|*.txz)   echo "-xJf" ;;
    *.tar.bz2|*.tbz2) echo "-xjf" ;;
    *.tar)            echo "-xf" ;;
    *) return 1 ;;
  esac
}

# Tar archives stream, so only the unpacked files need space. unzip needs the
# archive as a file.
fetch() {
  local url="$1" dest="$2" flags
  mkdir -p "$dest"
  if flags="$(tar_flags "$url")"; then
    curl --fail --location --retry "$DOWNLOAD_RETRIES" --retry-delay "$DOWNLOAD_RETRY_DELAY_SECONDS" \
      --silent --show-error "$url" \
      | tar "$flags" - -C "$dest"
  else
    case "${url%%\?*}" in
      *.zip) ;;
      *) die "unknown archive type: $url (want .tar, .tar.gz, .tgz, .tar.xz, .tar.bz2 or .zip)" ;;
    esac
    curl --fail --location --retry "$DOWNLOAD_RETRIES" --retry-delay "$DOWNLOAD_RETRY_DELAY_SECONDS" \
      --silent --show-error --output "$dest/.download.zip" "$url"
    unzip -q -o "$dest/.download.zip" -d "$dest"
    rm -f "$dest/.download.zip"
  fi
}

finish() {
  # The volume root can belong to root, so change only its contents. The
  # servers run as this uid anyway.
  chmod -R a+rX -- "$DATA_DIR"/* 2>/dev/null || true
  du -sh "$DATA_DIR"/* 2>/dev/null || true
  printf '%s mode=%s revision=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$REVISION" > "$STATE/ready"
  log "data is ready"
}

if [ -n "$DATA_URL" ]; then
  if has_step download; then
    log "download: done earlier"
    finish download
    exit 0
  fi
  log "downloading and unpacking $DATA_URL"
  fetch "$DATA_URL" "$DATA_DIR"
  # Accept archives with a single top-level folder around dbc/ and maps/.
  if [ ! -d "$DATA_DIR/dbc" ]; then
    inner="$(find "$DATA_DIR" -mindepth 2 -maxdepth 2 -type d -name dbc -not -path "$STATE/*" | head -1)"
    [ -n "$inner" ] || die "the archive has no dbc/ directory"
    log "moving $(dirname "$inner") up to $DATA_DIR"
    (cd "$(dirname "$inner")" && for d in *; do rm -rf "${DATA_DIR:?}/$d"; mv "$d" "$DATA_DIR/"; done)
    rmdir "$(dirname "$inner")" 2>/dev/null || true
  fi
  for d in dbc maps; do
    [ -d "$DATA_DIR/$d" ] || die "the archive has no $d/ directory"
  done
  done_step download
  finish download
  exit 0
fi

# The mmap step reads only maps and vmaps. The client is needed only when
# the maps or the vmaps are missing.
needs_client=0
has_step maps || needs_client=1
if [ "$EXTRACT_VMAPS" = 1 ] && ! has_step vmaps; then needs_client=1; fi

if [ "$needs_client" = 1 ] && [ -n "$CLIENT_URL" ] && [ ! -d "$CLIENT_DIR/Data" ]; then
  if [ ! -d "$SCRATCH_DIR" ] || [ ! -w "$SCRATCH_DIR" ]; then
    die "SCRATCH_DIR $SCRATCH_DIR is missing or not writable"
  fi
  log "downloading the client from $CLIENT_URL"
  rm -rf "${SCRATCH_DIR:?}/client"
  fetch "$CLIENT_URL" "$SCRATCH_DIR/client"
  data="$(find "$SCRATCH_DIR/client" -maxdepth 3 -type d -name Data | head -1)"
  [ -n "$data" ] || die "the client archive has no Data folder (the name is case-sensitive)"
  CLIENT_DIR="$(dirname "$data")"
  log "client folder: ${CLIENT_DIR#"$SCRATCH_DIR"/}"
fi
if [ "$needs_client" = 1 ] && [ ! -d "$CLIENT_DIR/Data" ]; then
  die "no Data folder in $CLIENT_DIR. Mount the client folder that contains Data/ (the name is case-sensitive), or set CLIENT_URL."
fi
cd "$DATA_DIR"

if has_step maps; then
  log "dbc and maps: done earlier"
else
  log "extracting dbc and maps"
  args=(-i "$CLIENT_DIR" -o "$DATA_DIR")
  # -f 0: store heights as floats instead of integers.
  [ "$HIGH_RES_MAPS" = 1 ] && args+=(-f 0)
  "$TOOLS/ad" "${args[@]}"
  done_step maps
fi

if [ "$EXTRACT_VMAPS" != 1 ]; then
  log "vmaps: skipped (EXTRACT_VMAPS=$EXTRACT_VMAPS)"
elif has_step vmaps; then
  log "vmaps: done earlier"
else
  log "extracting vmaps"
  rm -rf "$DATA_DIR/Buildings"
  args=(-d "$CLIENT_DIR/Data" -o "$DATA_DIR")
  # -l: precise vector data, about 500 MB more vmaps.
  [ "$HIGH_RES_VMAPS" = 1 ] && args+=(-l)
  "$TOOLS/vmap_extractor" "${args[@]}"
  log "assembling vmaps"
  mkdir -p "$DATA_DIR/vmaps"
  "$TOOLS/vmap_assembler" "$DATA_DIR/Buildings" "$DATA_DIR/vmaps"
  done_step vmaps
fi

if [ "$EXTRACT_MMAPS" != 1 ]; then
  log "mmaps: skipped (EXTRACT_MMAPS=$EXTRACT_MMAPS)"
elif has_step mmaps; then
  log "mmaps: done earlier"
else
  has_step vmaps || die "mmaps need vmaps. Set EXTRACT_VMAPS=1."
  threads="$MMAP_THREADS"
  [ "$threads" != 0 ] || threads="$(nproc)"
  log "generating mmaps with $threads threads (this step takes a long time)"
  mkdir -p "$DATA_DIR/mmaps"
  "$TOOLS/MoveMapGen" --silent \
    --configInputPath "$TOOLS/config.json" \
    --offMeshInput "$TOOLS/offmesh.txt" \
    --workdir "$DATA_DIR/" \
    --threads "$threads" \
    --buildGameObjects
  done_step mmaps
fi

# vmap_assembler reads Buildings/. MoveMapGen reads the vmaps. After both, the
# raw building models are no longer needed.
rm -rf "$DATA_DIR/Buildings"
[ -z "$CLIENT_URL" ] || rm -rf "${SCRATCH_DIR:?}/client"
finish extract
