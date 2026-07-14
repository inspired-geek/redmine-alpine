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
runtime=$tmp/runtime
default_gems=$runtime/lib/ruby/gems/3.4.0
default_gem=$default_gems/gems/default-example-1.0
gem=$bundle/gems/example-1.0
ruby_series=$(ruby -rrbconfig -e \
  'print RbConfig::CONFIG.fetch("ruby_version").split(".").first(2).join(".")')
other_series=9.9
[ "$ruby_series" != "$other_series" ] || other_series=8.8
multi_abi_gem=$bundle/gems/precompiled-1.0
single_abi_gem=$bundle/gems/single-abi-1.0
native_extension=$bundle/extensions/ruby/example/example.so
native_gem=$gem/lib/example.so
other_native=$gem/lib/other.so
fake_bin=$tmp/bin

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
  "$fake_bin" \
  "$app/test" \
  "$app/doc" \
  "$app/extra" \
  "$app/public" \
  "$app/files" \
  "$app/log" \
  "$home/.bundle/cache" \
  "$cargo/registry" \
  "$cargo/git" \
  "$cargo/target" \
  "$default_gems/cache" \
  "$default_gems/doc" \
  "$default_gems/build_info" \
  "$default_gem/lib" \
  "$default_gem/ext" \
  "$default_gem/test" \
  "$runtime/include/ruby" \
  "$runtime/lib/pkgconfig" \
  "$runtime/share/man/man1"

for file in \
  "$bundle/cache/example.gem" \
  "$bundle/doc/index.html" \
  "$bundle/build_info/example.info" \
  "$bundle/extensions/ruby/example/example.so" \
  "$native_gem" \
  "$other_native" \
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
  "$cargo/target/object.o" \
  "$default_gems/cache/default-example.gem" \
  "$default_gems/doc/index.html" \
  "$default_gems/build_info/default-example.info" \
  "$default_gem/lib/runtime.rb" \
  "$default_gem/ext/native.o" \
  "$default_gem/test/runtime_test.rb" \
  "$runtime/include/ruby/ruby.h" \
  "$runtime/lib/pkgconfig/ruby.pc" \
  "$runtime/share/man/man1/ruby.1"
do
  : >"$file"
done

printf '%s' 'same-runtime:debug-info' >"$native_extension"
printf '%s' 'same-runtime:debug-info' >"$native_gem"
printf '%s' 'other-runtime:debug-info' >"$other_native"
printf '%s\n' \
  '#!/bin/sh' \
  '[ "$1" = --strip-unneeded ] || exit 64' \
  'shift' \
  'for target do' \
  '  sed "s/:debug-info$//" "$target" >"$target.stripped"' \
  '  mv "$target.stripped" "$target"' \
  'done' \
  >"$fake_bin/strip"
chmod +x "$fake_bin/strip"

env HOME="$home" CARGO_HOME="$cargo" PATH="$fake_bin:$PATH" \
  RUNTIME_CLEANUP_KEEP_PATHS="$gem/examples/" \
  "$cleanup" "$bundle" "$app" "$runtime"

for retained in \
  "$bundle/extensions/ruby/example/example.so" \
  "$gem/lib/runtime.rb" \
  "$gem/examples/keep.rb" \
  "$multi_abi_gem/lib/native/$ruby_series/native.so" \
  "$single_abi_gem/lib/native/$other_series/native.so" \
  "$default_gem/lib/runtime.rb" \
  "$app/extra/mail_handler.rb" \
  "$app/public/application.css"
do
  [ -f "$retained" ] || fail "required path was removed: $retained"
done

[ "$(cat "$native_extension")" = same-runtime ] ||
  fail "native extension was not stripped"
[ "$native_extension" -ef "$native_gem" ] ||
  fail "identical native extensions were not hardlinked"
[ ! "$native_extension" -ef "$other_native" ] ||
  fail "different native extensions were hardlinked"

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
  "$cargo/target" \
  "$default_gems/cache" \
  "$default_gems/doc" \
  "$default_gems/build_info" \
  "$default_gem/ext" \
  "$default_gem/test" \
  "$runtime/include" \
  "$runtime/lib/pkgconfig" \
  "$runtime/share/man"
do
  [ ! -e "$removed" ] || fail "build residue survived: $removed"
done

set +e
"$cleanup" / "$app" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "unsafe bundle root was not rejected"

printf '%s\n' "runtime cleanup: PASS"
