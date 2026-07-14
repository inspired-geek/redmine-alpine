#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
builder=$root/scripts/image-build
containerfile=$root/Containerfile
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
log=$tmp/podman.log
cat >"$tmp/bin/podman" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$IMAGE_BUILD_TEST_LOG"
case $1 in
  build)
    [ "${IMAGE_BUILD_TEST_FAIL:-0}" != 1 ] || exit 37
    ;;
  push)
    shift
    [ "$1" = "--format" ] && [ "$2" = "oci" ] || exit 64
    shift 2
    [ "$1" = "--compression-format" ] && [ "$2" = "gzip" ] || exit 64
    shift 2
    [ "$1" = "--compression-level" ] && [ "$2" = "9" ] || exit 64
    shift 2
    [ "$1" = "--force-compression" ] || exit 64
    shift
    [ "$1" = "--digestfile" ] || exit 64
    digestfile=$2
    shift 2
    image=$1
    destination=$2
    [ -n "$image" ] || exit 64
    path=${destination#oci-archive:}
    path=${path%:*}
    mkdir -p "$(dirname "$path")"
    printf 'fixture OCI archive\n' >"$path"
    printf 'sha256:%s\n' cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc >"$digestfile"
    ;;
  *)
    printf 'unexpected podman command: %s\n' "$1" >&2
    exit 64
    ;;
esac
SH
chmod 0755 "$tmp/bin/podman"

if [ ! -x "$builder" ]; then
  printf '%s\n' "FAIL: missing executable scripts/image-build" >&2
  exit 1
fi

output=$tmp/output
env PATH="$tmp/bin:$PATH" IMAGE_BUILD_DIRECT_PODMAN=1 \
  IMAGE_BUILD_TEST_LOG="$log" \
  "$builder" 5.1 \
  --platform linux/amd64 \
  --tag localhost/redmine-alpine:5.1-test \
  --output-dir "$output" \
  --revision 0123456789abcdef0123456789abcdef01234567 \
  --no-cache

[ -s "$output/rootfs.oci.tar" ] || fail "rootfs OCI archive missing"
[ -s "$output/build.json" ] || fail "build metadata missing"

bud=$(grep '^build ' "$log")
push=$(grep '^push ' "$log")
printf '%s\n' "$push" | grep -F \
  'push --format oci --compression-format gzip --compression-level 9 --force-compression' \
  >/dev/null || fail "gzip level 9 archive policy was not applied"
for expected in \
  "--file $containerfile" \
  "--platform linux/amd64" \
  "--tag localhost/redmine-alpine:5.1-test" \
  "--no-cache" \
  "--source-date-epoch 1781551502" \
  "--rewrite-timestamp" \
  "SOURCE_BASE=docker.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b" \
  "BUILDER_BASE=docker.io/library/ruby:3.2-alpine3.23@sha256:d206c25708a44df6a7ce22213ee5da9fc0a9f7b31ce884429ba758db48abdc62" \
  "RUNTIME_BASE=docker.io/library/ruby:3.2-alpine3.23@sha256:d206c25708a44df6a7ce22213ee5da9fc0a9f7b31ce884429ba758db48abdc62" \
  "SOURCE_SHA256=1a3d1039e474e787cebf223da148bf28373e4bca262197a53cfa6139640ebe5f" \
  "EXPECTED_REDMINE_VERSION=5.1.13" \
  "EXPECTED_RUBY_VERSION=3.2.11" \
  "BUNDLER_VERSION=2.4.22" \
  "BUNDLER_GEM_SHA256=747ba50b0e67df25cbd3b48f95831a77a4d53a581d55f063972fcb146d142c5f" \
  "FORCE_RUBY_PLATFORM=true" \
  "PUMA_VERSION=8.0.2" \
  "RUNTIME_COMMANDS=ruby bundle gs convert" \
  "RUNTIME_REQUIRES=mysql2 sqlite3 puma" \
  "RUNTIME_PATHS=/usr/src/redmine"
do
  printf '%s\n' "$bud" | grep -F -- "$expected" >/dev/null ||
    fail "podman argv missing: $expected"
