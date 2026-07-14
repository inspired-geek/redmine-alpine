#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
preflight=$root/scripts/image-preflight
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
log=$tmp/commands.log
cat >"$tmp/bin/prepare" <<'SH'
#!/bin/sh
set -eu
printf 'prepare %s\n' "$*" >>"$IMAGE_PREFLIGHT_TEST_LOG"
[ "$1" = 5.1 ]
mkdir -p "$4"
printf '%s\n' '{"imageLayoutVersion":"1.0.0"}' >"$4/oci-layout"
printf '%s\n' '{"schemaVersion":2,"manifests":[]}' >"$4/index.json"
SH
cat >"$tmp/bin/podman" <<'SH'
#!/bin/sh
set -eu
printf 'podman %s\n' "$*" >>"$IMAGE_PREFLIGHT_TEST_LOG"
case $1 in
  pull)
    [ "$2" = --quiet ]
    case $3 in oci:*:zstd-preflight) ;; *) exit 64 ;; esac
    printf '%s\n' fixture-zstd-image
    ;;
  run)
    case " $* " in
      *' exec puma --version '*) printf '%s\n' 'puma version 8.0.2' ;;
      *' exec ruby -e '*) ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$tmp/bin/prepare" "$tmp/bin/podman"
printf '%s\n' index >"$tmp/rootfs.index.oci.tar"
printf '%s\n' '{}' >"$tmp/metrics.json"

env PATH="$tmp/bin:$PATH" IMAGE_PREFLIGHT_DIRECT_PODMAN=1 \
  IMAGE_PREFLIGHT_PREPARE="$tmp/bin/prepare" \
  IMAGE_PREFLIGHT_TEST_LOG="$log" \
  "$preflight" 5.1 \
  --index-archive "$tmp/rootfs.index.oci.tar" \
  --metrics "$tmp/metrics.json"

grep -F 'podman pull --quiet oci:' "$log" >/dev/null ||
  fail "selected zstd OCI layout was not pulled"
grep -F 'exec puma --version' "$log" >/dev/null ||
  fail "Puma was not exercised from the zstd image"
grep -F 'exec ruby -e ' "$log" >/dev/null ||
  fail "native gems were not exercised from the zstd image"

set +e
"$preflight" 5.1 >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "invalid invocation did not exit 64"

printf '%s\n' 'zstd:chunked image preflight: PASS'
