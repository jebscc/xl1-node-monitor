#!/usr/bin/env bash
#
# Move the service's XYO stack to whatever npm says is newest, and prove it.
#
#   bash scripts/bump-xyo-stack.sh           show what would change
#   bash scripts/bump-xyo-stack.sh --apply   change it, then run every gate
#
# WHY THIS EXISTS. On 2026-09-22 the stack was pinned to 5.6.0 by hand, and
# 5.6.1 had been published while the work was going on. Nothing was wrong with
# the result and it was a version behind within the hour, because the number
# was typed from what somebody had read earlier rather than asked for at the
# moment of writing it. A figure a person types is a figure that was true once.
#
# THE VERSIONS COME FROM THE REGISTRY AND THE NAMES COME FROM package.json, so
# neither is a list kept here that can go stale against the thing it describes.
#
# --apply IS NOT A COMMIT. It writes package.json, resolves the lockfile, and
# then runs every gate this repository has for the service:
#
#   pnpm install         the lockfile it just wrote must actually install
#   pnpm run typecheck   the same step the image build runs
#   peer-audit.mjs       the half a typecheck cannot see -- an unmet peer
#                        installs in silence under --frozen-lockfile
#   the two cross-checks  the sign-in witness against the SDK, and the anchored
#                        hash against the verifier people download. The second
#                        is the one that matters most: a stack move must never
#                        change the hash, or every attestation already on the
#                        chain stops verifying.
#
# AND IT PUTS THE FILES BACK IF ANY OF THEM FAILS. A half-applied bump that
# typechecks but breaks the hash is worse than no bump: it looks finished.
#
set -u

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

cd "$(dirname "$0")/.." || { echo "cannot reach the repository root"; exit 1; }
ROOT="$(pwd)"
# TWO LAYOUTS, AND THIS SHIPS IN BOTH. The private tree keeps the service in
# xl1-service/; the published one calls it service/ and carries this script
# inside it, so on a node `dirname $0/..` IS the service. Asked rather than
# assumed, because the machine that most needs to move its SDK is the node.
if [ -f "$ROOT/xl1-service/package.json" ]; then
  SVC="$ROOT/xl1-service"
elif [ -f "$ROOT/package.json" ]; then
  SVC="$ROOT"
else
  SVC="$ROOT/xl1-service"
fi
PKG="$SVC/package.json"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; X=$'\033[0m'
else B=""; D=""; G=""; R=""; Y=""; X=""; fi
head_() { printf '\n%s== %s%s\n' "$B" "$1" "$X"; }
note()  { printf '   %s%s%s\n' "$D" "$1" "$X"; }
good()  { printf '   %s%s%s\n' "$G" "$1" "$X"; }
warn()  { printf '   %s%s%s\n' "$Y" "$1" "$X"; }
fail()  { printf '   %s%s%s\n' "$R" "$1" "$X"; }

command -v curl >/dev/null 2>&1 || { fail "curl is not installed"; exit 2; }
[ -f "$PKG" ] || { fail "no $PKG"; exit 2; }

# WHERE THE pnpm HALF RUNS. Reporting needs nothing but curl and sed, on
# purpose, so "is there something newer" can be asked from the Pi -- which
# deliberately has no Node and no pnpm on the host, because everything is
# built in containers. bootstrap-pi.sh says so in as many words.
#
# Applying needs a real toolchain, and where the host has none we borrow the
# one the service is built with. Same form as rebuild-xl1-image.sh, which has
# run this way on a weekly timer since it was written: root in the container,
# corepack enable, the work mounted in. Following the pattern this repository
# has already proven on that machine rather than inventing a tidier one that
# has never run there.
NODE_IMAGE="${NODE_IMAGE:-node:26-bookworm-slim}"
if command -v pnpm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  RUNNER=host
elif command -v docker >/dev/null 2>&1; then
  RUNNER=docker
else
  RUNNER=none
fi

svc_sh() { # svc_sh <shell command, run inside xl1-service>
  case "$RUNNER" in
    host)   ( cd "$SVC" && sh -c "$1" ) ;;
    docker) docker run --rm -e CI=true -v "$SVC:/app" -w /app "$NODE_IMAGE" \
              sh -c "corepack enable && $1" ;;
    *)      return 127 ;;
  esac
}

# --- what is pinned, and what is published -----------------------------------

# SED, NOT NODE. The reporting half has to work where there is no toolchain,
# which is the machine most likely to want the answer.
pinned() {   # name<TAB>version for every stack package, read from the file
  grep -oE '"(@xyo-network|@xylabs|@ariestools)/[^"]+" *: *"[^"]+"' "$PKG" \
    | sed 's/" *: *"/\t/; s/"//g' | sort
}

latest() {   # latest <package>
  curl -fsSL --max-time 25 "https://registry.npmjs.org/$1/latest" 2>/dev/null \
    | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' | head -1
}

head_ "Pinned here, against what npm has"
MOVES=""
UNREACHED=""
while IFS="$(printf '\t')" read -r name have; do
  [ -n "$name" ] || continue
  want="$(latest "$name")"
  if [ -z "$want" ]; then
    # NOT TREATED AS "UP TO DATE". A registry that cannot be reached tells us
    # nothing, and the shape of this script makes silence look like agreement.
    printf '   %-32s %-8s %s?%s could not ask npm\n' "$name" "$have" "$Y" "$X"
    UNREACHED="$UNREACHED $name"
    continue
  fi
  if [ "$want" = "$have" ]; then
    printf '   %-32s %-8s %sup to date%s\n' "$name" "$have" "$D" "$X"
  else
    printf '   %-32s %-8s %s-> %s%s\n' "$name" "$have" "$Y" "$want" "$X"
    MOVES="$MOVES $name=$want"
  fi
