#!/bin/sh
set -eu

usage() {
  printf 'usage: %s PROFILE IMAGE {sqlite|mariadb}\n' "$0" >&2
  exit 64
}

[ "$#" -eq 3 ] || usage
profile_id=$1
image=$2
database=$3

case $database in
  sqlite|mariadb) ;;
  *) usage ;;
esac

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
catalog_path=${IMAGE_CATALOG:-$root/build/images.json}
profile=$("$root/scripts/image-catalog" profile "$profile_id")
engine=${CONTAINER_ENGINE:-podman}
expected_arch=${EXPECTED_ARCH:-}

redmine_version=$(
  printf '%s' "$profile" |
    ruby -rjson -e 'profile = JSON.parse(STDIN.read); print profile.fetch("redmine_version")'
)
puma_version=$(
  printf '%s' "$profile" |
    ruby -rjson -e 'profile = JSON.parse(STDIN.read); print profile.fetch("puma_version")'
)
mariadb_connector_version=$(
  printf '%s' "$profile" |
    ruby -rjson -e 'profile = JSON.parse(STDIN.read); print profile.dig("mariadb_connector", "version")'
)
runtime_requires=$(
  printf '%s' "$profile" |
    ruby -rjson -e 'profile = JSON.parse(STDIN.read); print profile.dig("runtime_checks", "requires").join(" ")'
)
build_packages=$(
  printf '%s' "$profile" |
    ruby -rjson -e 'profile = JSON.parse(STDIN.read); print profile.dig("packages", "build").join(" ")'
)
mariadb_image=$(
  ruby -rjson -e '
    catalog = JSON.parse(File.read(ARGV.fetch(0)))
    print catalog.dig("tool_policy", "test_images", "mariadb")
  ' "$catalog_path"
)

command -v "$engine" >/dev/null 2>&1 || {
  printf 'ERROR: container engine not found: %s\n' "$engine" >&2
  exit 69
}
command -v curl >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: curl is required for HTTP smoke tests.' >&2
  exit 69
}

prefix="redmine-smoke-$$-$(date +%s)"
tmp=$(mktemp -d)
containers=
volumes=
networks=

cleanup() {
  for container in $containers; do
    "$engine" rm -f "$container" >/dev/null 2>&1 || true
  done
  for volume in $volumes; do
    "$engine" volume rm -f "$volume" >/dev/null 2>&1 || true
  done
  for network in $networks; do
    "$engine" network rm "$network" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'FAIL [%s/%s]: %s\n' "$profile_id" "$database" "$*" >&2
  exit 1
}

track_container() {
  containers="$1 $containers"
}

track_volume() {
  volumes="$1 $volumes"
}

track_network() {
  networks="$1 $networks"
}

container_url() {
  published=$("$engine" port "$1" 8080/tcp | tail -n 1)
  [ -n "$published" ] || fail "no published port for $1"
  printf 'http://127.0.0.1:%s' "${published##*:}"
}

wait_for_login() {
  container=$1
  url=$(container_url "$container")
  attempt=1

  while [ "$attempt" -le 180 ]; do
    if curl -fsS "$url/login" >/dev/null 2>&1; then
      printf '%s\n' "$url"
      return 0
    fi

    running=$("$engine" inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)
    if [ "$running" != true ]; then
      "$engine" logs "$container" >&2 || true
      fail "container $container exited before /login became ready"
    fi

    attempt=$((attempt + 1))
    sleep 2
  done

  "$engine" logs "$container" >&2 || true
  fail "timed out waiting for $url/login"
}

