#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
entrypoint=$root/docker-entrypoint.sh
tmp=$(mktemp -d)
entrypoint_pid=

cleanup() {
  if [ -n "$entrypoint_pid" ]; then
    kill -TERM "$entrypoint_pid" >/dev/null 2>&1 || true
    wait "$entrypoint_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_status() {
  expected=$1
  actual=$2
  context=$3
  [ "$actual" -eq "$expected" ] ||
    fail "$context: expected status $expected, got $actual"
}

assert_contains() {
  file=$1
  text=$2
  grep -F "$text" "$file" >/dev/null ||
    fail "$file does not contain: $text"
}

assert_count() {
  expected=$1
  text=$2
  actual=$(grep -F -c "$text" "$log" || true)
  [ "$actual" -eq "$expected" ] ||
    fail "expected $expected occurrences of '$text', got $actual"
}

mkdir -p "$tmp/bin" "$tmp/state"
log=$tmp/log
stdout=$tmp/stdout
stderr=$tmp/stderr
: >"$log"

cat >"$tmp/bin/bundle" <<'SH'
#!/bin/sh
set -eu

printf '%s\n' "$*" >>"$ENTRYPOINT_TEST_LOG"

increment() {
  file=$ENTRYPOINT_TEST_STATE/$1
  value=0
  [ ! -f "$file" ] || value=$(cat "$file")
  value=$((value + 1))
  printf '%s\n' "$value" >"$file"
  printf '%s\n' "$value"
}

case "$*" in
  "exec rake db:migrate")
    attempt=$(increment core)
    case ${ENTRYPOINT_TEST_MODE:-success} in
      core-always-fails) exit 1 ;;
      core-fails-once) [ "$attempt" -gt 1 ] || exit 1 ;;
      block-core)
        printf '%s\n' "$$" >"$ENTRYPOINT_TEST_CHILD_PID"
        trap 'exit 143' TERM
        while :; do sleep 1; done
        ;;
    esac
    ;;
  "exec rake redmine:plugins:migrate")
    attempt=$(increment plugin)
    if [ "${ENTRYPOINT_TEST_MODE:-success}" = plugin-fails-once ] &&
       [ "$attempt" -eq 1 ]; then
      exit 1
    fi
    ;;
  "exec puma -C config/puma.rb")
    printf 'SECRET=%s\n' "$SECRET_KEY_BASE" >>"$ENTRYPOINT_TEST_LOG"
    ;;
esac
SH

cat >"$tmp/bin/capture" <<'SH'
#!/bin/sh
set -eu
for argument in "$@"; do
  printf 'ARG=%s\n' "$argument"
done
printf 'SECRET=%s\n' "$SECRET_KEY_BASE"
SH
chmod 0755 "$tmp/bin/bundle" "$tmp/bin/capture"

set +e
env -u SECRET_KEY_BASE -u REDMINE_SECRET_KEY_BASE \
  PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" \
  "$entrypoint" true >"$stdout" 2>"$stderr"
status=$?
set -e
assert_status 64 "$status" "missing secret"
assert_contains "$stderr" "SECRET_KEY_BASE or REDMINE_SECRET_KEY_BASE is required"

: >"$log"
env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" \
  REDMINE_SECRET_KEY_BASE=legacy-secret \
  "$entrypoint" bundle exec puma -C config/puma.rb >/dev/null
assert_contains "$log" "SECRET=legacy-secret"
assert_count 1 "exec rake db:migrate"
assert_count 1 "exec rake redmine:plugins:migrate"
assert_count 1 "exec puma -C config/puma.rb"

rm -rf "$tmp/state"
mkdir "$tmp/state"
: >"$log"
env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" \
  SECRET_KEY_BASE=preferred-secret REDMINE_SECRET_KEY_BASE=ignored-secret \
  "$entrypoint" bundle exec puma -C config/puma.rb >/dev/null
assert_contains "$log" "SECRET=preferred-secret"