done

printf '%s\n' "$bud" | grep -F 'MARIADB_CONNECTOR_VERSION=' >/dev/null ||
  fail "empty optional MariaDB Connector/C version was not passed"
printf '%s\n' "$bud" | grep -F 'MARIADB_CONNECTOR_SOURCE_URL=' >/dev/null ||
  fail "empty optional MariaDB Connector/C URL was not passed"
printf '%s\n' "$bud" | grep -F 'MARIADB_CONNECTOR_SOURCE_SHA256=' >/dev/null ||
  fail "empty optional MariaDB Connector/C checksum was not passed"

connector_log=$tmp/connector-podman.log
env PATH="$tmp/bin:$PATH" IMAGE_BUILD_DIRECT_PODMAN=1 \
  IMAGE_BUILD_TEST_LOG="$connector_log" \
  "$builder" 4.2 \
  --platform linux/amd64 \
  --tag localhost/redmine-alpine:4.2-test \
  --output-dir "$tmp/connector-output" \
  --revision 0123456789abcdef0123456789abcdef01234567
connector_build=$(grep '^build ' "$connector_log")
for expected in \
  'MARIADB_CONNECTOR_VERSION=3.3.18' \
  'MARIADB_CONNECTOR_SOURCE_URL=https://codeload.github.com/mariadb-corporation/mariadb-connector-c/tar.gz/9e2b0370de0076461ebae71a06acfb7a9364395b' \
  'MARIADB_CONNECTOR_SOURCE_SHA256=c9bb36de53cab97dbec2f3fc47219f9ddb8d7068e532c6abd9b18f8e5d3850fe'
do
  printf '%s\n' "$connector_build" | grep -F -- "$expected" >/dev/null ||
    fail "4.2 build argv missing: $expected"
done

modern_log=$tmp/modern-podman.log
env PATH="$tmp/bin:$PATH" IMAGE_BUILD_DIRECT_PODMAN=1 \
  IMAGE_BUILD_TEST_LOG="$modern_log" \
  "$builder" 6.0 \
  --platform linux/amd64 \
  --tag localhost/redmine-alpine:6.0-test \
  --output-dir "$tmp/modern-output" \
  --revision 0123456789abcdef0123456789abcdef01234567
modern_build=$(grep '^build ' "$modern_log")
printf '%s\n' "$modern_build" | grep -F 'FORCE_RUBY_PLATFORM=false' >/dev/null ||
  fail "native musl profile did not disable forced Ruby-platform gems"
modern_gemfile=$(
  printf '%s\n' "$modern_build" |
    ruby -rbase64 -e '
      encoded = STDIN.read[/GEMFILE_LOCAL_BASE64=([A-Za-z0-9+\/=]+)/, 1]
      abort "missing Gemfile.local payload" unless encoded
      print Base64.strict_decode64(encoded)
    '
)
printf '%s\n' "$modern_gemfile" | grep -Fx \
  'gem "sqlite3", "~>1.7.0", force_ruby_platform: true' >/dev/null ||
  fail "Redmine 6.0 sqlite3 must use the source gem on musl"
printf '%s\n' "$bud" | grep -F "GEMFILE_LOCAL_BASE64=" >/dev/null ||
  fail "Gemfile.local was not Base64 encoded"
if printf '%s\n' "$bud" | grep -F 'eval' >/dev/null ||
   printf '%s\n' "$bud" | grep -F '`' >/dev/null ||
   printf '%s\n' "$bud" | grep -F '$(' >/dev/null; then
  fail "executable shell fragment reached Buildah argv"
fi
for unused in \
  PROFILE_ID SOURCE_DATE_EPOCH SOURCE_KIND RUBY_INSTALL_MODE IMAGE_PROFILE_JSON_BASE64
do
  if printf '%s\n' "$bud" | grep -F -- "$unused=" >/dev/null; then
    fail "unused build argument reached Buildah argv: $unused"
  fi
done

