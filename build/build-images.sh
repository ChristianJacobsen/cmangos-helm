#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

die() { echo "error: $*" >&2; exit 1; }

EXPANSION="${EXPANSION:-classic}"
case "$EXPANSION" in
  classic) CLIENT="1.12.1 (Classic)" ;;
  tbc)     CLIENT="2.4.3 (The Burning Crusade)" ;;
  wotlk)   CLIENT="3.3.5a (Wrath of the Lich King)" ;;
  *) die "EXPANSION must be classic, tbc or wotlk" ;;
esac
description() {
  case "$1" in
    server) echo "CMaNGOS mangosd, realmd and map extractors for World of Warcraft $CLIENT" ;;
    db)     echo "CMaNGOS database installer for World of Warcraft $CLIENT" ;;
  esac
}

# Sourcing sources.env overwrites this, so keep the override first.
env_bots="${PLAYERBOTS_REF:-}"
# shellcheck disable=SC1091
. "$BUILD_DIR/sources.env"
PLAYERBOTS_REF="${env_bots:-$PLAYERBOTS_REF}"
pin_prefix="$(printf '%s' "$EXPANSION" | tr '[:lower:]' '[:upper:]')"
core_pin="${pin_prefix}_CORE_REF"
db_pin="${pin_prefix}_DB_REF"
CORE_REF="${CORE_REF:-${!core_pin}}"
DB_REF="${DB_REF:-${!db_pin}}"

CORE_REPO="https://github.com/cmangos/mangos-$EXPANSION.git"
DB_REPO="https://github.com/cmangos/$EXPANSION-db.git"
PLAYERBOTS_REPO="https://github.com/cmangos/playerbots.git"
IMAGE_PREFIX="cmangos-$EXPANSION"

SHA_LENGTH=40
SHORT_SHA_LENGTH=7

# The image tag and labels record commits, not branch names.
resolve() {
  local repo="$1" ref="$2" sha
  case "$ref" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      if [ "${#ref}" = "$SHA_LENGTH" ]; then echo "$ref"; return; fi ;;
  esac
  sha="$(git ls-remote "$repo" "$ref" "refs/tags/$ref^{}" | awk 'NR==1 {print $1}')"
  [ -n "$sha" ] || die "cannot resolve $ref in $repo"
  echo "$sha"
}
CORE_REF="$(resolve "$CORE_REPO" "$CORE_REF")"
DB_REF="$(resolve "$DB_REPO" "$DB_REF")"
PLAYERBOTS_REF="$(resolve "$PLAYERBOTS_REPO" "$PLAYERBOTS_REF")"

REGISTRY="${REGISTRY:-local}"
TAG="${TAG:-$(date -u +%Y%m%d)-$(printf '%s' "$CORE_REF" | cut -c1-"$SHORT_SHA_LENGTH")}"
PUSH="${PUSH:-0}"
BUILD_JOBS="${BUILD_JOBS:-0}"
TARGETS="${TARGETS:-server db}"
CACHE_REF="${CACHE_REF:-}"

case "$(uname -m)" in
  arm64|aarch64) HOST_PLATFORM=linux/arm64 ;;
  *)             HOST_PLATFORM=linux/amd64 ;;
esac
PLATFORMS="${PLATFORMS:-$HOST_PLATFORM}"

MULTI_ARCH=0
case "$PLATFORMS" in *,*) MULTI_ARCH=1 ;; esac
if [ "$MULTI_ARCH" = "1" ] && [ "$PUSH" != "1" ]; then
  die "multi-platform builds require PUSH=1 (docker cannot --load multi-arch images)"
fi

# The default docker driver cannot build multi-platform images or export a cache.
BUILDER_ARGS=""
if [ "$MULTI_ARCH" = "1" ] || [ -n "$CACHE_REF" ]; then
  docker buildx inspect cmangos >/dev/null 2>&1 || docker buildx create --name cmangos --driver docker-container
  BUILDER_ARGS="--builder cmangos"
