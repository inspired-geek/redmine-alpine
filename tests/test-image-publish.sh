#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
publisher=$root/scripts/image-publish
tmp=$(mktemp -d)
tmp=$(CDPATH= cd -- "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin"

ruby -rjson -rdigest -rrubygems/package -e '
  archive, manifest_path = ARGV
  media_type = "application/vnd.oci.image.index.v1+json"
  manifest = JSON.generate(
    "schemaVersion" => 2,
    "mediaType" => media_type,
    "manifests" => [],
    "annotations" => {"org.opencontainers.image.title" => "fixture"}
  )
  File.binwrite(manifest_path, manifest)
  digest = Digest::SHA256.hexdigest(manifest)
  index = JSON.generate(
    "schemaVersion" => 2,
    "mediaType" => media_type,
    "manifests" => [{
      "mediaType" => media_type,
      "digest" => "sha256:#{digest}",
      "size" => manifest.bytesize
    }]
  )
  files = {
    "blobs/sha256/#{digest}" => manifest,
    "index.json" => index,
    "oci-layout" => JSON.generate("imageLayoutVersion" => "1.0.0")
  }
  File.open(archive, "wb") do |file|
    Gem::Package::TarWriter.new(file) do |tar|
      files.sort.each do |name, contents|
        tar.add_file_simple(name, 0o644, contents.bytesize) do |entry|
          entry.write(contents)
        end
      end
    end
  end
' "$tmp/index.oci.tar" "$tmp/expected-manifest.json"

expected_digest=$(
  ruby -rdigest -e 'print "sha256:#{Digest::SHA256.file(ARGV.fetch(0)).hexdigest}"' \
    "$tmp/expected-manifest.json"
)
ruby -rjson -rdigest -e '
  archive, output, digest = ARGV
  value = {
    "schema_version" => 1,
    "profile" => "5.1",
    "content" => {"index_digest" => digest},
    "archives" => {
      "index" => {
        "bytes" => File.size(archive),
        "sha256" => Digest::SHA256.file(archive).hexdigest
      }
    }
  }
  File.write(output, JSON.generate(value))
' "$tmp/index.oci.tar" "$tmp/metrics.json" "$expected_digest"

cat >"$tmp/bin/status-probe" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$IMAGE_PUBLISH_TEST_PROBE_LOG"
case ${FAKE_PROBE_STATUS:-absent} in
  present|absent) printf '%s\n' "$FAKE_PROBE_STATUS" ;;
  error) printf '%s\n' 'indeterminate registry state' >&2; exit 70 ;;
  *) exit 64 ;;
esac
SH

cat >"$tmp/bin/skopeo" <<'SH'
#!/bin/sh
set -eu

command=$1
shift
printf 'skopeo %s' "$command" >>"$IMAGE_PUBLISH_TEST_SKOPEO_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >>"$IMAGE_PUBLISH_TEST_SKOPEO_LOG"
done
printf '\n' >>"$IMAGE_PUBLISH_TEST_SKOPEO_LOG"

authfile=
reference=
previous=
for argument in "$@"; do
  case $previous in
    --authfile|--dest-authfile) authfile=$argument ;;
  esac
  previous=$argument
  reference=$argument
done

[ -n "$authfile" ] && [ -f "$authfile" ] || {
  printf '%s\n' 'missing registry auth file' >&2
  exit 65
}
ruby -rjson -rbase64 -e '
  path = ARGV.fetch(0)
  abort "auth mode" unless (File.stat(path).mode & 0o777) == 0o600
  auth = JSON.parse(File.read(path)).dig("auths", "ghcr.io", "auth")
  abort "auth payload" unless Base64.strict_decode64(auth) == "test-user:test-token"
' "$authfile"

tag=${reference##*:}
case $command in
  copy)
    if [ "${FAKE_COPY_FAIL_TAG:-}" = "$tag" ]; then
      exit 37
    fi
    ;;
  inspect)
    if [ "${FAKE_INSPECT_FAIL_TAG:-}" = "$tag" ]; then
      exit 38
    fi
    if [ "${FAKE_INSPECT_MISMATCH_TAG:-}" = "$tag" ]; then
      printf '%s' '{"mismatch":true}'
    else
      cat "$IMAGE_PUBLISH_EXPECTED_MANIFEST"
    fi
    ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$tmp/bin/status-probe" "$tmp/bin/skopeo"

[ -x "$publisher" ] || fail "missing executable scripts/image-publish"

run_publish() {
  env \
    PATH="$tmp/bin:$PATH" \
    GHCR_USER=test-user \
    GHCR_TOKEN=test-token \
    IMAGE_PUBLISH_DIRECT_SKOPEO=1 \
    IMAGE_PUBLISH_STATUS_PROBE="$tmp/bin/status-probe" \
    IMAGE_PUBLISH_EXPECTED_MANIFEST="$tmp/expected-manifest.json" \
    IMAGE_PUBLISH_TEST_PROBE_LOG="$tmp/probe.log" \
    IMAGE_PUBLISH_TEST_SKOPEO_LOG="$tmp/skopeo.log" \
    "$@"
}

