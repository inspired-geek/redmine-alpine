#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
preflight=$root/scripts/image-preflight
fixture_builder=$root/tests/fixtures/make-preflight-fixture.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$preflight" ] || fail "missing executable scripts/image-preflight"
[ -f "$fixture_builder" ] || fail "missing OCI preflight fixture builder"

mkdir -p "$tmp/bin"
log=$tmp/commands.log
cat >"$tmp/bin/container-tools" <<'SH'
#!/bin/sh
set -eu

[ "$CONTAINER_TOOLS_IMAGE" = "$IMAGE_PREFLIGHT_EXPECTED_TOOLCHAIN" ] || {
  printf '%s\n' 'unpinned toolchain image' >&2
  exit 65
}
[ "$1" = sh ] && [ "$2" = -eu ] && [ "$3" = -c ] && [ "$5" = sh ] ||
  exit 64
partial_config=$4
printf '%s' "$partial_config" | grep -F '[storage.options.pull_options]' >/dev/null ||
  exit 65
printf '%s' "$partial_config" | grep -F 'enable_partial_images' >/dev/null ||
  exit 65
printf '%s' "$partial_config" | grep -F 'true' >/dev/null ||
  exit 65
shift 5

printf 'podman' >>"$IMAGE_PREFLIGHT_TEST_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >>"$IMAGE_PREFLIGHT_TEST_LOG"
done
printf '\n' >>"$IMAGE_PREFLIGHT_TEST_LOG"

case $1 in
  pull)
    [ "$2" = --quiet ]
    case $3 in oci:*:zstd-preflight) ;; *) exit 64 ;; esac
    [ "${IMAGE_PREFLIGHT_EMPTY_IMAGE_ID:-0}" != 1 ] || exit 0
    printf '%s\n' fixture-zstd-image
    ;;
  run)
    case " $* " in
      *' exec puma --version '*)
        printf '%s\n' "${IMAGE_PREFLIGHT_PUMA_OUTPUT:-puma version 8.0.2}"
        ;;
      *' exec ruby -e '*) ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$tmp/bin/container-tools"

python3 "$fixture_builder" \
  --archive "$tmp/rootfs.index.oci.tar" \
  --metrics "$tmp/metrics.json"

toolchain=$(
  "$root/scripts/image-catalog" tool-policy |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["toolchain"])'
)

run_preflight() {
  env \
    IMAGE_PREFLIGHT_CONTAINER_TOOLS="$tmp/bin/container-tools" \
    IMAGE_PREFLIGHT_EXPECTED_TOOLCHAIN="$toolchain" \
    IMAGE_PREFLIGHT_TEST_LOG="$log" \
    "$@"
}

: >"$log"
run_preflight "$preflight" 5.1 \
  --index-archive "$tmp/rootfs.index.oci.tar" \
  --metrics "$tmp/metrics.json"

grep -F 'podman pull --quiet oci:' "$log" >/dev/null ||
  fail "selected zstd OCI layout was not pulled"
grep -F 'exec puma --version' "$log" >/dev/null ||
  fail "Puma was not exercised from the zstd image"
grep -F 'exec ruby -e ' "$log" >/dev/null ||
  fail "native gems were not exercised from the zstd image"
[ "$(wc -l <"$log" | tr -d ' ')" -eq 3 ] ||
  fail "unexpected pinned toolchain command count"

assert_preparation_failure() {
  expected=$1
  archive=$2
  metrics=$3
  : >"$log"
  set +e
  run_preflight "$preflight" 5.1 \
    --index-archive "$archive" --metrics "$metrics" \
    >"$tmp/failure.out" 2>"$tmp/failure.err"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "invalid OCI input unexpectedly passed: $expected"
  grep -F "$expected" "$tmp/failure.err" >/dev/null ||
    fail "missing preflight diagnostic: $expected"
  [ ! -s "$log" ] || fail "invalid OCI input reached Podman: $expected"
}

cp "$tmp/metrics.json" "$tmp/checksum-mismatch.json"
python3 - "$tmp/checksum-mismatch.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    value = json.load(source)
value["archives"]["index"]["sha256"] = "0" * 64
with open(path, "w", encoding="utf-8") as output:
    json.dump(value, output, separators=(",", ":"))
PY
assert_preparation_failure 'index archive checksum mismatch' \
  "$tmp/rootfs.index.oci.tar" "$tmp/checksum-mismatch.json"

python3 "$fixture_builder" \
  --archive "$tmp/no-marker.oci.tar" \
  --metrics "$tmp/no-marker.json" \
  --omit-zstd-marker
assert_preparation_failure 'zstd:chunked descriptor missing' \
  "$tmp/no-marker.oci.tar" "$tmp/no-marker.json"

python3 "$fixture_builder" \
  --archive "$tmp/digest-mismatch.oci.tar" \
  --metrics "$tmp/digest-mismatch.json" \
  --mismatch-zstd-digest
assert_preparation_failure 'zstd:chunked digest mismatch' \
  "$tmp/digest-mismatch.oci.tar" "$tmp/digest-mismatch.json"

: >"$log"
set +e
IMAGE_PREFLIGHT_EMPTY_IMAGE_ID=1 run_preflight "$preflight" 5.1 \
  --index-archive "$tmp/rootfs.index.oci.tar" \
  --metrics "$tmp/metrics.json" >"$tmp/empty.out" 2>"$tmp/empty.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail "empty Podman image ID unexpectedly passed"
grep -F 'Podman returned an empty zstd:chunked image ID' "$tmp/empty.err" >/dev/null ||
  fail "empty image ID diagnostic changed"

: >"$log"
set +e
IMAGE_PREFLIGHT_EMPTY_IMAGE_ID=0 \
  IMAGE_PREFLIGHT_PUMA_OUTPUT='puma version 0.0.0' \
  run_preflight "$preflight" 5.1 \
    --index-archive "$tmp/rootfs.index.oci.tar" \
    --metrics "$tmp/metrics.json" >"$tmp/puma.out" 2>"$tmp/puma.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail "wrong Puma version unexpectedly passed"
grep -F 'zstd:chunked Puma version mismatch' "$tmp/puma.err" >/dev/null ||
  fail "Puma mismatch diagnostic changed"

set +e
"$preflight" 5.1 >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "invalid invocation did not exit 64"

printf '%s\n' 'zstd:chunked image preflight: PASS'
