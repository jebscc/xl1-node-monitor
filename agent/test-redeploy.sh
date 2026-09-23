#!/usr/bin/env bash
# What redeploy-anchor.sh promises, driven against a stubbed docker.
#
# THE ONE PROPERTY THAT MATTERS MOST is that it writes no `docker run` flags of
# its own. bootstrap-pi.sh owns that list, and its own comment records that the
# list drifted from docker-compose.pi.yml once and cost a clean install. A
# third copy here would be a third thing to keep in step, so this checks the
# wizard's function is what actually runs -- against the REAL bootstrap-pi.sh,
# not a fixture, because the thing that would break is the extraction.
#
# THE SECOND is that every way it can go wrong puts the old image back. A
# container that comes back healthy but publishing fewer ports looks exactly
# like a working one, and the site's chain height goes quiet.
set -u

SCRIPT="${1:?path to redeploy-anchor.sh}"
BOOT="${2:-$(dirname "$SCRIPT")/bootstrap-pi.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
SRC="$(tr -d '\r' < "$SCRIPT")"
CODE="$(printf '%s' "$SRC" | grep -vE '^[[:space:]]*#')"

printf '\nthe script itself\n'
if bash -n "$SCRIPT" 2>/dev/null; then ok "it parses"; else bad "it parses"; fi

# --- it borrows the flags, never writes them ---------------------------------
printf '\nwhose docker run this is\n'
if printf '%s' "$CODE" | grep -qE 'docker run'; then
  bad "it writes its own docker run" \
      "that is a third copy of a list whose second copy already cost an install"
else
  ok "it contains no docker run of its own"
fi
if printf '%s' "$CODE" | grep -q 'start_anchor_service() {/,/^}/p'; then
  ok "it takes the wizard's function at run time"
else
  bad "it does not read start_anchor_service out of the wizard" \
      "then the two lists drift, which is the whole thing this avoids"
fi

# AND THE EXTRACTION ACTUALLY WORKS against the real file. A sed that matches
# nothing fails silently and everything below it would then be untested.
if [ -f "$BOOT" ]; then
  GOT="$(sed -n '/^start_anchor_service() {/,/^}/p' "$BOOT")"
  if printf '%s' "$GOT" | grep -q 'docker run -d --name'; then
    ok "the real bootstrap-pi.sh still yields that function"
  else
    bad "start_anchor_service could not be read out of $BOOT" \
        "the redeploy would die rather than invent flags, but it would die"
  fi
else
  bad "no bootstrap-pi.sh to check the extraction against"
fi

# --- driven, with docker stubbed ---------------------------------------------
#
# Each run says how the fake node behaves: whether the build works, how many
# ports come back, and whether /health answers.
run_case() { # run_case <build ok> <ports after> <health ok> [ports before]
  _d="$(mktemp -d)"
  cat > "$_d/docker" <<STUB
#!/bin/sh
case "\$1" in
  build)  [ "$1" = yes ] || exit 1 ;;
  port)   if [ -f "$_d/.asked" ]; then n=$2; else n=${4:-$2}; : > "$_d/.asked"; fi
          i=0; while [ \$i -lt \$n ]; do echo "809\$i/tcp -> 127.0.0.1:809\$i"; i=\$((i+1)); done ;;
  inspect) case "\$*" in *image*) exit 0 ;; *) echo "XL1_NETWORK=sequence" ;; esac ;;
  tag|rm|run) : ;;
esac
exit 0
STUB
  cat > "$_d/curl" <<STUB
#!/bin/sh
[ "$3" = yes ] || exit 7
echo '{"signing":true}'
STUB
  printf '#!/bin/sh\nexec "$@"\n' > "$_d/sudo"
  printf '#!/bin/sh\nexit 0\n' > "$_d/sleep"
  chmod +x "$_d"/*
  ( PATH="$_d:$PATH" NO_COLOR=1 XL1_BOOTSTRAP="$BOOT" XL1_SERVICE_DIR="$_d" \
    bash "$SCRIPT" ) 2>&1
  rm -rf "$_d"
}
: > /dev/null

printf '\nwhen it works\n'
# The stub service dir needs a Dockerfile to be found; XL1_SERVICE_DIR skips
# discovery, so only the build stub decides.
OUT="$(run_case yes 1 yes)"
if printf '%s' "$OUT" | grep -q 'running the code in'; then
  ok "a clean run reports the service is on the new code"
else
  bad "a clean run does not report success" "$OUT"
fi
if printf '%s' "$OUT" | grep -q 'previous'; then
  ok "the image it replaced is kept"
else
  bad "nothing is kept to go back to" "a bad build would leave no way back"
fi

printf '\nwhen the build fails\n'
OUT="$(run_case no 1 yes)"
if printf '%s' "$OUT" | grep -qi 'did not build'; then
  ok "a failed build stops before the container is touched"
else
  bad "a failed build is not reported" "$OUT"
fi
if printf '%s' "$OUT" | grep -qi 'still running'; then
  ok "and says the running container was left alone"
else
  bad "it does not say the node is untouched" "which is the thing you need to know"
fi

printf '\nwhen it comes back smaller\n'
# THE QUIET ONE. Healthy, answering, and publishing less than it did.
OUT="$(run_case yes 0 yes 1)"
if printf '%s' "$OUT" | grep -qi 'binding was lost'; then
  ok "fewer publishes than before is caught"
else
  bad "a lost binding passes as a good redeploy" \
      "the container is healthy and nothing can reach it"
fi
if printf '%s' "$OUT" | grep -qi 'putting xl1-service:previous back'; then
  ok "and the old image is put back"
else
  bad "it leaves the node on the image that lost a binding"
fi

printf '\nwhen health never answers\n'
OUT="$(run_case yes 1 no)"
if printf '%s' "$OUT" | grep -qi 'never answered'; then
  ok "a container that does not answer is caught"
else
  bad "a dead service reads as a good redeploy" "$OUT"
fi
if printf '%s' "$OUT" | grep -qi 'putting xl1-service:previous back'; then
  ok "and the old image is put back"
else
  bad "it leaves the node on a service that does not answer"
fi

printf '\nthe dry run\n'
OUT="$( _d="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$_d/docker"; chmod +x "$_d/docker"
        PATH="$_d:$PATH" NO_COLOR=1 XL1_BOOTSTRAP="$BOOT" XL1_SERVICE_DIR="$_d" \
        bash "$SCRIPT" --dry-run 2>&1; rm -rf "$_d" )"
if printf '%s' "$OUT" | grep -q 'would run:'; then
  ok "--dry-run prints the plan"
else
  bad "--dry-run does not print a plan" "$OUT"
fi
if printf '%s' "$OUT" | grep -qi 'built xl1-service'; then
  bad "--dry-run built something" "the one mode that must change nothing"
else
  ok "--dry-run changes nothing"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