: >"$tmp/probe.log"
: >"$tmp/skopeo.log"
actual=$(FAKE_PROBE_STATUS=absent run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --image ghcr.io/inspired-geek/redmine-alpine)
[ "$actual" = "image publish: PASS profile=5.1 digest=$expected_digest published=5.1.13,5.1 verified=- preserved=-" ] ||
  fail "publish summary changed: $actual"

[ "$(wc -l <"$tmp/probe.log" | tr -d ' ')" -eq 1 ] ||
  fail "immutable tag probe count changed"
grep -Fx 'ghcr.io/inspired-geek/redmine-alpine 5.1.13' "$tmp/probe.log" >/dev/null ||
  fail "immutable tag probe argv changed"
[ "$(wc -l <"$tmp/skopeo.log" | tr -d ' ')" -eq 4 ] ||
  fail "absent immutable publish command count changed"
sed -n '1p' "$tmp/skopeo.log" | grep -F \
  'skopeo copy --all --preserve-digests --dest-authfile ' >/dev/null ||
  fail "immutable copy flags changed"
sed -n '1p' "$tmp/skopeo.log" | grep -F \
  "oci-archive:$tmp/index.oci.tar docker://ghcr.io/inspired-geek/redmine-alpine:5.1.13" \
  >/dev/null || fail "immutable tag was not published first"
sed -n '2p' "$tmp/skopeo.log" | grep -F \
  'skopeo inspect --raw --authfile ' >/dev/null ||
  fail "immutable verification flags changed"
sed -n '2p' "$tmp/skopeo.log" | grep -F \
  'docker://ghcr.io/inspired-geek/redmine-alpine:5.1.13' >/dev/null ||
  fail "immutable verification tag changed"
sed -n '3p' "$tmp/skopeo.log" | grep -F \
  'docker://ghcr.io/inspired-geek/redmine-alpine:5.1' >/dev/null ||
  fail "moving tag was not promoted after immutable verification"
sed -n '4p' "$tmp/skopeo.log" | grep -F \
  'docker://ghcr.io/inspired-geek/redmine-alpine:5.1' >/dev/null ||
  fail "moving tag verification changed"
if grep -F 'test-token' "$tmp/skopeo.log" >/dev/null; then
  fail "registry token leaked into Skopeo argv"
fi
authfile=$(sed -n '1s/.*--dest-authfile \([^ ]*\).*/\1/p' "$tmp/skopeo.log")
[ -n "$authfile" ] && [ ! -e "$authfile" ] ||
  fail "temporary registry auth file was not removed"

: >"$tmp/probe.log"
: >"$tmp/skopeo.log"
present_output=$(FAKE_PROBE_STATUS=present run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --image ghcr.io/inspired-geek/redmine-alpine)
[ "$present_output" = "image publish: PASS profile=5.1 digest=$expected_digest published=5.1 verified=5.1.13 preserved=-" ] ||
  fail "verified immutable summary changed: $present_output"
[ "$(wc -l <"$tmp/skopeo.log" | tr -d ' ')" -eq 3 ] ||
  fail "existing immutable tag command count changed"
sed -n '1p' "$tmp/skopeo.log" | grep -F 'skopeo inspect --raw' >/dev/null ||
  fail "existing immutable tag was not verified first"
if grep -F 'copy ' "$tmp/skopeo.log" | grep -F ':5.1.13' >/dev/null; then
  fail "existing immutable tag was overwritten"
fi

: >"$tmp/skopeo.log"
set +e
FAKE_PROBE_STATUS=present FAKE_INSPECT_MISMATCH_TAG=5.1.13 run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --image ghcr.io/inspired-geek/redmine-alpine >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"
status=$?
set -e
[ "$status" -eq 0 ] ||
  fail "an existing immutable tag blocked its moving tag"
grep -F \
  "image-publish: immutable tag preserved profile=5.1 tag=5.1.13 remote=" \
  "$tmp/mismatch.err" >/dev/null ||
  fail "immutable preservation diagnostic is missing"
grep -F '::warning title=Immutable image tag preserved::profile=5.1 tag=5.1.13' \
  "$tmp/mismatch.err" >/dev/null ||
  fail "immutable divergence did not emit an Actions warning"
expected_mismatch_summary="image publish: PASS profile=5.1 digest=$expected_digest published=5.1 verified=- preserved=5.1.13"
[ "$(cat "$tmp/mismatch.out")" = "$expected_mismatch_summary" ] ||
  fail "preserved immutable summary changed: $(cat "$tmp/mismatch.out")"
[ "$(wc -l <"$tmp/skopeo.log" | tr -d ' ')" -eq 3 ] ||
  fail "moving tag was not published after preserving an immutable tag"