rm -rf "$tmp/state"
mkdir "$tmp/state"
: >"$log"
env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" \
  SECRET_KEY_BASE=secret ENTRYPOINT_TEST_MODE=plugin-fails-once \
  REDMINE_DB_MIGRATE_RETRIES=2 REDMINE_DB_MIGRATE_DELAY=0 \
  "$entrypoint" bundle exec puma -C config/puma.rb >/dev/null
assert_count 2 "exec rake db:migrate"
assert_count 2 "exec rake redmine:plugins:migrate"
assert_count 1 "exec puma -C config/puma.rb"

rm -rf "$tmp/state"
mkdir "$tmp/state"
: >"$log"
set +e
env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" \
  SECRET_KEY_BASE=secret ENTRYPOINT_TEST_MODE=core-always-fails \
  REDMINE_DB_MIGRATE_RETRIES=2 REDMINE_DB_MIGRATE_DELAY=0 \
  "$entrypoint" bundle exec puma -C config/puma.rb \
  >"$stdout" 2>"$stderr"
status=$?
set -e
assert_status 1 "$status" "retry exhaustion"
assert_count 2 "exec rake db:migrate"
assert_count 0 "exec puma -C config/puma.rb"
assert_contains "$stderr" "failed after 2 attempts"

: >"$log"
env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" \
  SECRET_KEY_BASE=secret REDMINE_NO_DB_MIGRATE=1 \
  "$entrypoint" bundle exec puma -C config/puma.rb >/dev/null
assert_count 0 "exec rake db:migrate"
assert_count 1 "exec puma -C config/puma.rb"

env PATH="$tmp/bin:$PATH" SECRET_KEY_BASE=custom-secret \
  "$entrypoint" capture "two words" "*" >"$stdout"
assert_contains "$stdout" "ARG=two words"
assert_contains "$stdout" "ARG=*"
assert_contains "$stdout" "SECRET=custom-secret"

for invalid in abc 0; do
  set +e
  env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
    ENTRYPOINT_TEST_STATE="$tmp/state" SECRET_KEY_BASE=secret \
    REDMINE_DB_MIGRATE_RETRIES="$invalid" \
    "$entrypoint" bundle exec puma -C config/puma.rb \
    >"$stdout" 2>"$stderr"
  status=$?
  set -e
  assert_status 64 "$status" "invalid retry count $invalid"
done

set +e
env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" SECRET_KEY_BASE=secret \
  REDMINE_DB_MIGRATE_DELAY=-1 \
  "$entrypoint" bundle exec puma -C config/puma.rb \
  >"$stdout" 2>"$stderr"
status=$?
set -e
assert_status 64 "$status" "invalid retry delay"

set +e
env PATH="$tmp/bin:$PATH" SECRET_KEY_BASE=secret RAILS_ENV=staging \
  "$entrypoint" true >"$stdout" 2>"$stderr"
status=$?
set -e
assert_status 64 "$status" "non-production Rails environment"
assert_contains "$stderr" "RAILS_ENV must be production"

rm -rf "$tmp/state"
mkdir "$tmp/state"
child_pid_file=$tmp/child-pid
env PATH="$tmp/bin:$PATH" ENTRYPOINT_TEST_LOG="$log" \
  ENTRYPOINT_TEST_STATE="$tmp/state" \
  ENTRYPOINT_TEST_CHILD_PID="$child_pid_file" \
  ENTRYPOINT_TEST_MODE=block-core SECRET_KEY_BASE=secret \
  "$entrypoint" bundle exec puma -C config/puma.rb \
  >"$stdout" 2>"$stderr" &
entrypoint_pid=$!

attempt=1
while [ ! -s "$child_pid_file" ]; do
  [ "$attempt" -lt 100 ] || fail "migration child PID was not recorded"
  attempt=$((attempt + 1))
  sleep 0.05
done
child_pid=$(cat "$child_pid_file")
kill -TERM "$entrypoint_pid"
set +e
wait "$entrypoint_pid"
status=$?
set -e
entrypoint_pid=
assert_status 143 "$status" "TERM during migration"
if kill -0 "$child_pid" >/dev/null 2>&1; then
  fail "migration child $child_pid survived TERM"
fi

printf '%s\n' "entrypoint contract: PASS"
