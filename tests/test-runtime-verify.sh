#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
verify=$root/scripts/runtime-verify
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$verify" ] || fail "missing executable scripts/runtime-verify"
grep -F 'expected_redmine == "trunk"' "$verify" >/dev/null ||
  fail "trunk runtime version contract is missing"

fixture=$tmp/rootfs
bundle=$fixture/usr/local/bundle
app=$fixture/usr/src/redmine
bin=$tmp/bin
log=$tmp/commands.log
mkdir -p \
  "$fixture/bin" \
  "$fixture/sbin" \
  "$fixture/lib" \
  "$fixture/opt/mariadb-connector/lib/mariadb" \
  "$fixture/usr/bin" \
  "$bundle/bin" \
  "$bundle/gems/example-1.0/lib" \
  "$app/config" \
  "$app/files" \
  "$app/log" \
  "$app/plugins" \
  "$app/public/assets" \
  "$app/public/plugin_assets" \
  "$app/public/themes" \
  "$app/sqlite" \
  "$app/tmp/pdf" \
  "$app/tmp/pids" \
  "$app/lib/redmine" \
  "$bin"

cat >"$app/lib/redmine/version.rb" <<'RUBY'
module Redmine
  module VERSION
    MAJOR = 5
    MINOR = 1
    TINY = 13
  end
end
RUBY
: >"$app/config/database.yml"
: >"$app/config/secrets.yml"
: >"$app/config/puma.rb"
: >"$app/Gemfile"
: >"$bundle/bin/bundle"
: >"$fixture/usr/bin/ruby"

cat >"$bin/ruby" <<'SH'
#!/bin/sh
set -eu
printf 'ruby %s\n' "$*" >>"$RUNTIME_VERIFY_TEST_LOG"
[ "${RUNTIME_VERIFY_RUBY_FAIL:-0}" = 0 ]
SH
cat >"$bin/apk" <<'SH'
#!/bin/sh
set -eu
printf 'apk %s\n' "$*" >>"$RUNTIME_VERIFY_TEST_LOG"
[ "$1 $2" = "info -e" ]
[ "$3" = "${RUNTIME_VERIFY_INSTALLED_PACKAGE:-}" ]
SH
cat >"$bin/scanelf" <<'SH'
#!/bin/sh
set -eu
printf 'scanelf %s\n' "$*" >>"$RUNTIME_VERIFY_TEST_LOG"
if [ "${RUNTIME_VERIFY_RUBY_EXTENSION:-0}" = 1 ]; then
  printf '%s;%s\n' \
    "$RUNTIME_VERIFY_TEST_ROOT/usr/local/bundle/gems/native-1.0/lib/native.so" \
    'libc.musl-x86_64.so.1'
  exit 0
fi
printf '%s;%s\n' \
  "$RUNTIME_VERIFY_TEST_ROOT/usr/bin/ruby" \
  'libc.musl-x86_64.so.1'
SH
cat >"$bin/ldd" <<'SH'
#!/bin/sh
set -eu
printf 'ldd %s\n' "$*" >>"$RUNTIME_VERIFY_TEST_LOG"
if [ "${RUNTIME_VERIFY_LDD_RUBY_HOST_SYMBOLS:-0}" = 1 ]; then
  printf '%s\n' \
    "Error relocating $1: rb_define_module: symbol not found" \
    "Error relocating $1: ruby_xmalloc: symbol not found" >&2
  exit 1
fi
if [ "${RUNTIME_VERIFY_LDD_NON_RUBY_SYMBOL:-0}" = 1 ]; then
  printf '%s\n' "Error relocating $1: unrelated_symbol: symbol not found" >&2
  exit 1
