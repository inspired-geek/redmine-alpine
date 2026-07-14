#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf 'usage: %s ghcr.io/OWNER/IMAGE TAG\n' "$0" >&2
  exit 64
fi

image=$1
tag=$2
if ! ruby -e '
  reference = ARGV.fetch(0)
  pattern = %r{\Aghcr\.io/[a-z0-9]+(?:[._-][a-z0-9]+)*/[a-z0-9]+(?:[._/-][a-z0-9]+)*\z}
  exit(pattern.match?(reference) ? 0 : 1)
' "$image"
then
  printf 'unsupported image reference: %s\n' "$image" >&2
  exit 64
fi
if ! ruby -e '
  tag = ARGV.fetch(0)
  exit(/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/.match?(tag) ? 0 : 1)
' "$tag"
then
  printf 'unsupported manifest tag: %s\n' "$tag" >&2
  exit 64
fi

: "${GHCR_USER:?GHCR_USER is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

image_path=${image#ghcr.io/}
temporary=$(mktemp -d)
chmod 0700 "$temporary"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
basic_header=$temporary/basic.header
GHCR_BASIC_HEADER=$basic_header ruby -rbase64 -e '
  path = ENV.fetch("GHCR_BASIC_HEADER")
  value = Base64.strict_encode64(
    "#{ENV.fetch("GHCR_USER")}:#{ENV.fetch("GHCR_TOKEN")}"
  )
  File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write("Authorization: Basic #{value}\n")
  end
  File.chmod(0o600, path)
'
token_response=$(
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 60 \
    --header "@$basic_header" \
    --get \
    --data-urlencode "service=ghcr.io" \
    --data-urlencode "scope=repository:${image_path}:pull,push" \
    https://ghcr.io/token
)

bearer=$(
  printf '%s' "$token_response" |
    ruby -rjson -e '
      data = JSON.parse(STDIN.read)
      token = data["token"] || data["access_token"]
      abort "GHCR did not return a bearer token" unless token.is_a?(String) && !token.empty?
      print token
    '
)

bearer_header=$temporary/bearer.header
GHCR_BEARER_HEADER=$bearer_header GHCR_BEARER_TOKEN=$bearer ruby -e '
  path = ENV.fetch("GHCR_BEARER_HEADER")
  token = ENV.fetch("GHCR_BEARER_TOKEN")
  File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write("Authorization: Bearer #{token}\n")
  end
  File.chmod(0o600, path)
'
response_file=$temporary/response
status=$(
  curl \
    --silent \
    --show-error \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 60 \
    --header "@$bearer_header" \
    --header 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    --output "$response_file" \
    --write-out '%{http_code}' \
    "https://ghcr.io/v2/${image_path}/manifests/${tag}"
)

case "$status" in
  200)
    printf 'present\n'
    ;;
  404)
    printf 'absent\n'
    ;;
  *)
    printf 'unexpected GHCR manifest status for %s: %s\n' "$tag" "$status" >&2
    cat "$response_file" >&2
    exit 1
    ;;
esac