assert_core_stylesheet() {
  container=$1
  url=$2
  page=$tmp/$container-login.html
  stylesheet=$tmp/$container-core.css

  curl -fsS "$url/login" -o "$page" ||
    fail "could not fetch /login from $container"
  asset_path=$(
    ruby -rcgi -e '
      html = File.read(ARGV.fetch(0))
      match = html.match(/href="([^"]+\.css(?:\?[^"]*)?)"/i)
      abort "no stylesheet link on /login" unless match
      print CGI.unescapeHTML(match[1])
    ' "$page"
  ) || fail "could not find a core stylesheet on /login in $container"

  case $asset_path in
    http://*|https://*) asset_url=$asset_path ;;
    /*) asset_url=$url$asset_path ;;
    *) asset_url=$url/$asset_path ;;
  esac

  if ! asset_status=$(curl -fsS -o "$stylesheet" -w '%{http_code}' "$asset_url"); then
    fail "core stylesheet is not available from $container: $asset_url"
  fi
  [ "$asset_status" = 200 ] ||
    fail "core stylesheet returned HTTP $asset_status from $container"
  [ -s "$stylesheet" ] ||
    fail "core stylesheet returned an empty response from $container"
}

assert_running_application() {
  container=$1
  "$engine" exec \
    -e EXPECTED_REDMINE_VERSION="$redmine_version" \
    "$container" \
    bundle exec rails runner '
      actual = [
        Redmine::VERSION::MAJOR,
        Redmine::VERSION::MINOR,
        Redmine::VERSION::TINY
      ].join(".")
      expected = ENV.fetch("EXPECTED_REDMINE_VERSION")
      if expected == "trunk"
        abort "invalid trunk Redmine version: #{actual}" unless actual.match?(/\A\d+\.\d+\.\d+\z/)
      else
        abort "unexpected Redmine version: #{actual}" unless actual == expected
      end
      connection = ActiveRecord::Base.connection
      if connection.adapter_name.downcase.include?("mysql")
        current_database = connection.current_database
        unless current_database.is_a?(String) && !current_database.empty?
          abort "current_database must be a non-empty String: #{current_database.inspect}"
        end
      end
      plugin = Redmine::Plugin.find(:smoke_plugin)
      abort "smoke plugin was not registered" unless plugin
      abort "smoke plugin migration is missing" unless
        connection.table_exists?("smoke_plugin_records")
    ' >/dev/null || fail "Rails application/plugin contract failed in $container"

  "$engine" exec "$container" sh -c '
    test -s public/plugin_assets/smoke_plugin/stylesheets/smoke.css
    test -s public/themes/smoke_theme/stylesheets/application.css
  ' || fail "plugin assets or theme are missing in $container"
}

configured_user=$("$engine" image inspect --format '{{.Config.User}}' "$image")
[ "$configured_user" = 1001 ] ||
  fail "configured user is $configured_user, expected 1001"

configured_cmd=$("$engine" image inspect --format '{{json .Config.Cmd}}' "$image")
[ "$configured_cmd" = '["bundle","exec","puma","-C","config/puma.rb"]' ] ||
  fail "unexpected CMD: $configured_cmd"

configured_entrypoint=$(
  "$engine" image inspect --format '{{json .Config.Entrypoint}}' "$image"
)
[ "$configured_entrypoint" = '["/usr/local/bin/docker-entrypoint"]' ] ||
  fail "unexpected ENTRYPOINT: $configured_entrypoint"

"$engine" run --rm --entrypoint sh "$image" -c '
  test ! -e Gemfile.local
  bundle check
' || fail "runtime Gemfile is not canonical or disagrees with Gemfile.lock"

if [ -n "$expected_arch" ]; then
  actual_arch=$("$engine" image inspect --format '{{.Architecture}}' "$image")
  [ "$actual_arch" = "$expected_arch" ] ||
    fail "architecture is $actual_arch, expected $expected_arch"
fi

actual_version=$(
  "$engine" run --rm --entrypoint sh "$image" \
    -c 'printf "%s" "$REDMINE_VERSION"'
)
[ "$actual_version" = "$redmine_version" ] ||
  fail "REDMINE_VERSION is $actual_version, expected $redmine_version"

actual_puma=$(
  "$engine" run --rm --entrypoint bundle "$image" exec puma --version
)
printf '%s\n' "$actual_puma" | grep -F "$puma_version" >/dev/null ||
  fail "Puma $puma_version not reported: $actual_puma"

"$engine" run --rm --entrypoint bundle "$image" \
  exec ruby -e 'ARGV.each { |library| require library }' $runtime_requires ||
  fail "a required native runtime gem could not be loaded"

if [ -n "$mariadb_connector_version" ]; then
  "$engine" run --rm --entrypoint bundle \
    -e EXPECTED_MARIADB_CONNECTOR_VERSION="$mariadb_connector_version" \
    "$image" exec ruby -e '
      require "mysql2"
      actual = Mysql2::Client.info.fetch(:header_version)
      expected = ENV.fetch("EXPECTED_MARIADB_CONNECTOR_VERSION")
      abort "unexpected MariaDB Connector/C: #{actual}" unless actual == expected
    ' || fail "source-built MariaDB Connector/C version mismatch"
fi

case " $runtime_requires " in
  *' commonmarker '*)
    "$engine" run --rm --entrypoint bundle "$image" exec ruby -e '
      require "commonmarker"
      html = Commonmarker.to_html(
        "**smoke**",
        options: {extension: {}, render: {}, parse: {}},
        plugins: {}
      )
      abort "Commonmarker render failed" unless html.include?("<strong>smoke</strong>")
    ' || fail "Commonmarker native extension could not render Markdown"
    ;;
esac

"$engine" run --rm --entrypoint sh \
  -e BUILD_PACKAGES="$build_packages" \
  "$image" -c '
    test "$(id -u)" = 1001
    test "$(id -g)" = 0
    for package in $BUILD_PACKAGES .build-deps .verify-deps; do
      if apk info -e "$package" >/dev/null 2>&1; then
        printf "build package remains installed: %s\n" "$package" >&2
        exit 1
      fi
    done
  ' || fail "UID/GID or build-dependency cleanup check failed"

"$engine" run --rm --entrypoint sh "$image" -c '
  output=$(mktemp -d)
  convert -size 2x2 xc:red "$output/pixel.png"
  identify "$output/pixel.png" >/dev/null
  test -s "$output/pixel.png"
  printf "%s\n" \
    "%!PS" \
    "/Times-Roman findfont 12 scalefont setfont" \
    "72 720 moveto" \
    "(redmine-alpine smoke) show" \
    "showpage" >"$output/page.ps"
  gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite \
    -sOutputFile="$output/page.pdf" "$output/page.ps"
  test -s "$output/page.pdf"
  bundle exec ruby -e "
    begin
      require %q[mini_magick]
    rescue LoadError
      require %q[rmagick]
    end
  "
' || fail "ImageMagick, Ghostscript, or Ruby image adapter smoke failed"

assert_runtime_paths_writable() {
  user_spec=$1
  "$engine" run --rm \
    --user "$user_spec" \
    --entrypoint sh \
    "$image" -c '
      for path in \
        files log plugins public/plugin_assets public/themes sqlite tmp tmp/pdf tmp/pids
      do
        test -w "$path" || {
          printf "path is not writable: %s\n" "$path" >&2
          exit 1
        }
      done
      touch files/.smoke sqlite/.smoke tmp/.smoke public/plugin_assets/.smoke
    '
}

assert_runtime_paths_writable 1001:0 ||
  fail "runtime paths are not writable as UID 1001"
assert_runtime_paths_writable 12345:0 ||
  fail "runtime paths are not group-writable for an arbitrary UID in group 0"

missing_secret_log=$tmp/missing-secret.log
if "$engine" run --rm "$image" true >"$missing_secret_log" 2>&1; then
  fail "image accepted startup without a secret"
fi
grep -F 'SECRET_KEY_BASE or REDMINE_SECRET_KEY_BASE is required' \
  "$missing_secret_log" >/dev/null ||
  fail "missing-secret diagnostic was not emitted"

"$engine" run --rm \
  -e REDMINE_SECRET_KEY_BASE=legacy-smoke-secret \
  "$image" sh -c 'test "$SECRET_KEY_BASE" = legacy-smoke-secret' ||
  fail "legacy secret alias did not map to SECRET_KEY_BASE"

"$engine" run --rm \
  -e SECRET_KEY_BASE=preferred-smoke-secret \
  -e REDMINE_SECRET_KEY_BASE=ignored-legacy-secret \
  "$image" sh -c 'test "$SECRET_KEY_BASE" = preferred-smoke-secret' ||
  fail "preferred secret did not take precedence"

"$engine" run --rm \
  -e SECRET_KEY_BASE=command-smoke-secret \
  -e DB_ADAPTER=mysql2 \
  -e DB_HOST=unresolvable.invalid \
  -e REDMINE_DB_MIGRATE_RETRIES=1 \
  "$image" sh -c 'exit 0' ||
  fail "arbitrary command attempted implicit database migration"

files_volume=$prefix-files
plugins_volume=$prefix-plugins
plugin_assets_volume=$prefix-plugin-assets
themes_volume=$prefix-themes
sqlite_volume=$prefix-sqlite
for volume in \
  "$files_volume" "$plugins_volume" "$plugin_assets_volume" \
  "$themes_volume" "$sqlite_volume"
do
  "$engine" volume create "$volume" >/dev/null
  track_volume "$volume"
done

"$engine" run --rm --user 0 --entrypoint sh \
  -v "$plugins_volume:/plugins" \
  -v "$root/tests/fixtures/smoke_plugin:/fixture:ro" \
  "$image" -c '
    mkdir -p /plugins/smoke_plugin
    cp -R /fixture/. /plugins/smoke_plugin/
    chown -R 1001:0 /plugins
    chmod -R g=u /plugins
  '

"$engine" run --rm --user 0 --entrypoint sh \
  -v "$themes_volume:/themes" \
  -v "$root/tests/fixtures/smoke_theme:/fixture:ro" \
  "$image" -c '
    mkdir -p /themes/smoke_theme
    cp -R /fixture/. /themes/smoke_theme/
    chown -R 1001:0 /themes
    chmod -R g=u /themes
  '

network=
if [ "$database" = mariadb ]; then
  network=$prefix-network
  "$engine" network create "$network" >/dev/null
  track_network "$network"

  database_container=$prefix-database
  "$engine" run -d \
    --name "$database_container" \
    --network "$network" \
    --network-alias db \
    -e MARIADB_ROOT_PASSWORD=root-smoke-password \
    -e MARIADB_DATABASE=redmine \
    -e MARIADB_USER=redmine \
    -e MARIADB_PASSWORD=redmine-smoke-password \
    "$mariadb_image" >/dev/null
  track_container "$database_container"

  attempt=1
  while ! "$engine" exec "$database_container" \
    healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1
  do
    if [ "$attempt" -ge 90 ]; then
      "$engine" logs "$database_container" >&2 || true
      fail "MariaDB did not become healthy"
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
fi

start_redmine() {
  name=$1
  set -- "$engine" run -d \
    --name "$name" \
    -p 127.0.0.1::8080 \
    -e SECRET_KEY_BASE=redmine-smoke-secret \
    -v "$files_volume:/usr/src/redmine/files" \
    -v "$plugins_volume:/usr/src/redmine/plugins" \
    -v "$plugin_assets_volume:/usr/src/redmine/public/plugin_assets" \
    -v "$themes_volume:/usr/src/redmine/public/themes" \
    -v "$sqlite_volume:/usr/src/redmine/sqlite"

  if [ "$database" = mariadb ]; then
    set -- "$@" \
      --network "$network" \
      -e DB_ADAPTER=mysql2 \
      -e DB_HOST=db \
      -e DB_PORT=3306 \
      -e DB_USER=redmine \
      -e DB_PASSWORD=redmine-smoke-password \
      -e DB_NAME=redmine
  fi

  "$@" "$image" >/dev/null
  track_container "$name"
}

first_container=$prefix-first
start_redmine "$first_container"
first_url=$(wait_for_login "$first_container")
assert_core_stylesheet "$first_container" "$first_url"
assert_running_application "$first_container"
if ! "$engine" logs "$first_container" 2>&1 |
  grep -F 'Redmine database migrations completed.' >/dev/null
then
  fail "first boot did not complete core and plugin migrations"
fi

"$engine" exec "$first_container" sh -c '
  printf "%s\n" "redmine-alpine attachment smoke" >files/smoke-attachment.txt
' || fail "attachment volume is not writable"

"$engine" rm -f "$first_container" >/dev/null

"$engine" run --rm --entrypoint sh \
  -e SMOKE_DATABASE="$database" \
  -v "$files_volume:/usr/src/redmine/files" \
  -v "$plugin_assets_volume:/usr/src/redmine/public/plugin_assets" \
  -v "$themes_volume:/usr/src/redmine/public/themes" \
  -v "$sqlite_volume:/usr/src/redmine/sqlite" \
  "$image" -c '
    grep -F "redmine-alpine attachment smoke" files/smoke-attachment.txt >/dev/null
    test -s public/plugin_assets/smoke_plugin/stylesheets/smoke.css
    test -s public/themes/smoke_theme/stylesheets/application.css
    if [ "$SMOKE_DATABASE" = sqlite ]; then
      test -s sqlite/redmine.db
    fi
  ' || fail "attachment, plugin asset, theme, or SQLite data was not persisted"

second_container=$prefix-second
start_redmine "$second_container"
second_url=$(wait_for_login "$second_container")
assert_core_stylesheet "$second_container" "$second_url"
assert_running_application "$second_container"
"$engine" exec "$second_container" \
  grep -F 'redmine-alpine attachment smoke' files/smoke-attachment.txt >/dev/null ||
  fail "attachment disappeared after restart"

printf 'runtime smoke: PASS profile=%s image=%s database=%s\n' \
  "$profile_id" "$image" "$database"
