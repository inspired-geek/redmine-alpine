#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
cd "$root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing $1"
}

assert_absent() {
  [ ! -e "$1" ] || fail "obsolete path remains: $1"
}

assert_contains() {
  file=$1
  expected=$2
  grep -F -- "$expected" "$file" >/dev/null ||
    fail "$file does not contain: $expected"
}

assert_not_contains() {
  file=$1
  rejected=$2
  if grep -Fi -- "$rejected" "$file" >/dev/null; then
    fail "$file unexpectedly contains: $rejected"
  fi
}

for file in \
  Containerfile \
  build/images.json \
  config/database.yml \
  config/production.append.rb \
  config/puma.rb \
  config/secrets.yml \
  docker-entrypoint.sh \
  scripts/image-build \
  tests/smoke-image.sh
do
  assert_file "$file"
done

for path in \
  3.4/Containerfile \
  4.0/Containerfile \
  4.1/Containerfile \
  4.2/Containerfile \
  5.0/Containerfile \
  5.1/Containerfile \
  6.0/Containerfile \
  6.1/Containerfile \
  7.0/Containerfile \
  trunk/Containerfile \
  config/database-puma.yml \
  config/environments/production.rb \
  config/initializers/redmine_alpine_mysql2_compat.rb \
  config/unicorn.conf.rb \
  docker-entrypoint-puma.sh \
  tests/smoke-modern-image.sh \
  tests/validate-modern-images.sh
do
  assert_absent "$path"
done

if [ -d docs/superpowers/plans ] &&
   find docs/superpowers/plans -type f -print -quit | grep -q .; then
  fail 'implementation plans must not be committed'
fi

containerfile_count=$(find . -maxdepth 2 -name Containerfile -type f | wc -l | tr -d ' ')
[ "$containerfile_count" -eq 1 ] ||
  fail "expected one Containerfile, found $containerfile_count"

assert_contains .gitignore '.superpowers/'
assert_contains .gitignore 'artifacts/'
for obsolete_context in 3.4 4.0 4.1 4.2 5.0 5.1 6.0 6.1 7.0 trunk docs; do
  assert_not_contains .containerignore "$obsolete_context"
done

sh -n docker-entrypoint.sh
ruby -c config/puma.rb | grep -F 'Syntax OK' >/dev/null

assert_contains Containerfile 'FROM ${SOURCE_BASE} AS source'
assert_contains Containerfile 'FROM ${BUILDER_BASE} AS builder'
assert_contains Containerfile 'FROM ${RUNTIME_BASE} AS runtime'
assert_contains Containerfile 'COPY config/production.append.rb /tmp/redmine-alpine-production.rb'
assert_contains Containerfile 'cat /tmp/redmine-alpine-production.rb >> config/environments/production.rb'
assert_not_contains Containerfile 'COPY --chown=1001:0 config/environments/production.rb'
assert_contains Containerfile 'COPY --chown=1001:0 config/database.yml config/secrets.yml config/puma.rb'
assert_contains Containerfile 'cmake -S /tmp/mariadb-connector-source'
assert_contains Containerfile 'COPY --from=builder /opt/mariadb-connector-runtime/'
assert_contains Containerfile 'LD_LIBRARY_PATH=/opt/mariadb-connector/lib/mariadb'
assert_not_contains Containerfile redmine_alpine_mysql2_compat
assert_contains Containerfile 'COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint'
assert_contains Containerfile 'USER 1001'
assert_contains Containerfile 'ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]'
assert_contains Containerfile 'CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]'
assert_not_contains Containerfile unicorn

assert_contains config/database.yml 'RAILS_MAX_THREADS'
assert_contains config/database.yml '/usr/src/redmine/sqlite/redmine.db'
assert_contains config/database.yml 'utf8mb4'
assert_contains config/database.yml 'transaction_isolation: "READ-COMMITTED"'
assert_contains config/database.yml 'DB_PORT'
assert_not_contains config/database.yml postgresql

catalog_result=$(scripts/image-catalog validate)
[ "$catalog_result" = 'catalog: PASS profiles=10 managed_tags=14' ] ||
  fail "catalog summary changed: $catalog_result"

ruby -rjson <<'RUBY'
catalog = JSON.parse(File.read("build/images.json"))
profiles = catalog.fetch("profiles")
expected_ids = %w[3.4 4.0 4.1 4.2 5.0 trunk 5.1 6.0 6.1 7.0]
expected_tags = %w[
  3.4 4.0 4.1 4.2 5.0 trunk
  5.1 5.1.13 6.0 6.0.10 6.1 6.1.3 7.0 7.0.0
]

raise "profile matrix changed" unless profiles.map { |profile| profile.fetch("id") } == expected_ids
tags = profiles.flat_map do |profile|
  profile.fetch("tags").values_at("moving", "immutable").flatten
end
raise "managed tags changed" unless tags == expected_tags

profiles.each do |profile|
  id = profile.fetch("id")
  requires = profile.dig("runtime_checks", "requires")
  raise "#{id} does not require Puma" unless requires.include?("puma")
  raise "#{id} metadata does not identify Puma" unless
    profile.dig("oci", "description").include?("Puma")
  raise "#{id} has no moving tag" if profile.dig("tags", "moving").empty?
  raise "#{id} is optional" unless profile.fetch("platforms") == ["linux/amd64"]
end
RUBY