ruby -rjson -e '
  value = JSON.parse(File.read(ARGV[0]))
  abort "profile" unless value.fetch("profile") == "5.1"
  abort "platform" unless value.fetch("platform") == "linux/amd64"
  abort "tag" unless value.fetch("tag") == "localhost/redmine-alpine:5.1-test"
  abort "revision" unless value.fetch("revision") ==
    "0123456789abcdef0123456789abcdef01234567"
  abort "digest" unless value.fetch("image_digest") ==
    "sha256:" + ("c" * 64)
  abort "compression" unless value.fetch("compression") ==
    {"format" => "gzip", "level" => 9}
' "$output/build.json"

failed=$tmp/failed
set +e
env PATH="$tmp/bin:$PATH" IMAGE_BUILD_DIRECT_PODMAN=1 \
  IMAGE_BUILD_TEST_LOG="$log" IMAGE_BUILD_TEST_FAIL=1 \
  "$builder" 5.1 \
  --platform linux/amd64 \
  --tag localhost/redmine-alpine:failed \
  --output-dir "$failed" \
  --revision 0123456789abcdef0123456789abcdef01234567 \
  --no-cache >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 37 ] || fail "Buildah failure was not propagated"
[ ! -e "$failed/build.json" ] || fail "failed build emitted success metadata"

[ -f "$containerfile" ] || fail "root Containerfile missing"
[ "$(find "$root" -name Containerfile -maxdepth 2 | wc -l | tr -d ' ')" -ge 1 ] ||
  fail "Containerfile search failed"
grep -F 'FROM ${SOURCE_BASE} AS source' "$containerfile" >/dev/null ||
  fail "source stage missing"
grep -F 'FROM ${BUILDER_BASE} AS builder' "$containerfile" >/dev/null ||
  fail "builder stage missing"
grep -F 'FROM ${RUNTIME_BASE} AS runtime' "$containerfile" >/dev/null ||
  fail "runtime stage missing"
grep -F 'PUMA_DISABLE_SSL=1' "$containerfile" >/dev/null ||
  fail "Puma native TLS must be disabled for the shared HTTP runtime contract"
grep -F 'https://rubygems.org/downloads/bundler-${BUNDLER_VERSION}.gem' \
  "$containerfile" >/dev/null ||
  fail "Bundler gem must use its direct immutable download URL"
grep -F 'gem install --local --no-document /tmp/bundler.gem' \
  "$containerfile" >/dev/null ||
  fail "Bundler gem must be installed from the verified local artifact"
grep -F "bundle_jobs=\$(awk '/^processor/ { count += 1 } END { print count }' /proc/cpuinfo)" \
  "$containerfile" >/dev/null ||
  fail "Bundler concurrency must be derived from available CPUs"
grep -F '[ "$bundle_jobs" -le 10 ] || bundle_jobs=10' \
  "$containerfile" >/dev/null ||
  fail "Bundler concurrency must be capped at ten workers"
grep -F 'export MAKEFLAGS="-j$bundle_jobs"' "$containerfile" >/dev/null ||
  fail "native extension make jobs must use available CPUs"
grep -F 'bundle install --jobs "$bundle_jobs"' "$containerfile" >/dev/null ||
  fail "Bundler must use the computed concurrency"
grep -F 'cmake -S /tmp/mariadb-connector-source' "$containerfile" >/dev/null ||
  fail "optional MariaDB Connector/C source build is missing"
grep -F 'BUNDLE_BUILD__MYSQL2=--with-mysql-config=/opt/mariadb-connector/bin/mariadb_config' \
  "$containerfile" >/dev/null ||
  fail "mysql2 is not compiled against the source-built connector"
grep -F 'mariadb_config --cc_version' "$containerfile" >/dev/null ||
  fail "Connector/C release version is not checked with the correct mariadb_config field"
grep -F 'COPY --from=builder /opt/mariadb-connector-runtime/' \
  "$containerfile" >/dev/null ||
  fail "source-built MariaDB Connector/C runtime is not copied"
grep -F 'LD_LIBRARY_PATH=/opt/mariadb-connector/lib/mariadb' \
  "$containerfile" >/dev/null ||
  fail "source-built MariaDB Connector/C is not preferred at runtime"
