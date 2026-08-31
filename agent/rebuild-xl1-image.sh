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
# Versioned images to keep after a build. Each is ~545MB and one accumulates
# per CLI release, so they add up over a multi-year run.
#
# Three, not one: the rollback in the update runbook is `docker tag` back to
# the previous version, which takes seconds and needs that image to still
# exist. Keeping only the current one turns a bad upgrade into a full rebuild
# on a Pi. Set 0 to disable pruning entirely.
KEEP_IMAGES="${XL1_KEEP_IMAGES:-3}"

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

# Whether to take upstream's latest recipe automatically. OFF by default.
#
# This script runs as root and hands the checkout to `docker build`, which
# executes the Dockerfile's RUN steps during the build. Auto-merging therefore
# means the machine holding your producer key fetches third-party source every
# week and runs it, unreviewed, before any human has looked at it.
#
# "It builds only, it never promotes" protects the running NODE from a bad
# image. It does not protect the HOST from the build, which has already
# happened by the time promotion is a question.
#
# Little is lost by leaving this off. The two reasons to rebuild -- a newer CLI,
# and a base image that has collected security patches -- both work on the
# recipe already present, because the base layers are re-pulled on every build
# regardless. Only the recipe stops moving by itself, and the agent already
# emails when upstream changes, so taking it becomes a decision made with the
# diff in front of you rather than one made for you at 4am on a Sunday.
AUTO_MERGE="${XL1_IMAGES_AUTO_MERGE:-0}"

if [ -d "$REPO/.git" ]; then
  # A fetch failure is no longer fatal: the point is to report drift, and
  # being unable to check is not a reason to skip a base-image rebuild.
  git_repo fetch --quiet origin || log "WARNING: could not reach origin; reporting on what is here"
  UPSTREAM_MOVED=""
  if git_repo rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    BEHIND="$(git_repo rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
    [ "$BEHIND" -gt 0 ] && UPSTREAM_MOVED="$BEHIND"
  fi

  if [ "$AUTO_MERGE" = "1" ] && [ -n "$UPSTREAM_MOVED" ]; then
    log "XL1_IMAGES_AUTO_MERGE=1: taking $UPSTREAM_MOVED upstream commit(s) unreviewed"
    git_repo merge --ff-only --quiet '@{u}' \
      || fail "$REPO has local changes or has diverged; resolve it by hand"
  elif [ -n "$UPSTREAM_MOVED" ]; then
    log "upstream is $UPSTREAM_MOVED commit(s) ahead; building the reviewed checkout instead"
    log "  review:  git -C $REPO log --oneline HEAD..@{u}"
    log "  take it: git -C $REPO merge --ff-only @{u}"
  else
    log "checkout is current with upstream"
  fi
else
  log "cloning $REPO_URL into $REPO"
  git clone --quiet "$REPO_URL" "$REPO"
fi

# --- build -----------------------------------------------------------------
log "building xl1:$LATEST (this takes several minutes on a Pi)"
# The Dockerfile does `COPY dist/node`, and dist/ is not in the repository --
# upstream's build-image.sh compiles it with `pnpm xy compile` before building.
# This script has always plain-built, which worked only because the checkout it
# runs against was compiled by hand once and kept the result. It clones when the
# directory is missing, and that path had never been exercised: it would fail at
# the COPY with a cache-key error that says nothing about a missing compile.
#
# Compiled in a container so no Node or pnpm is needed on the host.
if [ ! -f "$REPO/dist/node/entrypoint.mjs" ]; then
  log "compiling the image entrypoint (dist/node is absent)"
  docker run --rm -v "$REPO":/w -w /w "node:${NODE_VERSION:-24.14.1}-bookworm-slim" \
    sh -c 'corepack enable && pnpm install --frozen-lockfile && pnpm xy compile' \
    || fail "could not compile the entrypoint; the running node is untouched"
  [ -f "$REPO/dist/node/entrypoint.mjs" ] \
    || fail "the compile produced no entrypoint; the running node is untouched"
fi

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

# --- prune old versions ------------------------------------------------------
# Only after the smoke test. Removing yesterday's images to make room for one
# that does not work is the wrong order.
prune_old_images() {
  [ "$KEEP_IMAGES" -gt 0 ] 2>/dev/null || { log "image pruning disabled"; return 0; }

  # What xl1:local resolves to. Never removed whatever its version tag, because
  # it is what the producer runs.
  local promoted=""
  promoted="$(docker image inspect xl1:local --format '{{.Id}}' 2>/dev/null || true)"

  # Every image any container references, running OR stopped. A stopped
  # container holding a reference is the usual reason a remove fails, and
  # forcing past it is how you delete the thing you were about to roll back to.
  local in_use=""
  in_use="$(docker ps -aq 2>/dev/null | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null || true)"

  # Semver tags only, newest first. `xl1:local` cannot match this pattern, so
  # the promotion tag is structurally out of scope rather than special-cased.
  local versions=""
  versions="$(docker images xl1 --format '{{.Tag}}' 2>/dev/null \
              | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV || true)"
  [ -n "$versions" ] || return 0

  local total kept=0 removed=0
  total="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
  log "versioned images: $total (keeping $KEEP_IMAGES)"

  local v id
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ "$kept" -lt "$KEEP_IMAGES" ]; then
      kept=$((kept + 1))
      continue
    fi
    id="$(docker image inspect "xl1:$v" --format '{{.Id}}' 2>/dev/null || true)"
    if [ -n "$promoted" ] && [ "$id" = "$promoted" ]; then
      log "  keeping xl1:$v -- it is what xl1:local points at"
      continue
    fi
    if [ -n "$id" ] && printf '%s\n' "$in_use" | grep -qF "$id"; then
      log "  keeping xl1:$v -- a container still references it"
      continue
    fi
    # No -f, deliberately. If Docker objects, it knows something this does not,
    # and the right response is to say so rather than insist.
    if docker rmi "xl1:$v" >/dev/null 2>&1; then
      log "  removed xl1:$v"
      removed=$((removed + 1))
    else
      log "  could NOT remove xl1:$v -- left in place"
    fi
  done <<EOF
$versions
EOF

  log "pruned $removed image(s), $((total - removed)) remain"
}

prune_old_images

if [ "$RUNNING" = "$LATEST" ]; then
  log "done: already running $LATEST"
else
  log "done: xl1:$LATEST is ready. Running $RUNNING. Promote when convenient:"
  log "  docker tag xl1:$LATEST xl1:local"
  log "  docker rm -f ${CONTAINER:-xl1-producer}"
  log "  docker run -d --name xl1-producer --restart unless-stopped \\"
  log "    --env-file $REPO/sequence-producer.env xl1:local"
fi
