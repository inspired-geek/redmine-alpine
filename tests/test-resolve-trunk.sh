#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
resolver=$root/scripts/resolve-trunk
catalog=$root/scripts/image-catalog
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
calls=$tmp/calls
: >"$calls"

cat >"$tmp/bin/git" <<'SH'
#!/bin/sh
set -eu
printf 'git\n' >>"$TRUNK_TEST_CALLS"
attempt=$(grep -c '^git$' "$TRUNK_TEST_CALLS")
[ "$attempt" -ge 3 ] || exit 75
printf '%s\trefs/heads/master\n' 0123456789abcdef0123456789abcdef01234567
SH

cat >"$tmp/bin/curl" <<'SH'
#!/bin/sh
set -eu
printf 'curl\n' >>"$TRUNK_TEST_CALLS"
output=
url=
while [ "$#" -gt 0 ]; do
  case $1 in
    --output)
      output=$2
      shift 2
      ;;
    http://*|https://*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done
case $url in
  https://api.github.com/repos/redmine/redmine/commits/*)
    printf '%s\n' \
      '{"sha":"0123456789abcdef0123456789abcdef01234567","commit":{"committer":{"date":"2026-07-01T12:34:56Z"}}}'
    ;;
  https://codeload.github.com/redmine/redmine/tar.gz/*)
    [ -n "$output" ] || exit 64
    printf 'resolved trunk archive\n' >"$output"
    ;;
  *)
    printf 'unexpected URL: %s\n' "$url" >&2
    exit 64
    ;;
esac
SH

cat >"$tmp/bin/skopeo" <<'SH'
#!/bin/sh
set -eu
printf 'skopeo\n' >>"$TRUNK_TEST_CALLS"
cat <<'JSON'
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "platform": {"architecture": "amd64", "os": "linux"}
    },
    {
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "platform": {"architecture": "arm64", "os": "linux"}
    }
  ]
}
JSON
SH
cat >"$tmp/bin/container-tools" <<'SH'
#!/bin/sh
set -eu
printf 'container-tools image=%s command=%s\n' \
  "${CONTAINER_TOOLS_IMAGE:-}" "$*" >>"$TRUNK_TEST_CALLS"
exec skopeo "$@"
SH
chmod 0755 \
  "$tmp/bin/git" "$tmp/bin/curl" "$tmp/bin/skopeo" \
  "$tmp/bin/container-tools"

if [ ! -x "$resolver" ]; then
  printf '%s\n' "FAIL: missing executable scripts/resolve-trunk" >&2
  exit 1
fi

resolution=$tmp/resolution.json
env PATH="$tmp/bin:$PATH" TRUNK_TEST_CALLS="$calls" \
  TRUNK_GIT_RETRY_DELAY_SECONDS=0 \
  TRUNK_CONTAINER_TOOLS="$tmp/bin/container-tools" \
  "$resolver" --output "$resolution"

ruby -rjson -rdigest -rtime -e '
  path, archive_text = ARGV
  value = JSON.parse(File.read(path))
  expected_keys = %w[
    builder_base created profile runtime_base source_commit
    source_date_epoch source_sha256 source_url
  ].sort
  abort "resolution keys" unless value.keys.sort == expected_keys
  commit = "0123456789abcdef0123456789abcdef01234567"
  abort "profile" unless value.fetch("profile") == "trunk"
  abort "commit" unless value.fetch("source_commit") == commit
  abort "URL" unless value.fetch("source_url") ==
    "https://codeload.github.com/redmine/redmine/tar.gz/#{commit}"
  abort "checksum" unless value.fetch("source_sha256") ==
    Digest::SHA256.hexdigest(archive_text)
  abort "created" unless value.fetch("created") == "2026-07-01T12:34:56Z"
  abort "epoch" unless value.fetch("source_date_epoch") ==
    Time.parse("2026-07-01T12:34:56Z").to_i
  expected_base =
    "ruby:3.4-alpine3.24@sha256:" + ("a" * 64)
  expected_runtime =
    "alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
  abort "builder base" unless value.fetch("builder_base") == expected_base
  abort "runtime base" unless value.fetch("runtime_base") == expected_runtime
' "$resolution" 'resolved trunk archive
'

[ "$(grep -c '^git$' "$calls")" -eq 3 ] ||
  fail "resolver did not retry git ls-remote twice"
[ "$(wc -l <"$calls" | tr -d ' ')" -eq 7 ] ||
  fail "resolver did not perform exactly seven external calls"
registry_tool=$(
  ruby -rjson -e \
    'print JSON.parse(File.read(ARGV.fetch(0))).dig("tool_policy", "registry_tool")' \
    "$root/build/images.json"
)
grep -F \
  "container-tools image=$registry_tool command=skopeo inspect --raw" \
  "$calls" >/dev/null || fail "resolver did not use the pinned registry tool"

before=$(wc -l <"$calls")
first=$("$catalog" profile trunk --resolution "$resolution")
second=$("$catalog" profile trunk --resolution "$resolution")
[ "$first" = "$second" ] || fail "resolved profile output changed"
[ "$(wc -l <"$calls")" -eq "$before" ] ||
  fail "catalog re-resolved external state"

printf '%s' "$first" | ruby -rjson -e '
  profile = JSON.parse(STDIN.read)
  source = profile.fetch("source")
  abort "resolved kind" unless source.fetch("kind") == "resolved_git_archive"
  abort "resolved commit" unless source.fetch("commit") ==
    "0123456789abcdef0123456789abcdef01234567"
  abort "resolved checksum" unless source.fetch("sha256").match?(/\A[0-9a-f]{64}\z/)
  abort "resolved epoch" unless source.fetch("source_date_epoch").positive?
  abort "resolved base" unless profile.dig("base", "reference").match?(
    /@sha256:[0-9a-f]{64}\z/
  )
  abort "resolved runtime base" unless profile.dig("base", "runtime_reference") ==
    "alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
'

args=$("$catalog" build-args trunk --resolution "$resolution")
printf '%s' "$args" | ruby -rjson -rbase64 -e '
  args = JSON.parse(STDIN.read)
  encoded = args.fetch(args.index("--build-arg") + 1)
  payload = encoded.delete_prefix("IMAGE_PROFILE_JSON_BASE64=")
  profile = JSON.parse(Base64.strict_decode64(payload))
  abort "build args are unresolved" unless profile.dig("source", "commit")
'

bad=$tmp/bad-resolution.json
ruby -rjson -e '
  value = JSON.parse(File.read(ARGV[0]))
  value["source_commit"] = "f" * 40
  File.write(ARGV[1], JSON.generate(value))
' "$resolution" "$bad"
if "$catalog" profile trunk --resolution "$bad" >/dev/null 2>&1; then
  fail "contradictory resolution was accepted"
fi

printf '%s\n' "trunk resolver: PASS"
