#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
compressor=$root/scripts/image-compress
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/output"
podman_log=$tmp/podman.log
indexer_log=$tmp/indexer.log

cat >"$tmp/bin/podman" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$IMAGE_COMPRESS_TEST_PODMAN_LOG"
[ "$1" = push ] || exit 64
[ "${IMAGE_COMPRESS_TEST_FAIL:-0}" != 1 ] || exit 38
shift
[ "$1" = --format ] && [ "$2" = oci ] || exit 64
shift 2
[ "$1" = --compression-format ] && [ "$2" = zstd:chunked ] || exit 64
shift 2
[ "$1" = --compression-level ] &&
  [ "$2" = "${IMAGE_COMPRESS_TEST_LEVEL:-7}" ] || exit 64
shift 2
[ "$1" = --force-compression ] || exit 64
shift
[ "$1" = --digestfile ] || exit 64
digestfile=$2
shift 2
image=$1
destination=$2
[ "$image" = localhost/redmine-alpine:5.1-test ] || exit 64
path=${destination#oci-archive:}
path=${path%:*}
printf '%s\n' 'zstd:chunked archive fixture' >"$path"
printf 'sha256:%s\n' dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  >"$digestfile"
SH
chmod 0755 "$tmp/bin/podman"

cat >"$tmp/bin/oci-index" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$IMAGE_COMPRESS_TEST_INDEXER_LOG"
[ "$1" = 5.1 ] || exit 64
shift
[ "$1" = --gzip-archive ] || exit 64
[ -s "$2" ] || exit 64
shift 2
[ "$1" = --zstd-chunked-archive ] || exit 64
[ -s "$2" ] || exit 64
shift 2
[ "$1" = --output ] || exit 64
printf '%s\n' 'dual-compression OCI index fixture' >"$2"
printf '%s\n' \
  'OCI index: PASS profile=5.1 digest=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
SH
chmod 0755 "$tmp/bin/oci-index"

printf '%s\n' 'gzip archive fixture' >"$tmp/output/rootfs.oci.tar"

[ -x "$compressor" ] || fail "missing executable scripts/image-compress"

env PATH="$tmp/bin:$PATH" \
  IMAGE_COMPRESS_DIRECT_PODMAN=1 \
  IMAGE_COMPRESS_INDEXER="$tmp/bin/oci-index" \
  IMAGE_COMPRESS_TEST_PODMAN_LOG="$podman_log" \
  IMAGE_COMPRESS_TEST_INDEXER_LOG="$indexer_log" \
  "$compressor" 5.1 \
  --image localhost/redmine-alpine:5.1-test \
  --gzip-archive "$tmp/output/rootfs.oci.tar" \
  --output-dir "$tmp/output" \
  --zstd-level 7

[ -s "$tmp/output/rootfs.zstd-chunked.oci.tar" ] ||
  fail "zstd:chunked archive missing"
[ -s "$tmp/output/rootfs.index.oci.tar" ] ||
  fail "dual-compression index archive missing"
[ -s "$tmp/output/compression.json" ] || fail "compression metadata missing"

grep -F \
  'push --format oci --compression-format zstd:chunked --compression-level 7 --force-compression --digestfile' \
  "$podman_log" >/dev/null || fail "Podman zstd:chunked argv changed"
grep -F \
  '5.1 --gzip-archive' "$indexer_log" >/dev/null ||
  fail "OCI index builder was not called"

ruby -rjson -rdigest -e '
  output = ARGV.fetch(0)
  metadata = JSON.parse(File.read(File.join(output, "compression.json")))
  abort "profile" unless metadata.fetch("profile") == "5.1"
  gzip = metadata.fetch("gzip")
  zstd = metadata.fetch("zstd_chunked")
  index = metadata.fetch("index")
  abort "gzip level" unless gzip.fetch("level") == 9
  abort "zstd level" unless zstd.fetch("level") == 7
  abort "zstd digest" unless zstd.fetch("image_digest") == "sha256:" + ("d" * 64)
  {
    gzip => "rootfs.oci.tar",
    zstd => "rootfs.zstd-chunked.oci.tar",
    index => "rootfs.index.oci.tar"
  }.each do |entry, name|
    path = File.join(output, name)
    abort "archive name" unless entry.fetch("archive") == name
    abort "archive bytes" unless entry.fetch("bytes") == File.size(path)
    abort "archive sha" unless entry.fetch("sha256") == Digest::SHA256.file(path).hexdigest
  end
' "$tmp/output"

mkdir -p "$tmp/selected"
cp "$tmp/output/rootfs.oci.tar" "$tmp/selected/rootfs.oci.tar"
: >"$podman_log"
env PATH="$tmp/bin:$PATH" \
  IMAGE_COMPRESS_DIRECT_PODMAN=1 \
  IMAGE_COMPRESS_INDEXER="$tmp/bin/oci-index" \
  IMAGE_COMPRESS_TEST_LEVEL=10 \
  IMAGE_COMPRESS_TEST_PODMAN_LOG="$podman_log" \
  IMAGE_COMPRESS_TEST_INDEXER_LOG="$indexer_log" \
  "$compressor" 5.1 \
  --image localhost/redmine-alpine:5.1-test \
  --gzip-archive "$tmp/selected/rootfs.oci.tar" \
  --output-dir "$tmp/selected" >/dev/null
grep -F -- '--compression-level 10' "$podman_log" >/dev/null ||
  fail "selected catalog zstd level was not used by default"
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "selected level" unless value.dig("zstd_chunked", "level") == 10
' "$tmp/selected/compression.json"

: >"$podman_log"
set +e
env PATH="$tmp/bin:$PATH" \
  IMAGE_COMPRESS_DIRECT_PODMAN=1 \
  IMAGE_COMPRESS_INDEXER="$tmp/bin/oci-index" \
  IMAGE_COMPRESS_TEST_PODMAN_LOG="$podman_log" \
  IMAGE_COMPRESS_TEST_INDEXER_LOG="$indexer_log" \
  "$compressor" 5.1 \
  --image localhost/redmine-alpine:5.1-test \
  --gzip-archive "$tmp/output/rootfs.oci.tar" \
  --output-dir "$tmp/rejected" \
  --zstd-level 12 >"$tmp/rejected.log" 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "invalid zstd level returned $status instead of 64"
[ ! -s "$podman_log" ] || fail "invalid zstd level invoked Podman"

mkdir -p "$tmp/failed"
cp "$tmp/output/rootfs.oci.tar" "$tmp/failed/rootfs.oci.tar"
set +e
env PATH="$tmp/bin:$PATH" \
  IMAGE_COMPRESS_DIRECT_PODMAN=1 \
  IMAGE_COMPRESS_INDEXER="$tmp/bin/oci-index" \
  IMAGE_COMPRESS_TEST_PODMAN_LOG="$podman_log" \
  IMAGE_COMPRESS_TEST_INDEXER_LOG="$indexer_log" \
  IMAGE_COMPRESS_TEST_FAIL=1 \
  "$compressor" 5.1 \
  --image localhost/redmine-alpine:5.1-test \
  --gzip-archive "$tmp/failed/rootfs.oci.tar" \
  --output-dir "$tmp/failed" \
  --zstd-level 7 >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 38 ] || fail "Podman compression failure was not propagated"
[ ! -e "$tmp/failed/rootfs.zstd-chunked.oci.tar" ] ||
  fail "failed compression left a zstd archive"
[ ! -e "$tmp/failed/rootfs.index.oci.tar" ] ||
  fail "failed compression left an index archive"
[ ! -e "$tmp/failed/compression.json" ] ||
  fail "failed compression emitted success metadata"

printf '%s\n' 'image compression driver: PASS'
