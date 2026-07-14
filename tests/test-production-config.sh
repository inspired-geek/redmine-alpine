#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
fragment=$root/config/production.append.rb
containerfile=$root/Containerfile

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  file=$1
  expected=$2
  grep -F -- "$expected" "$file" >/dev/null ||
    fail "$file does not contain: $expected"
}

[ -f "$fragment" ] || fail 'missing config/production.append.rb'
[ ! -e "$root/config/environments/production.rb" ] ||
  fail 'release-specific production.rb must not be replaced'

ruby -c "$fragment" >/dev/null
assert_contains "$fragment" 'RAILS_LOG_TO_STDOUT'
assert_contains "$fragment" 'ActiveSupport::TaggedLogging.new(logger)'
assert_contains "$fragment" 'config.active_record.dump_schema_after_migration = false'

assert_contains "$containerfile" \
  'COPY config/production.append.rb /tmp/redmine-alpine-production.rb'
assert_contains "$containerfile" \
  'cat /tmp/redmine-alpine-production.rb >> config/environments/production.rb'

if grep -F 'COPY --chown=1001:0 config/environments/production.rb' \
  "$containerfile" >/dev/null; then
  fail 'runtime stage still replaces the release-specific production.rb'
fi

printf '%s\n' 'production config overlay contract: PASS'