fi
if [ "${RUNTIME_VERIFY_LDD_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'Error loading shared library libmissing.so: No such file' >&2
  exit 1
fi
printf '%s\n' 'libc.musl-x86_64.so.1 => /lib/ld-musl-x86_64.so.1'
SH
for command in ruby bundle gs convert apk scanelf ldd; do
  chmod 0755 "$bin/$command" 2>/dev/null || :
done
for command in bundle gs convert; do
  cp "$bin/ruby" "$bin/$command"
done

runtime_paths='/usr/src/redmine /usr/src/redmine/config/database.yml /usr/src/redmine/config/secrets.yml /usr/src/redmine/config/puma.rb /usr/src/redmine/files /usr/src/redmine/log /usr/src/redmine/plugins /usr/src/redmine/public/assets /usr/src/redmine/public/plugin_assets /usr/src/redmine/public/themes /usr/src/redmine/sqlite /usr/src/redmine/tmp /usr/src/redmine/tmp/pdf /usr/src/redmine/tmp/pids'

run_verify() {
  env PATH="$bin:$PATH" \
    APK="$bin/apk" \
    LDD="$bin/ldd" \
    RUBY="$bin/ruby" \
    SCANELF="$bin/scanelf" \
    EXPECTED_BUNDLER_VERSION=2.4.22 \
    EXPECTED_PUMA_VERSION=8.0.2 \
    EXPECTED_REDMINE_VERSION=5.1.13 \
    EXPECTED_RUBY_VERSION=3.2.11 \
    BUILD_PACKAGES='gcc make musl-dev' \
    FEATURE_PACKAGES='ghostscript imagemagick' \
    RUNTIME_PACKAGES='mariadb-connector-c sqlite-libs' \
    RUNTIME_COMMANDS='ruby bundle gs convert' \
    RUNTIME_PATHS="$runtime_paths" \
    RUNTIME_REQUIRES='mysql2 sqlite3 puma' \
    RUNTIME_VERIFY_ROOT="$fixture" \
    RUNTIME_VERIFY_TEST_LOG="$log" \
    RUNTIME_VERIFY_TEST_ROOT="$fixture" \
    "$@"
}

run_verify "$verify" elf
run_verify "$verify" contract

grep -F "ldd $fixture/usr/bin/ruby" "$log" >/dev/null ||
  fail "ELF closure was not checked"
grep -F "$fixture/opt" "$log" >/dev/null ||
  fail "ELF closure did not include optional /opt runtimes"
grep -F 'ruby -e ' "$log" >/dev/null ||
  fail "Ruby/gem contract was not checked"
grep -F 'apk info -e gcc' "$log" >/dev/null ||
  fail "forbidden packages were not checked"

chmod g+w "$app/Gemfile"
set +e
run_verify "$verify" contract >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] || fail "group-writable runtime code was accepted"
chmod g-w "$app/Gemfile"

RUNTIME_VERIFY_RUBY_EXTENSION=1 \
RUNTIME_VERIFY_LDD_RUBY_HOST_SYMBOLS=1 \
RUNTIME_VERIFY_LDD_NON_RUBY_SYMBOL=0 \
  run_verify "$verify" elf

set +e
RUNTIME_VERIFY_RUBY_EXTENSION=1 \
RUNTIME_VERIFY_LDD_RUBY_HOST_SYMBOLS=0 \
RUNTIME_VERIFY_LDD_NON_RUBY_SYMBOL=1 \
  run_verify "$verify" elf >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] || fail "non-Ruby unresolved extension symbol was accepted"

set +e
RUNTIME_VERIFY_RUBY_EXTENSION=0 \
RUNTIME_VERIFY_LDD_RUBY_HOST_SYMBOLS=0 \
RUNTIME_VERIFY_LDD_NON_RUBY_SYMBOL=0 \
RUNTIME_VERIFY_LDD_FAIL=1 \
  run_verify "$verify" elf \
  >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] || fail "unresolved ELF dependency was accepted"
grep -F "$fixture/usr/bin/ruby" "$tmp/error" >/dev/null ||
  fail "ELF failure omitted its path"

mkdir -p "$bundle/gems/example-1.0/ext"
set +e
run_verify "$verify" contract >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] || fail "forbidden gem build tree was accepted"
rm -rf "$bundle/gems/example-1.0/ext"

mkdir -p \
  "$bundle/gems/example-1.0/lib" \
  "$bundle/gems/second-1.0/lib"
: >"$bundle/gems/example-1.0/lib/allowed.o"
: >"$bundle/gems/second-1.0/lib/forbidden.o"
first_residue=$(find "$bundle" -type f -name '*.o' -print | head -n 1)
set +e
RUNTIME_CLEANUP_KEEP_PATHS="$first_residue" \
  run_verify "$verify" contract >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] ||
  fail "a later compiler artifact was hidden by an allowed first match"
rm -f \
  "$bundle/gems/example-1.0/lib/allowed.o" \
  "$bundle/gems/second-1.0/lib/forbidden.o"

mkdir -p "$fixture/usr/local/include"
set +e
run_verify "$verify" contract >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] || fail "copied Ruby development headers were accepted"
rm -rf "$fixture/usr/local/include"

default_gems=$fixture/usr/local/lib/ruby/gems/3.2.0
mkdir -p "$default_gems/cache" "$default_gems/gems/default-1.0/ext"
: >"$default_gems/cache/default-1.0.gem"
: >"$default_gems/gems/default-1.0/ext/native.o"
set +e
run_verify "$verify" contract >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] || fail "default gem build residue was accepted"
rm -rf "$default_gems"

set +e
RUNTIME_VERIFY_INSTALLED_PACKAGE=gcc run_verify "$verify" contract \
  >"$tmp/output" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ] || fail "installed build package was accepted"
grep -F 'gcc' "$tmp/error" >/dev/null ||
  fail "package failure omitted its name"

printf '%s\n' "runtime verifier: PASS"