done <<EOF
$(pinned)
EOF

[ -n "$UNREACHED" ] && warn "could not ask npm about:$UNREACHED"

if [ -z "$MOVES" ]; then
  head_ "Verdict"
  if [ -n "$UNREACHED" ]; then
    warn "nothing to move among the ones that answered, and some did not answer."
    exit 1
  fi
  good "every pinned package is already the newest published."
  exit 0
fi

if [ "$APPLY" != 1 ]; then
  head_ "Verdict"
  warn "there are newer releases. Re-run with --apply to take them and verify."
  exit 1
fi

# --- take them, then earn them -----------------------------------------------

if [ "$RUNNER" = none ]; then
  head_ "Verdict"
  fail "there are newer releases, and this machine has no way to take them:"
  fail "no pnpm and node on the host, and no docker to borrow them from."
  note "Reporting needs neither, which is why the list above still printed."
  exit 1
fi

head_ "Applying"
[ "$RUNNER" = docker ] && note "no pnpm on this host, so the work runs in $NODE_IMAGE"
cp "$PKG" "$PKG.bump-backup"
cp "$SVC/pnpm-lock.yaml" "$SVC/pnpm-lock.yaml.bump-backup"
restore() {
  mv -f "$PKG.bump-backup" "$PKG" 2>/dev/null
  mv -f "$SVC/pnpm-lock.yaml.bump-backup" "$SVC/pnpm-lock.yaml" 2>/dev/null
}
# ON ANY EXIT UNTIL IT HAS EARNED ITS KEEP. The backups are only discarded
# once every gate has passed, so an interrupt leaves the tree as it was.
trap 'restore' EXIT INT TERM

# SED, NOT NODE, so the writer needs no toolchain either -- the container is
# borrowed for pnpm and nothing else. An embedded node program here also has
# to survive two layers of quoting on its way into `docker run sh -c`, which
# is a great deal of care spent on replacing a version string.
#
# `|` as the delimiter because every package name contains a slash.
for _m in $MOVES; do
  _n="${_m%=*}"; _v="${_m##*=}"
  sed -E -i 's|("'"$_n"'" *: *)"[^"]*"|\1"'"$_v"'"|' "$PKG"
done
good "package.json written"

gate() { # gate <label> <shell command, run inside the service>
  # SHIFTED OFF, which the first version forgot -- so the command it ran was
  # the label, and every gate reported `resolving the lockfile: command not
  # found`. It failed safely only because the restore trap was already armed.
  _label="$1"; shift
  printf '   %-32s ... ' "$_label"
  if svc_sh "$*" >/tmp/bump-gate.$$ 2>&1; then
    printf '%sok%s\n' "$G" "$X"; rm -f /tmp/bump-gate.$$; return 0
  fi
  printf '%sFAILED%s\n' "$R" "$X"
  sed 's/^/     /' /tmp/bump-gate.$$ | tail -25
  rm -f /tmp/bump-gate.$$
  return 1
}

head_ "Earning it"
# A GATE THAT IS NOT IN THIS TREE IS NOT A GATE THAT FAILED. The published
# service carries the peer audit and the anchored-hash check; the sign-in
# oracle holds the SITE's witness to the SDK and lives only in the private
# tree, so on a node it is absent and correctly so. Restoring a good bump
# because a file was never there is the wrong answer, and so is passing
# quietly -- what ran is named in the verdict.
SKIPPED=""
gate_file() { # gate_file <label> <file that must exist> <command...>
  _lbl="$1"; _need="$2"; shift 2
  if [ ! -f "$SVC/$_need" ]; then
    printf '   %-32s %snot in this tree%s
' "$_lbl" "$D" "$X"
    SKIPPED="$SKIPPED [$_lbl]"
    return 0
  fi
  gate "$_lbl" "$@"
}

gate "resolving the lockfile" pnpm install --no-frozen-lockfile || exit 1
gate "installing as the build does" pnpm install --frozen-lockfile || exit 1
gate "typecheck" pnpm run typecheck || exit 1
gate_file "peer audit" scripts/peer-audit.mjs node scripts/peer-audit.mjs . || exit 1
gate_file "the anchored hash" test-attestation-hash.mjs node test-attestation-hash.mjs || exit 1
gate_file "the sign-in witness" test-signin-oracle.mjs node test-signin-oracle.mjs || exit 1

# Earned. Keep the new files and stop putting the old ones back.
trap - EXIT INT TERM
rm -f "$PKG.bump-backup" "$SVC/pnpm-lock.yaml.bump-backup"

head_ "Verdict"
good "taken and verified:"
for m in $MOVES; do printf '     %s\n' "$m"; done
note "package.json and pnpm-lock.yaml are changed and not committed."
[ -n "$SKIPPED" ] && note "not run here, being absent from this tree:$SKIPPED"
note "The anchored hash is unchanged, so what is already on the chain still verifies."
exit 0