grep -F 'COPY scripts/gemfile-canonicalize /usr/local/bin/gemfile-canonicalize' \
  "$containerfile" >/dev/null ||
  fail "tested Gemfile canonicalizer was not copied after bundle installation"
grep -F '/usr/local/bin/gemfile-canonicalize Gemfile Gemfile.local' \
  "$containerfile" >/dev/null ||
  fail "temporary compatibility overrides were not canonicalized"
grep -F 'bundle check' "$containerfile" >/dev/null ||
  fail "the canonical runtime Gemfile must be checked against Gemfile.lock"
grep -F 'RUBYOPT=-rlogger' "$containerfile" >/dev/null ||
  fail "runtime Ruby must preload stdlib logger for Rails 6.1 compatibility"
grep -F 'true) export BUNDLE_FORCE_RUBY_PLATFORM=1 ;;' "$containerfile" >/dev/null ||
  fail "source-gem compatibility mode is missing"
grep -F 'false) unset BUNDLE_FORCE_RUBY_PLATFORM ;;' "$containerfile" >/dev/null ||
  fail "native musl gem mode is missing"
if grep -F 'ENV BUNDLE_FORCE_RUBY_PLATFORM=1' "$containerfile" >/dev/null; then
  fail "Ruby-platform forcing must be profile data, not a global environment"
fi
builder_stage=$(
  awk '
    /^FROM .* AS builder$/ { in_builder = 1 }
    /^FROM .* AS runtime$/ { in_builder = 0 }
    in_builder { print }
  ' "$containerfile"
)
if printf '%s\n' "$builder_stage" | grep -F 'FEATURE_PACKAGES' >/dev/null; then
  fail "runtime-only feature packages must not be installed in the builder"
fi
grep -F 'COPY scripts/apk-add /usr/local/bin/apk-add' "$containerfile" >/dev/null ||
  fail "retrying APK installer was not copied into the source stage"
[ "$(grep -F -c '/usr/local/bin/apk-add' "$containerfile")" -ge 7 ] ||
  fail "all APK transactions must use the retry helper"
if grep -F 'apk add --no-cache' "$containerfile" >/dev/null; then
  fail "direct APK transactions bypass the retry helper"
fi
grep -F 'imagemagick6_convert=$(command -v convert-6)' "$containerfile" >/dev/null ||
  fail "ImageMagick 6 must expose the common convert command"
grep -F 'imagemagick6_identify=$(command -v identify-6)' "$containerfile" >/dev/null ||
  fail "ImageMagick 6 must expose the common identify command"
grep -F 'rm -f "$GEM_HOME"/gems/rbpdf-font-*/lib/fonts/ttf2ufm/ttf2ufm' \
  "$containerfile" >/dev/null ||
  fail "non-musl rbpdf-font helper was not removed before dependency scanning"
grep -F 'COPY scripts/runtime-cleanup /usr/local/bin/runtime-cleanup' \
  "$containerfile" >/dev/null ||
  fail "shared runtime cleanup was not copied into the builder"
grep -F '/usr/local/bin/runtime-cleanup "$GEM_HOME" /usr/src/redmine' \
  "$containerfile" >/dev/null ||
  fail "shared runtime cleanup was not executed"
grep -F 'COPY scripts/runtime-verify /usr/local/bin/runtime-verify' \
  "$containerfile" >/dev/null ||
  fail "shared runtime verifier was not copied"
grep -F '/usr/local/bin/apk-add --virtual .verify-deps pax-utils' \
  "$containerfile" >/dev/null ||
  fail "ELF verifier dependency was not installed ephemerally"
grep -F '/usr/local/bin/runtime-verify elf' "$containerfile" >/dev/null ||
  fail "ELF closure was not verified"
grep -F '/usr/local/bin/runtime-verify contract' "$containerfile" >/dev/null ||
  fail "runtime content contract was not verified"
if grep -E 'case .*REDMINE|if .*REDMINE_VERSION|REDMINE_VERSION.*(3\\.4|4\\.0|5\\.1)' \
  "$containerfile" >/dev/null; then
  fail "Containerfile branches on Redmine series"
fi

printf '%s\n' "image build driver: PASS"