fi

OUTPUT="--load"
[ "$PUSH" = "1" ] && OUTPUT="--push"

origin_url() {
  local url
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)" || return 0
  url="${url%.git}"
  case "$url" in
    git@*) url="${url#git@}"; url="https://${url/://}" ;;
  esac
  printf '%s\n' "$url"
}
# GHCR links a package to the repository in org.opencontainers.image.source.
IMAGE_SOURCE="${IMAGE_SOURCE:-$(origin_url)}"
IMAGE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"

echo "==> core        $CORE_REPO @ $CORE_REF"
echo "==> world db    $DB_REPO @ $DB_REF"
echo "==> playerbots  $PLAYERBOTS_REPO @ $PLAYERBOTS_REF"
echo "==> images      $REGISTRY/$IMAGE_PREFIX-{$(echo "$TARGETS" | tr ' ' ',')}:$TAG"
echo "==> platforms   $PLATFORMS (push=$PUSH)"

CREATED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
for target in $TARGETS; do
  cache_args=""
  if [ -n "$CACHE_REF" ]; then
    cache_args="--cache-from type=registry,ref=$CACHE_REF-$target"
    cache_args="$cache_args --cache-to type=registry,ref=$CACHE_REF-$target,mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true"
  fi
  labels=(
    --label "org.opencontainers.image.created=$CREATED"
    --label "org.opencontainers.image.version=$TAG"
    --label "org.opencontainers.image.title=$IMAGE_PREFIX-$target"
    --label "org.opencontainers.image.description=$(description "$target")"
    --label "net.cmangos.expansion=$EXPANSION"
    --label "net.cmangos.core.revision=$CORE_REF"
    --label "net.cmangos.$EXPANSION-db.revision=$DB_REF"
    --label "net.cmangos.playerbots.revision=$PLAYERBOTS_REF"
  )
  [ -n "$IMAGE_SOURCE" ] && labels+=(--label "org.opencontainers.image.source=$IMAGE_SOURCE")
  [ -n "$IMAGE_REVISION" ] && labels+=(--label "org.opencontainers.image.revision=$IMAGE_REVISION")
  echo "==> building $target"
  # shellcheck disable=SC2086
  docker buildx build $BUILDER_ARGS $cache_args "$BUILD_DIR" \
    --file "$BUILD_DIR/Dockerfile" \
    --target "$target" \
    --platform "$PLATFORMS" \
    --build-arg "EXPANSION=$EXPANSION" \
    --build-arg "CORE_REPO=$CORE_REPO" \
    --build-arg "CORE_REF=$CORE_REF" \
    --build-arg "DB_REPO=$DB_REPO" \
    --build-arg "DB_REF=$DB_REF" \
    --build-arg "PLAYERBOTS_REF=$PLAYERBOTS_REF" \
    --build-arg "BUILD_JOBS=$BUILD_JOBS" \
    "${labels[@]}" \
    --tag "$REGISTRY/$IMAGE_PREFIX-$target:$TAG" \
    $OUTPUT
done

registry_host="${REGISTRY%%/*}"
repo_prefix="${REGISTRY#*/}"
[ "$repo_prefix" = "$REGISTRY" ] && repo_prefix=""

GENERATED="$BUILD_DIR/images.generated.yaml"
{
  echo "# Generated by build-images.sh on $CREATED"
  echo "# core $CORE_REF, $EXPANSION-db $DB_REF, playerbots $PLAYERBOTS_REF"
  echo "expansion: $EXPANSION"
  echo "images:"
  echo "  $EXPANSION:"
  for target in server db; do
    printf '    %s:\n      registry: %s\n      repository: %s%s%s\n      tag: "%s"\n      digest: ""\n' \
      "$target" "$registry_host" "$repo_prefix" "${repo_prefix:+/}" "$IMAGE_PREFIX-$target" "$TAG"
  done
} > "$GENERATED"

echo "==> wrote $GENERATED"
cat "$GENERATED"
