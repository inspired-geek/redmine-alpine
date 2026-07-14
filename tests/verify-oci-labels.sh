#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 4 ]] || {
  echo "usage: $0 IMAGE VERSION REVISION CREATED" >&2
  exit 64
}

image=$1
expected_version=$2
expected_revision=$3
expected_created=$4
engine=${CONTAINER_ENGINE:-podman}

command -v "$engine" >/dev/null
command -v jq >/dev/null
labels=$(
  "$engine" image inspect "$image" |
    jq -ce '.[0].Config.Labels // error("image has no config labels")'
)

fail() {
  printf 'FAIL [%s]: %s\n' "$image" "$*" >&2
  exit 1
}

label() {
  jq -r --arg key "$1" '.[$key] // ""' <<<"$labels"
}

assert_equal() {
  local key=$1 expected=$2 actual
  actual=$(label "$key")
  [[ "$actual" == "$expected" ]] ||
    fail "$key is '$actual', expected '$expected'"
}

for key in \
  org.opencontainers.image.authors \
  org.opencontainers.image.description \
  org.opencontainers.image.title
do
  [[ -n "$(label "$key")" ]] || fail "$key is empty"
done

assert_equal \
  org.opencontainers.image.source \
  https://github.com/inspired-geek/redmine-alpine
assert_equal \
  org.opencontainers.image.documentation \
  https://github.com/inspired-geek/redmine-alpine#readme
assert_equal \
  org.opencontainers.image.url \
  https://github.com/inspired-geek/redmine-alpine
assert_equal org.opencontainers.image.licenses GPL-2.0-or-later
assert_equal org.opencontainers.image.version "$expected_version"
assert_equal org.opencontainers.image.revision "$expected_revision"
assert_equal org.opencontainers.image.created "$expected_created"

description_length=$(
  jq -r '."org.opencontainers.image.description" | length' <<<"$labels"
)
(( description_length <= 512 )) ||
  fail "org.opencontainers.image.description is $description_length characters, maximum is 512"

license_length=$(
  jq -r '."org.opencontainers.image.licenses" | length' <<<"$labels"
)
(( license_length <= 256 )) ||
  fail "org.opencontainers.image.licenses is $license_length characters, maximum is 256"
