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

comment_main=$tmp/comment.Gemfile
comment_overrides=$tmp/comment.Gemfile.local
printf '%s\n' \
  'gem "puma", "~> 6.0" # runtime server' \
  'gem "rack", "~> 3.0"' >"$comment_main"
printf '%s\n' 'gem "puma", "8.0.2"' >"$comment_overrides"
"$helper" "$comment_main" "$comment_overrides"
grep -Fx 'gem "rack", "~> 3.0"' "$comment_main" >/dev/null ||
  fail "declaration after a trailing comment was removed"

multiline_main=$tmp/multiline.Gemfile
multiline_overrides=$tmp/multiline.Gemfile.local
printf '%s\n' \
  'gem "sqlite3", # pinned native adapter' \
  '  "~> 1.7"' \
  'gem "rack", "~> 3.0"' >"$multiline_main"
printf '%s\n' 'gem "sqlite3", "=2.9.4"' >"$multiline_overrides"
"$helper" "$multiline_main" "$multiline_overrides"
if grep -F '~> 1.7' "$multiline_main" >/dev/null; then
  fail "continuation after an inline comment survived canonicalization"
fi
grep -Fx 'gem "rack", "~> 3.0"' "$multiline_main" >/dev/null ||
  fail "declaration after a multiline override was removed"

interleaved_main=$tmp/interleaved.Gemfile
interleaved_overrides=$tmp/interleaved.Gemfile.local
printf '%s\n' \
  'gem "sqlite3",' \
  '  # pinned native adapter' \
  '  "~> 1.7"' \
  'gem "rack", "~> 3.0"' >"$interleaved_main"
printf '%s\n' 'gem "sqlite3", "=2.9.4"' >"$interleaved_overrides"
"$helper" "$interleaved_main" "$interleaved_overrides"
if grep -F '~> 1.7' "$interleaved_main" >/dev/null; then
  fail "continuation after a whole-line comment survived canonicalization"
fi
grep -Fx 'gem "rack", "~> 3.0"' "$interleaved_main" >/dev/null ||
  fail "declaration after an interleaved multiline override was removed"

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
