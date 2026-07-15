#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"

cat >"$tmp/bin/fake-engine" <<'FAKE'
#!/bin/sh
set -eu
[ "$1 $2 $3" = "image inspect fixture:7.0" ] || exit 64
license=${FAKE_LICENSE:-GPL-2.0-or-later}
source=${FAKE_SOURCE:-https://github.com/inspired-geek/redmine-alpine}
documentation=${FAKE_DOCUMENTATION:-https://github.com/inspired-geek/redmine-alpine#readme}
version=${FAKE_VERSION:-7.0.0}
revision=${FAKE_REVISION:-fixture-revision}
created=${FAKE_CREATED:-2026-07-11T12:00:00Z}
description=${FAKE_DESCRIPTION-Redmine 7.0.0 on Alpine with Puma; fully supported current stable release}
printf '%s\n' \
  '[{"Config":{"Labels":{' \
  '"org.opencontainers.image.authors":"Alexey Ivanov <lexa.ivanov@gmail.com>",' \
  "\"org.opencontainers.image.created\":\"${created}\"," \
  "\"org.opencontainers.image.description\":\"${description}\"," \
  "\"org.opencontainers.image.documentation\":\"${documentation}\"," \
  "\"org.opencontainers.image.licenses\":\"${license}\"," \
  "\"org.opencontainers.image.revision\":\"${revision}\"," \
  "\"org.opencontainers.image.source\":\"${source}\"," \
  '"org.opencontainers.image.title":"Redmine 7.0 Alpine",' \
  '"org.opencontainers.image.url":"https://github.com/inspired-geek/redmine-alpine",' \
  "\"org.opencontainers.image.version\":\"${version}\"" \
  '}}}]'
FAKE
chmod +x "$tmp/bin/fake-engine"

CONTAINER_ENGINE="$tmp/bin/fake-engine" \
  tests/verify-oci-labels.sh \
  fixture:7.0 7.0.0 fixture-revision 2026-07-11T12:00:00Z

expect_rejected() {
  assignment=$1
  expected_key=$2
  if env "$assignment" CONTAINER_ENGINE="$tmp/bin/fake-engine" \
    tests/verify-oci-labels.sh \
    fixture:7.0 7.0.0 fixture-revision 2026-07-11T12:00:00Z \
    >"$tmp/output" 2>"$tmp/error"
  then
    printf 'invalid label was accepted: %s\n' "$assignment" >&2
    exit 1
  fi
  grep -F "$expected_key" "$tmp/error" >/dev/null
}

expect_rejected FAKE_LICENSE=MIT org.opencontainers.image.licenses
expect_rejected FAKE_SOURCE=https://example.invalid org.opencontainers.image.source
expect_rejected FAKE_DOCUMENTATION=https://example.invalid org.opencontainers.image.documentation
expect_rejected FAKE_VERSION=wrong org.opencontainers.image.version
expect_rejected FAKE_REVISION=wrong org.opencontainers.image.revision
expect_rejected FAKE_CREATED=wrong org.opencontainers.image.created
expect_rejected FAKE_DESCRIPTION= org.opencontainers.image.description

printf 'OCI label verifier: PASS\n'
