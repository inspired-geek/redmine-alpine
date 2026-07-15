#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
smoke=$root/tests/smoke-image.sh

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  pattern=$1
  grep -F "$pattern" "$smoke" >/dev/null ||
    fail "unified smoke script is missing: $pattern"
}

assert_not_contains() {
  pattern=$1
  if grep -F "$pattern" "$smoke" >/dev/null; then
    fail "unified smoke script contains incompatible code: $pattern"
  fi
}

[ -x "$smoke" ] || fail "missing executable tests/smoke-image.sh"
sh -n "$smoke"

for pattern in \
  'scripts/image-catalog" profile "$profile_id"' \
  'profile.fetch("puma_version")' \
  'profile.dig("runtime_checks", "requires")' \
  'test ! -e Gemfile.local' \
  'BUNDLE_FROZEN=true bundle check' \
  'dig("tool_policy", "test_images", "mariadb")' \
  'current_database must be a non-empty String' \
  'Mysql2::Client.info.fetch(:header_version)' \
  'smoke_plugin_records' \
  'CGI.unescapeHTML' \
  'core stylesheet returned an empty response' \
  'plugin stylesheet returned an empty response' \
  'redmine-alpine plugin asset smoke' \
  'convert -size 2x2' \
  'gs -q -dBATCH' \
  '-e SMOKE_DATABASE="$database"' \
  'if [ "$SMOKE_DATABASE" = sqlite ]; then' \
  'Redmine database migrations completed.'
do
  assert_contains "$pattern"
done

assert_contains 'print CGI.unescapeHTML(match[1])'
assert_not_contains 'match.fetch(1)'
assert_not_contains 'test -s public/plugin_assets/smoke_plugin/stylesheets/smoke.css'

for fixture in \
  tests/fixtures/smoke_plugin/Gemfile \
  tests/fixtures/smoke_plugin/init.rb \
  tests/fixtures/smoke_plugin/db/migrate/001_create_smoke_plugin_records.rb \
  tests/fixtures/smoke_plugin/assets/stylesheets/smoke.css \
  tests/fixtures/smoke_theme/stylesheets/application.css
do
  [ -f "$root/$fixture" ] || fail "missing $fixture"
done

grep -Fx 'gem "rake"' "$root/tests/fixtures/smoke_plugin/Gemfile" >/dev/null ||
  fail "smoke plugin Gemfile does not exercise the runtime dependency check"

ruby -c "$root/tests/fixtures/smoke_plugin/init.rb" >/dev/null
grep -F 'view_layouts_base_html_head' \
  "$root/tests/fixtures/smoke_plugin/init.rb" >/dev/null ||
  fail "smoke plugin does not inject its stylesheet into rendered pages"
ruby -c \
  "$root/tests/fixtures/smoke_plugin/db/migrate/001_create_smoke_plugin_records.rb" \
  >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fake_engine=$root/tests/fixtures/fake-container-engine.sh
profile=$($root/scripts/image-catalog profile 5.1)
redmine_version=$(printf '%s' "$profile" | ruby -rjson -e \
  'print JSON.parse(STDIN.read).fetch("redmine_version")')
puma_version=$(printf '%s' "$profile" | ruby -rjson -e \
  'print JSON.parse(STDIN.read).fetch("puma_version")')

set +e
FAKE_CAPTURE=$tmp/image-adapter-command \
FAKE_CAPTURE_STATUS=$tmp/image-adapter-status \
FAKE_REDMINE_VERSION=$redmine_version \
FAKE_PUMA_VERSION=$puma_version \
CONTAINER_ENGINE=$fake_engine \
EXPECTED_ARCH=amd64 \
  "$smoke" 5.1 image sqlite >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] ||
  fail "fake image-adapter probe unexpectedly completed"
[ -s "$tmp/image-adapter-command" ] ||
  fail "image-adapter command was not passed to the container engine"
grep -F 'mini_magick' "$tmp/image-adapter-command" >/dev/null ||
  fail "Ruby image-adapter code was split from the container shell command"
[ "$(cat "$tmp/image-adapter-status")" -eq 42 ] ||
  fail "a failed image command did not stop its multi-command shell block"

set +e
"$smoke" 5.1 image invalid >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "invalid database mode returned $status instead of 64"

printf '%s\n' 'unified image smoke contract: PASS'
