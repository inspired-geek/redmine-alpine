#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
helper=$root/scripts/apk-add
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$helper" ] || fail "missing executable scripts/apk-add"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/apk" <<'SH'
#!/bin/sh
set -eu
count=0
[ ! -f "$APK_ADD_TEST_COUNT" ] || count=$(cat "$APK_ADD_TEST_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$APK_ADD_TEST_COUNT"
printf '%s\n' "$*" >>"$APK_ADD_TEST_LOG"
[ "$count" -ge "${APK_ADD_TEST_SUCCEED_ON:-999}" ] || exit 75
SH
cat >"$tmp/bin/sleep" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$APK_ADD_TEST_SLEEP_LOG"
SH
chmod 0755 "$tmp/bin/apk" "$tmp/bin/sleep"

count=$tmp/count
log=$tmp/apk.log
sleep_log=$tmp/sleep.log
env PATH="$tmp/bin:$PATH" \
  APK_ADD_TEST_COUNT="$count" \
  APK_ADD_TEST_LOG="$log" \
  APK_ADD_TEST_SLEEP_LOG="$sleep_log" \
  APK_ADD_TEST_SUCCEED_ON=3 \
  APK_ADD_RETRY_DELAY_SECONDS=0 \
  "$helper" --virtual .build-deps gcc make

[ "$(cat "$count")" -eq 3 ] || fail "transient failure was not retried twice"
[ "$(wc -l <"$sleep_log" | tr -d ' ')" -eq 2 ] ||
  fail "retry delay did not run between attempts"
[ "$(sort -u "$log")" = 'add --no-cache --virtual .build-deps gcc make' ] ||
  fail "apk-add changed the requested package transaction"

printf '0\n' >"$count"
set +e
env PATH="$tmp/bin:$PATH" \
  APK_ADD_TEST_COUNT="$count" \
  APK_ADD_TEST_LOG="$log" \
  APK_ADD_TEST_SLEEP_LOG="$sleep_log" \
  APK_ADD_RETRY_DELAY_SECONDS=0 \
  "$helper" ca-certificates >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 75 ] || fail "final apk failure status was not preserved"
[ "$(cat "$count")" -eq 3 ] || fail "persistent failure did not stop after three attempts"

set +e
"$helper" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "missing package arguments were accepted"

set +e
APK_ADD_MAX_ATTEMPTS=0 "$helper" ca-certificates >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "invalid retry count was accepted"

printf '%s\n' 'apk add retry helper: PASS'