if grep -F 'skopeo copy' "$tmp/skopeo.log" | grep -F ':5.1.13' >/dev/null; then
  fail "existing immutable tag was overwritten"
fi
grep -F 'skopeo copy' "$tmp/skopeo.log" | grep -F ':5.1' >/dev/null ||
  fail "moving tag was not updated after immutable preservation"

: >"$tmp/skopeo.log"
set +e
FAKE_PROBE_STATUS=error run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --image ghcr.io/inspired-geek/redmine-alpine \
  >/dev/null 2>"$tmp/probe-error.err"
status=$?
set -e
[ "$status" -eq 70 ] || fail "indeterminate probe status was not propagated"
[ ! -s "$tmp/skopeo.log" ] || fail "indeterminate probe performed registry writes"
grep -F \
  'profile=5.1 phase=immutable-probe tag=5.1.13 expected=present-or-absent actual=indeterminate status=70' \
  "$tmp/probe-error.err" >/dev/null ||
  fail "indeterminate probe diagnostic changed"

: >"$tmp/skopeo.log"
set +e
FAKE_PROBE_STATUS=absent FAKE_COPY_FAIL_TAG=5.1.13 run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --image ghcr.io/inspired-geek/redmine-alpine \
  >/dev/null 2>"$tmp/copy-error.err"
status=$?
set -e
[ "$status" -eq 37 ] || fail "immutable copy failure was not propagated"
[ "$(wc -l <"$tmp/skopeo.log" | tr -d ' ')" -eq 1 ] ||
  fail "moving tag was attempted after immutable copy failure"
grep -F \
  "profile=5.1 phase=publish kind=immutable tag=5.1.13 expected=$expected_digest actual=copy-failed status=37" \
  "$tmp/copy-error.err" >/dev/null || fail "copy failure diagnostic changed"

: >"$tmp/skopeo.log"
set +e
FAKE_PROBE_STATUS=absent FAKE_COPY_FAIL_TAG= \
  FAKE_INSPECT_MISMATCH_TAG= FAKE_INSPECT_FAIL_TAG=5.1.13 run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --image ghcr.io/inspired-geek/redmine-alpine \
  >/dev/null 2>"$tmp/inspect-error.err"
status=$?
set -e
[ "$status" -eq 38 ] || fail "remote inspect failure was not propagated"
[ "$(wc -l <"$tmp/skopeo.log" | tr -d ' ')" -eq 2 ] ||
  fail "moving tag was attempted after remote inspect failure"
grep -F \
  "profile=5.1 phase=verify kind=immutable tag=5.1.13 expected=$expected_digest actual=unavailable status=38" \
  "$tmp/inspect-error.err" >/dev/null || fail "inspect failure diagnostic changed"

: >"$tmp/probe.log"
: >"$tmp/skopeo.log"
ruby -rjson -e '
  source, output = ARGV
  value = JSON.parse(File.read(source))
  value["profile"] = "3.4"
  File.write(output, JSON.generate(value))
' "$tmp/metrics.json" "$tmp/metrics-3.4.json"
run_publish \
  "$publisher" 3.4 \
  --index-archive "$tmp/index.oci.tar" \
  --metrics "$tmp/metrics-3.4.json" \
  --image ghcr.io/inspired-geek/redmine-alpine >/dev/null
[ ! -s "$tmp/probe.log" ] || fail "moving-only profile probed an immutable tag"
[ "$(wc -l <"$tmp/skopeo.log" | tr -d ' ')" -eq 2 ] ||
  fail "moving-only publish command count changed"
grep -F 'docker://ghcr.io/inspired-geek/redmine-alpine:3.4' "$tmp/skopeo.log" >/dev/null ||
  fail "moving-only tag changed"

: >"$tmp/skopeo.log"
ruby -rjson -e '
  source, output = ARGV
  value = JSON.parse(File.read(source))
  value.dig("archives", "index")["sha256"] = "0" * 64
  File.write(output, JSON.generate(value))
' "$tmp/metrics.json" "$tmp/tampered-metrics.json"
set +e
run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --metrics "$tmp/tampered-metrics.json" \
  --image ghcr.io/inspired-geek/redmine-alpine \
  >/dev/null 2>"$tmp/metrics-error.err"
status=$?
set -e
[ "$status" -eq 1 ] || fail "tampered metrics status changed"
grep -F 'index archive sha256 contradicts metrics' "$tmp/metrics-error.err" >/dev/null ||
  fail "tampered metrics diagnostic changed"
[ ! -s "$tmp/skopeo.log" ] || fail "tampered metrics reached registry tooling"

: >"$tmp/skopeo.log"
set +e
run_publish \
  "$publisher" 5.1 \
  --index-archive "$tmp/index.oci.tar" \
  --image 'docker.io/inspired-geek/redmine-alpine' >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "non-GHCR image was accepted"
[ ! -s "$tmp/skopeo.log" ] || fail "invalid image reached registry tooling"

printf '%s\n' 'fail-closed image publisher: PASS'
