#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cleanup=$root/scripts/runtime-cleanup
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$cleanup" ] || fail "missing executable scripts/runtime-cleanup"

bundle=$tmp/bundle
app=$tmp/app
home=$tmp/home
cargo=$tmp/cargo
gem=$bundle/gems/example-1.0
ruby_series=$(ruby -rrbconfig -e \
  'print RbConfig::CONFIG.fetch("ruby_version").split(".").first(2).join(".")')
other_series=9.9
[ "$ruby_series" != "$other_series" ] || other_series=8.8
multi_abi_gem=$bundle/gems/precompiled-1.0
single_abi_gem=$bundle/gems/single-abi-1.0

mkdir -p \
  "$bundle/cache" \
  "$bundle/doc" \
  "$bundle/build_info" \
  "$bundle/extensions/ruby/example" \
  "$gem/lib" \
  "$gem/ext" \
  "$gem/ports" \
  "$gem/test" \
  "$gem/spec" \
  "$gem/examples" \
  "$gem/doc" \
  "$multi_abi_gem/lib/native/$ruby_series" \
  "$multi_abi_gem/lib/native/$other_series" \
  "$single_abi_gem/lib/native/$other_series" \
  "$app/test" \
  "$app/doc" \
  "$app/extra" \
  "$app/public" \
  "$app/files" \
  "$app/log" \
  "$home/.bundle/cache" \
  "$cargo/registry" \
  "$cargo/git" \
  "$cargo/target"

for file in \
  "$bundle/cache/example.gem" \
  "$bundle/doc/index.html" \
  "$bundle/build_info/example.info" \
  "$bundle/extensions/ruby/example/example.so" \
  "$gem/lib/runtime.rb" \
  "$gem/ext/native.o" \
  "$gem/ports/native.a" \
  "$gem/test/runtime_test.rb" \
  "$gem/spec/runtime_spec.rb" \
  "$gem/examples/keep.rb" \
  "$gem/doc/guide.md" \
  "$multi_abi_gem/lib/native/$ruby_series/native.so" \
  "$multi_abi_gem/lib/native/$other_series/native.so" \
  "$single_abi_gem/lib/native/$other_series/native.so" \
  "$app/test/app_test.rb" \
  "$app/doc/guide.md" \
  "$app/extra/mail_handler.rb" \
  "$app/public/application.css" \
  "$app/files/delete.me" \
  "$app/log/delete.me" \
  "$home/.bundle/cache/index" \
  "$cargo/registry/index" \
  "$cargo/git/checkout" \
  "$cargo/target/object.o"
do
  : >"$file"
done

env HOME="$home" CARGO_HOME="$cargo" \
  RUNTIME_CLEANUP_KEEP_PATHS="$gem/examples" \
  "$cleanup" "$bundle" "$app"

for retained in \
  "$bundle/extensions/ruby/example/example.so" \
  "$gem/lib/runtime.rb" \
  "$gem/examples/keep.rb" \
  "$multi_abi_gem/lib/native/$ruby_series/native.so" \
  "$single_abi_gem/lib/native/$other_series/native.so" \
  "$app/extra/mail_handler.rb" \
  "$app/public/application.css"
do
  [ -f "$retained" ] || fail "required path was removed: $retained"
done

for removed in \
  "$bundle/cache" \
  "$bundle/doc" \
  "$bundle/build_info" \
  "$gem/ext" \
  "$gem/ports" \
  "$gem/test" \
  "$gem/spec" \
  "$gem/doc" \
  "$multi_abi_gem/lib/native/$other_series" \
  "$app/test" \
  "$app/doc" \
  "$app/files/delete.me" \
  "$app/log/delete.me" \
  "$home/.bundle/cache" \
  "$cargo/registry" \
  "$cargo/git" \
  "$cargo/target"
do
  [ ! -e "$removed" ] || fail "build residue survived: $removed"
done

set +e
"$cleanup" / "$app" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "unsafe bundle root was not rejected"

grep -F '[ "$keep_parent" = / ]' "$cleanup" >/dev/null ||
  fail "direct children of root are not normalized without a double slash"

printf '%s\n' "runtime cleanup: PASS"
