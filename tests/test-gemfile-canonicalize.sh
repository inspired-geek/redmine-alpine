#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
helper=$root/scripts/gemfile-canonicalize

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$helper" ] || fail "missing executable scripts/gemfile-canonicalize"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

main=$tmp/Gemfile
overrides=$tmp/Gemfile.local
printf '%s\n' \
  'source "https://rubygems.org"' \
  'gem "puma", "~> 6.0"' \
  'group :database do' \
  "  gem 'sqlite3', '~> 1.4'," \
  '                 platforms: [:mri, :mingw]' \
  "  gem 'mysql2', '~> 0.5'" \
  'end' \
  'gem "tzinfo-data", platforms: [:mingw, :x64_mingw, :mswin]' \
  'gem "rack", "~> 3.0"' >"$main"
printf '%s\n' \
  'gem "puma", "8.0.2"' \
  'gem "sqlite3", "=2.9.4", force_ruby_platform: true' \
  'gem "mysql2", "~>0.5.0"' \
  'gem "tzinfo-data"' >"$overrides"

"$helper" "$main" "$overrides"

[ ! -e "$overrides" ] || fail "temporary overrides were not removed"
[ "$(grep -F -c 'gem "puma", "8.0.2"' "$main")" -eq 1 ] ||
  fail "canonical Puma declaration is not unique"
[ "$(grep -F -c 'gem "sqlite3", "=2.9.4", force_ruby_platform: true' "$main")" -eq 1 ] ||
  fail "canonical SQLite declaration is not unique"
[ "$(grep -F -c 'gem "mysql2", "~>0.5.0"' "$main")" -eq 1 ] ||
  fail "canonical MySQL declaration is not unique"
[ "$(grep -F -c 'gem "tzinfo-data"' "$main")" -eq 1 ] ||
  fail "canonical no-requirement declaration is not unique"
if grep -E 'puma.*~>|sqlite3.*~> 1\.4|mysql2.*~> 0\.5' "$main" >/dev/null; then
  fail "an upstream override declaration remained"
fi
grep -F 'gem "rack", "~> 3.0"' "$main" >/dev/null ||
  fail "unrelated Gemfile content was removed"
ruby -c "$main" >/dev/null || fail "canonical Gemfile is invalid Ruby"

malformed_main=$tmp/malformed.Gemfile
malformed_overrides=$tmp/malformed.Gemfile.local
printf '%s\n' 'gem "rack", "~> 3.0"' >"$malformed_main"
cp "$malformed_main" "$tmp/malformed.before"
printf '%s\n' 'gem "sqlite3", "=2.9.4"; system("false")' >"$malformed_overrides"
if "$helper" "$malformed_main" "$malformed_overrides" >/dev/null 2>&1; then
  fail "malformed override code was accepted"
fi
cmp -s "$malformed_main" "$tmp/malformed.before" ||
  fail "failed canonicalization modified the Gemfile"
[ -e "$malformed_overrides" ] ||
  fail "failed canonicalization removed diagnostic input"

duplicate_main=$tmp/duplicate.Gemfile
duplicate_overrides=$tmp/duplicate.Gemfile.local
printf '%s\n' 'gem "rack", "~> 3.0"' >"$duplicate_main"
printf '%s\n' 'gem "rack", "=3.2.0"' 'gem "rack", "=3.2.1"' \
  >"$duplicate_overrides"
if "$helper" "$duplicate_main" "$duplicate_overrides" >/dev/null 2>&1; then
  fail "duplicate override names were accepted"
fi

printf '%s\n' 'Gemfile canonicalizer: PASS'
