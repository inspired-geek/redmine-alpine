#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"

cat >"$tmp/bin/curl" <<'FAKE'
#!/bin/sh
set -eu
printf 'curl' >>"$FAKE_CURL_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >>"$FAKE_CURL_LOG"
done
printf '\n' >>"$FAKE_CURL_LOG"

output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      output=$2
      shift 2
      ;;
    --header)
      case $2 in
        @*)
          header_file=${2#@}
          ruby -e '
            path = ARGV.fetch(0)
            abort "missing header file" unless File.file?(path)
            abort "unsafe header mode" unless (File.stat(path).mode & 0o777) == 0o600
          ' "$header_file"
          ;;
      esac
      shift 2
      ;;
    --write-out|--user|--data-urlencode|--connect-timeout|--max-time)
      shift 2
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done

case "$url" in
  https://ghcr.io/token)
    if [ -n "${FAKE_TOKEN_RESPONSE+x}" ]; then
      printf '%s' "$FAKE_TOKEN_RESPONSE"
    else
      printf '%s' '{"token":"fixture-token"}'
    fi
    ;;
  */manifests/*)
    [ -z "$output" ] || printf '%s' "${FAKE_BODY:-fixture}" >"$output"
    [ "${FAKE_CURL_FAILURE:-0}" = 0 ] || exit 7
    printf '%s' "${FAKE_STATUS:-200}"
    ;;
  *)
    exit 64
    ;;
esac
FAKE
chmod +x "$tmp/bin/curl"

run_probe() {
  env PATH="$tmp/bin:$PATH" GHCR_USER=test GHCR_TOKEN=test-token \
    FAKE_CURL_LOG="$tmp/curl.log" "$@"
}

: >"$tmp/curl.log"
actual=$(FAKE_STATUS=200 run_probe scripts/ghcr-manifest-status.sh ghcr.io/inspired-geek/redmine-alpine 7.0.0)
[ "$actual" = present ] || {
  printf 'expected present, got %s\n' "$actual" >&2
  exit 1
}
if grep -E 'test-token|fixture-token' "$tmp/curl.log" >/dev/null; then
  printf 'registry credential leaked into curl argv\n' >&2
  exit 1
fi
sed -n 's/.* @\([^ ]*\).*/\1/p' "$tmp/curl.log" |
while IFS= read -r header_file; do
  [ ! -e "$header_file" ] || {
    printf 'temporary curl header file remains: %s\n' "$header_file" >&2
    exit 1
  }
done

actual=$(FAKE_STATUS=404 run_probe scripts/ghcr-manifest-status.sh ghcr.io/inspired-geek/redmine-alpine 7.0.0)
[ "$actual" = absent ] || {
  printf 'expected absent, got %s\n' "$actual" >&2
  exit 1
}

if FAKE_STATUS=500 run_probe scripts/ghcr-manifest-status.sh \
  ghcr.io/inspired-geek/redmine-alpine 7.0.0 >"$tmp/output" 2>"$tmp/error"
then
  printf '500 response was accepted\n' >&2
  exit 1
fi
grep -F 'unexpected GHCR manifest status for 7.0.0: 500' "$tmp/error" >/dev/null

if FAKE_TOKEN_RESPONSE='{}' run_probe scripts/ghcr-manifest-status.sh \
  ghcr.io/inspired-geek/redmine-alpine 7.0.0 >"$tmp/output" 2>"$tmp/error"
then
  printf 'missing bearer token was accepted\n' >&2
  exit 1
fi

if FAKE_CURL_FAILURE=1 run_probe scripts/ghcr-manifest-status.sh \
  ghcr.io/inspired-geek/redmine-alpine 7.0.0 >"$tmp/output" 2>"$tmp/error"
then
  printf 'transport failure was accepted\n' >&2
  exit 1
fi

if FAKE_STATUS=200 FAKE_CURL_FAILURE=0 \
  FAKE_TOKEN_RESPONSE='{"token":"fixture-token"}' \
  run_probe scripts/ghcr-manifest-status.sh \
  'ghcr.io/inspired-geek/redmine-alpine:7.0.0' 7.0.0 \
  >"$tmp/output" 2>"$tmp/error"
then
  printf 'tagged image reference was accepted\n' >&2
  exit 1
fi
grep -F 'unsupported image reference' "$tmp/error" >/dev/null

if FAKE_STATUS=200 FAKE_CURL_FAILURE=0 \
  FAKE_TOKEN_RESPONSE='{"token":"fixture-token"}' \
  run_probe scripts/ghcr-manifest-status.sh \
  ghcr.io/inspired-geek/redmine-alpine '../7.0.0' \
  >"$tmp/output" 2>"$tmp/error"
then
  printf 'unsafe manifest tag was accepted\n' >&2
  exit 1
fi
grep -F 'unsupported manifest tag' "$tmp/error" >/dev/null

printf 'GHCR manifest status probe: PASS\n'
