#!/usr/bin/env bash
#
# Rebuild the XL1 node image so it does not sit unpatched for years.
#
# It BUILDS ONLY. It never retags xl1:local, never stops a container, and never
# restarts the producer. Swapping the image a live block producer runs on is a
# decision for a human at a time of their choosing, not something to discover
# happened overnight. The new image is tagged by version and left ready.
#
# Promotion, when you want it:
#
#   docker tag xl1:<version> xl1:local
#   docker rm -f xl1-producer
#   docker run -d --name xl1-producer --restart unless-stopped \
#     --env-file /opt/xl1-docker-images/sequence-producer.env xl1:local
#
# Roll back by tagging the previous version and repeating.
#
set -euo pipefail

REPO="${XL1_IMAGES_REPO:-/opt/xl1-docker-images}"
REPO_URL="${XL1_IMAGES_URL:-https://github.com/XYOracleNetwork/xl1-docker-images.git}"
REGISTRY="${XL1_CLI_REGISTRY:-https://registry.npmjs.org/@xyo-network/xl1-cli/latest}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
fail() { log "FAILED: $*"; exit 1; }

command -v docker >/dev/null || fail "docker not found"
command -v curl >/dev/null || fail "curl not found"

# --- what is current -------------------------------------------------------
LATEST="$(curl -fsSL --max-time 30 "$REGISTRY" \
  | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$LATEST" ] || fail "could not read the latest CLI version from the registry"

# $LATEST comes from a public registry and is interpolated into a docker
# --build-arg, which the Dockerfile expands inside a quoted shell command:
#   RUN npm install -g "@xyo-network/xl1-cli@${XL1_CLI_VERSION}"
# A quote or semicolon in that value would break out of those quotes and run
# as root during the build. Reject anything that is not a plain version.
case "$LATEST" in
  *[!0-9A-Za-z.-]* | "" | -* )
    fail "registry returned an implausible version: $LATEST" ;;
esac
log "latest published CLI: $LATEST"

# --- what is running -------------------------------------------------------
CONTAINER="$(docker ps --filter ancestor=xl1:local --format '{{.Names}}' | head -1)"
RUNNING=""
if [ -n "$CONTAINER" ]; then
  RUNNING="$(docker exec "$CONTAINER" \
    cat /usr/local/lib/node_modules/@xyo-network/xl1-cli/package.json 2>/dev/null \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  log "running CLI: ${RUNNING:-unknown} (container $CONTAINER)"
fi

# Rebuild when the version moves, or when the existing build has aged past
# MAX_IMAGE_AGE_DAYS -- the base image collects security patches even when the
# CLI version does not change.
MAX_IMAGE_AGE_DAYS="${XL1_MAX_IMAGE_AGE_DAYS:-30}"
if docker image inspect "xl1:$LATEST" >/dev/null 2>&1; then
  BUILT_AT="$(docker image inspect "xl1:$LATEST" --format '{{.Created}}' 2>/dev/null || true)"
  AGE_DAYS=9999
  if [ -n "$BUILT_AT" ]; then
    BUILT_EPOCH="$(date -d "$BUILT_AT" +%s 2>/dev/null || echo 0)"
    [ "$BUILT_EPOCH" -gt 0 ] && AGE_DAYS=$(( ( $(date +%s) - BUILT_EPOCH ) / 86400 ))
  fi
  if [ "$AGE_DAYS" -lt "$MAX_IMAGE_AGE_DAYS" ]; then
    log "xl1:$LATEST built ${AGE_DAYS}d ago; nothing to do"
    [ "$RUNNING" = "$LATEST" ] || log "NOTE: built but not promoted -- running $RUNNING, available $LATEST"
    exit 0
  fi
  log "xl1:$LATEST is ${AGE_DAYS}d old; rebuilding for base image patches"
fi

# --- source ----------------------------------------------------------------
# The repo belongs to the operator but this runs as root, so git refuses it as
# "dubious ownership". Scope the exception to this one path rather than editing
# root's global config, which would relax the check everywhere.
git_repo() { git -C "$REPO" -c "safe.directory=$REPO" "$@"; }

if [ -d "$REPO/.git" ]; then
  log "updating $REPO"
  git_repo fetch --quiet origin || fail "could not fetch from origin"
  # Refuse to clobber local edits rather than silently discarding them.
  # @{u} is the current branch's upstream, more reliable than origin/HEAD,
  # which is often absent depending on how the repo was cloned.
  if git_repo rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    git_repo merge --ff-only --quiet '@{u}' \
      || fail "$REPO has local changes or has diverged; resolve it by hand"
  else
    log "no upstream branch configured; building the working tree as-is"
  fi
else
  log "cloning $REPO_URL into $REPO"
  git clone --quiet "$REPO_URL" "$REPO"
fi

# --- build -----------------------------------------------------------------
log "building xl1:$LATEST (this takes several minutes on a Pi)"
# buildx shells out to git itself to stamp the source commit into the image
# provenance, and hits the same dubious-ownership refusal. GIT_CONFIG_* passes
# the exception to those child processes without touching any config file.
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=safe.directory \
GIT_CONFIG_VALUE_0="$REPO" \
docker build \
  --file "$REPO/docker/Dockerfile" \
  --build-arg "XL1_CLI_VERSION=$LATEST" \
  --tag "xl1:$LATEST" \
  "$REPO" || fail "docker build failed; the running node is untouched"

log "built xl1:$LATEST"

# --- smoke test ------------------------------------------------------------
# Prove the image is usable before suggesting anyone promote it.
#
# This used to run `node -e process.exit(0)`, which only proved a Node binary
# existed in the image -- it would have passed on a build with a broken CLI or
# a missing entrypoint. Upstream's own smoke test asks the entrypoint for a
# version instead, which exercises the path a real start takes.
#
# --rm and no env-file: it exits immediately and does not join a network.
SMOKE_OUT="$(docker run --rm --entrypoint xl1 "xl1:$LATEST" --version 2>/dev/null || docker run --rm -e XL1_NETWORK= -e XL1_ROLE= "xl1:$LATEST" --version 2>/dev/null || true)"
if [ -n "$SMOKE_OUT" ]; then
  log "smoke test passed: $(printf '%s' "$SMOKE_OUT" | head -1)"
else
  log "WARNING: smoke test failed; do not promote xl1:$LATEST"
  exit 1
fi

if [ "$RUNNING" = "$LATEST" ]; then
  log "done: already running $LATEST"
else
  log "done: xl1:$LATEST is ready. Running $RUNNING. Promote when convenient:"
  log "  docker tag xl1:$LATEST xl1:local"
  log "  docker rm -f ${CONTAINER:-xl1-producer}"
  log "  docker run -d --name xl1-producer --restart unless-stopped \\"
  log "    --env-file $REPO/sequence-producer.env xl1:local"
fi