workflow=.github/workflows/build.yml
assert_file "$workflow"
assert_contains "$workflow" 'tests/validate-images.sh'
assert_not_contains "$workflow" modern
assert_not_contains "$workflow" continue-on-error
assert_contains "$workflow" 'scripts/image-catalog matrix'
assert_contains "$workflow" 'scripts/resolve-trunk'
assert_contains "$workflow" 'scripts/image-build'
assert_contains "$workflow" 'scripts/image-compress'
assert_contains "$workflow" 'scripts/image-metrics'
assert_contains "$workflow" 'scripts/image-publish'
assert_contains "$workflow" 'tests/smoke-image.sh "$PROFILE" "$LOCAL_IMAGE" sqlite'
assert_contains "$workflow" 'tests/smoke-image.sh "$PROFILE" "$LOCAL_IMAGE" mariadb'
assert_contains "$workflow" 'actions/checkout@v6'
assert_contains "$workflow" 'actions/upload-artifact@v7'
assert_contains "$workflow" 'actions/download-artifact@v8'
assert_contains "$workflow" 'rootfs.index.oci.tar'
assert_contains "$workflow" 'zstd_chunked_manifest_digest'
assert_contains "$workflow" 'enable_partial_images = \"true\"'
assert_not_contains "$workflow" redhat-actions/buildah-build
assert_not_contains "$workflow" redhat-actions/push-to-registry

ruby -rjson -ryaml <<'RUBY'
workflow = YAML.safe_load(File.read(".github/workflows/build.yml"))
raise "workflow permissions" unless workflow.fetch("permissions") == {"contents" => "read"}
raise "publication may be cancelled" unless
  workflow.dig("concurrency", "cancel-in-progress") == false
raise "master publication is not queued" unless
  workflow.dig("concurrency", "queue") == "max"

jobs = workflow.fetch("jobs")
prepare = jobs.fetch("prepare")
build = jobs.fetch("build")
publish = jobs.fetch("publish")
raise "prepare matrix output" unless
  prepare.dig("outputs", "matrix") == "${{ steps.matrix.outputs.value }}"
raise "build dependencies" unless Array(build.fetch("needs")) == ["prepare"]
raise "build matrix" unless
  build.dig("strategy", "matrix") == "${{ fromJSON(needs.prepare.outputs.matrix) }}"
raise "build may fail fast" unless build.dig("strategy", "fail-fast") == false
raise "build received package-write permission" if build.fetch("permissions", {}).key?("packages")

build_script = build.fetch("steps").map { |step| step.fetch("run", "") }.join("\n")
raise "candidate is not built no-cache" unless build_script.include?("--no-cache")
raise "SQLite smoke missing" unless
  build_script.include?('tests/smoke-image.sh "$PROFILE" "$LOCAL_IMAGE" sqlite')
raise "MariaDB smoke missing" unless
  build_script.include?('tests/smoke-image.sh "$PROFILE" "$LOCAL_IMAGE" mariadb')

raise "publish dependencies" unless Array(publish.fetch("needs")) == %w[prepare build]
raise "publish condition" unless
  publish.fetch("if") == "github.event_name == 'push' && github.ref == 'refs/heads/master'"
raise "publish permission" unless publish.dig("permissions", "packages") == "write"
raise "publish matrix" unless
  publish.dig("strategy", "matrix") == "${{ fromJSON(needs.prepare.outputs.matrix) }}"
raise "publish may fail fast" unless publish.dig("strategy", "fail-fast") == false

publish_script = publish.fetch("steps").map { |step| step.fetch("run", "") }.join("\n")
raise "publisher missing" unless publish_script.include?("scripts/image-publish")
raise "publish rebuilds images" if publish_script.include?("scripts/image-build")
raise "gzip registry pull missing" unless publish_script.include?("docker pull")
raise "zstd registry pull missing" unless publish_script.include?("zstd_chunked_manifest_digest")
RUBY

assert_not_contains README.md modern
for token in \
  'all fourteen managed tags' \
  '3.4.13' \
  '4.0.9' \
  '4.1.7' \
  '4.2.11' \
  '5.0.6' \
  '5.1.13' \
  '6.0.10' \
  '6.1.3' \
  '7.0.0' \
  'Puma' \
  'previous Unicorn-based images' \
  'Alpine 3.24' \
  'scripts/image-build' \
  'tests/smoke-image.sh' \
  'gzip' \
  'zstd:chunked' \
  'org.opencontainers.image.source' \
  'org.opencontainers.image.description' \
  'org.opencontainers.image.licenses' \
  'SECRET_KEY_BASE' \
  'REDMINE_SECRET_KEY_BASE' \
  'DB_PORT' \
  'RAILS_MAX_THREADS' \
  'WEB_CONCURRENCY' \
  'REDMINE_NO_DB_MIGRATE' \
  'REDMINE_DB_MIGRATE_RETRIES' \
  '/usr/src/redmine/sqlite'
do
  assert_contains README.md "$token"
done

assert_contains docker-compose.yml 'ghcr.io/inspired-geek/redmine-alpine:7.0'
assert_contains docker-compose.yml 'mariadb:11.8.8'
assert_contains docker-compose.yml 'condition: service_healthy'
assert_contains docker-compose.yml 'SECRET_KEY_BASE: ${SECRET_KEY_BASE:?'
assert_contains docker-compose.yml 'DB_PASSWORD: ${DB_PASSWORD:?'
assert_not_contains docker-compose.yml mariadb:latest

printf '%s\n' 'unified image repository contract: PASS'
