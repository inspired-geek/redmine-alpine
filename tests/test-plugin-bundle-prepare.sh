#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
prepare=$root/scripts/plugin-bundle-prepare
tmp=$(mktemp -d)

cleanup() {
  chmod -R u+w "$tmp" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$prepare" ] || fail "missing executable plugin bundle preparer"

app=$tmp/app
runtime_tmp=$tmp/runtime
bundle_config=$tmp/bundle-config
test_home=$tmp/home
mkdir -p \
  "$app/plugins/compatible" "$runtime_tmp" "$bundle_config" "$test_home"

run_stubbed_bundle_contract() {
  fake_bin=$tmp/fake-bin
  fake_log=$tmp/fake-bundle.log
  original_gem_home=$tmp/original-gems
  mkdir -p "$fake_bin" "$original_gem_home"
  cat >"$fake_bin/bundle" <<'SH'
#!/bin/sh
set -eu

[ "$#" -eq 2 ] && [ "$1" = install ] && [ "$2" = --local ] || {
  printf 'unexpected bundle arguments: %s\n' "$*" >&2
  exit 64
}
case $BUNDLE_GEMFILE in
  "$PLUGIN_BUNDLE_TEST_RUNTIME_TMP"/*/Gemfile) ;;
  *) printf 'runtime Gemfile escaped TMPDIR: %s\n' "$BUNDLE_GEMFILE" >&2; exit 65 ;;
esac
case $GEM_HOME in
  "$PLUGIN_BUNDLE_TEST_RUNTIME_TMP"/*/gems) ;;
  *) printf 'runtime GEM_HOME escaped TMPDIR: %s\n' "$GEM_HOME" >&2; exit 65 ;;
esac
case :$GEM_PATH: in
  *:"$GEM_HOME":*) ;;
  *) printf 'runtime GEM_HOME missing from GEM_PATH: %s\n' "$GEM_PATH" >&2; exit 65 ;;
esac
case :$GEM_PATH: in
  *:"$PLUGIN_BUNDLE_TEST_ORIGINAL_GEM_HOME":*) ;;
  *) printf 'original GEM_HOME missing from GEM_PATH: %s\n' "$GEM_PATH" >&2; exit 65 ;;
esac

plugin_gemfile=${REDMINE_APPLICATION_GEMFILE%/*}/plugins/compatible/Gemfile
if grep -F 'redmine_alpine_missing_plugin_fixture' "$plugin_gemfile" >/dev/null; then
  printf '%s\n' 'redmine_alpine_missing_plugin_fixture is not installed' >&2
  exit 7
fi
printf 'ARGS=%s GEMFILE=%s GEM_HOME=%s GEM_PATH=%s\n' \
  "$*" "$BUNDLE_GEMFILE" "$GEM_HOME" "$GEM_PATH" \
  >>"$PLUGIN_BUNDLE_TEST_LOG"
printf '%s\n' '# plugin_fixture resolved by stubbed Bundler' \
  >>"${BUNDLE_GEMFILE}.lock"
SH
  chmod 0755 "$fake_bin/bundle"

  printf '%s\n' \
    'source "https://rubygems.org"' \
    'Dir[File.join(__dir__, "plugins", "*", "{Gemfile,PluginGemfile}")].sort.each do |plugin_gemfile|' \
    '  eval_gemfile plugin_gemfile' \
    'end' >"$app/Gemfile"
  printf '%s\n' 'stub application lock' >"$app/Gemfile.lock"
  printf '%s\n' 'gem "plugin_fixture", "= 1.0.0"' \
    >"$app/plugins/compatible/Gemfile"
  cp "$app/Gemfile.lock" "$tmp/original.lock"
  chmod -R a-w "$app" "$bundle_config"

  runtime_gemfile=$(
    env PATH="$fake_bin:$PATH" TMPDIR="$runtime_tmp" \
      BUNDLE_APP_CONFIG="$bundle_config" GEM_HOME="$original_gem_home" \
      GEM_PATH="$original_gem_home" HOME="$test_home" \
      PLUGIN_BUNDLE_TEST_LOG="$fake_log" \
      PLUGIN_BUNDLE_TEST_RUNTIME_TMP="$runtime_tmp" \
      PLUGIN_BUNDLE_TEST_ORIGINAL_GEM_HOME="$original_gem_home" \
      "$prepare" "$app"
  )
  grep -F 'ARGS=install --local' "$fake_log" >/dev/null ||
    fail "preparer did not invoke bundle install --local"
  grep -F '# plugin_fixture resolved by stubbed Bundler' \
    "${runtime_gemfile}.lock" >/dev/null ||
    fail "preparer did not preserve the writable runtime lockfile"
  cmp -s "$app/Gemfile.lock" "$tmp/original.lock" ||
    fail "stubbed preparation changed the application lockfile"

  chmod -R u+w "$app"
  printf '%s\n' 'gem "redmine_alpine_missing_plugin_fixture", "= 1.0.0"' \
    >"$app/plugins/compatible/Gemfile"
  chmod -R a-w "$app"
  set +e
  env PATH="$fake_bin:$PATH" TMPDIR="$runtime_tmp" \
    BUNDLE_APP_CONFIG="$bundle_config" GEM_HOME="$original_gem_home" \
    GEM_PATH="$original_gem_home" HOME="$test_home" \
    PLUGIN_BUNDLE_TEST_LOG="$fake_log" \
    PLUGIN_BUNDLE_TEST_RUNTIME_TMP="$runtime_tmp" \
    PLUGIN_BUNDLE_TEST_ORIGINAL_GEM_HOME="$original_gem_home" \
    "$prepare" "$app" >"$tmp/missing.out" 2>"$tmp/missing.err"
  status=$?
  set -e
  [ "$status" -eq 7 ] || fail "missing plugin dependency status changed: $status"
  grep -F 'plugin dependencies are not installed' "$tmp/missing.err" >/dev/null ||
    fail "missing plugin dependency diagnostic changed"
  cmp -s "$app/Gemfile.lock" "$tmp/original.lock" ||
    fail "failed stubbed preparation changed the application lockfile"

  printf '%s\n' 'plugin runtime bundle preparer contract: PASS'
}

if [ "${PLUGIN_BUNDLE_TEST_FORCE_STUB:-false}" = true ] ||
   ! command -v bundle >/dev/null 2>&1 ||
   ! ruby -rbundler -e 'exit 0' >/dev/null 2>&1
then
  run_stubbed_bundle_contract
  exit 0
fi

test_gem_home=$(ruby -rrubygems -e 'print Gem.dir')
test_gem_path=$(ruby -rrubygems -e 'print Gem.path.join(File::PATH_SEPARATOR)')

versions=$(ruby -rbundler -rrubygems -e '
  %w[json rake].each do |name|
    specification = Gem::Specification.find_all_by_name(name).first
    abort "#{name} fixture gem is missing" unless specification
    puts "#{name}=#{specification.version}"
  end
  puts "bundler=#{Bundler::VERSION}"
')
json_version=$(printf '%s\n' "$versions" | sed -n 's/^json=//p')
rake_version=$(printf '%s\n' "$versions" | sed -n 's/^rake=//p')
bundler_version=$(printf '%s\n' "$versions" | sed -n 's/^bundler=//p')

printf '%s\n' \
  'source "https://rubygems.org"' \
  "gem \"json\", \"= $json_version\"" \
  'Dir[File.join(__dir__, "plugins", "*", "{Gemfile,PluginGemfile}")].sort.each do |plugin_gemfile|' \
  '  eval_gemfile plugin_gemfile' \
  'end' >"$app/Gemfile"
printf '%s\n' \
  'GEM' \
  '  remote: https://rubygems.org/' \
  '  specs:' \
  "    json ($json_version)" \
  '' \
  'PLATFORMS' \
  '  ruby' \
  '' \
  'DEPENDENCIES' \
  "  json (= $json_version)" \
  '' \
  'BUNDLED WITH' \
  "   $bundler_version" >"$app/Gemfile.lock"
printf '%s\n' "gem \"rake\", \"= $rake_version\"" \
  >"$app/plugins/compatible/Gemfile"
cp "$app/Gemfile.lock" "$tmp/original.lock"
chmod -R a-w "$app"
chmod -R a-w "$bundle_config"

runtime_gemfile=$(
  env TMPDIR="$runtime_tmp" BUNDLE_APP_CONFIG="$bundle_config" \
    GEM_HOME="$test_gem_home" GEM_PATH="$test_gem_path" HOME="$test_home" \
    "$prepare" "$app"
)
case $runtime_gemfile in
  "$runtime_tmp"/*/Gemfile) ;;
  *) fail "runtime Gemfile escaped TMPDIR: $runtime_gemfile" ;;
esac
cmp -s "$app/Gemfile.lock" "$tmp/original.lock" ||
  fail "read-only application lockfile changed"
grep -F "rake (= $rake_version)" "${runtime_gemfile}.lock" >/dev/null ||
  fail "runtime lockfile did not record the compatible plugin dependency"
env \
  REDMINE_APPLICATION_GEMFILE="$app/Gemfile" \
  BUNDLE_APP_CONFIG="$bundle_config" \
  BUNDLE_GEMFILE="$runtime_gemfile" \
  GEM_HOME="$test_gem_home" GEM_PATH="$test_gem_path" \
  HOME="$test_home" \
  bundle check >/dev/null ||
  fail "generated runtime bundle does not pass bundle check"
env \
  REDMINE_APPLICATION_GEMFILE="$app/Gemfile" \
  BUNDLE_APP_CONFIG="$bundle_config" \
  BUNDLE_GEMFILE="$runtime_gemfile" \
  GEM_HOME="$test_gem_home" GEM_PATH="$test_gem_path" \
  HOME="$test_home" \
  bundle exec ruby -e 'require "rake"' ||
  fail "generated runtime bundle cannot load the plugin dependency"

chmod -R u+w "$app"
printf '%s\n' 'gem "redmine_alpine_missing_plugin_fixture", "= 1.0.0"' \
  >"$app/plugins/compatible/Gemfile"
chmod -R a-w "$app"
set +e
env TMPDIR="$runtime_tmp" BUNDLE_APP_CONFIG="$bundle_config" \
  GEM_HOME="$test_gem_home" GEM_PATH="$test_gem_path" HOME="$test_home" \
  "$prepare" "$app" >"$tmp/missing.out" 2>"$tmp/missing.err"
status=$?
set -e
[ "$status" -ne 0 ] || fail "missing plugin dependency unexpectedly passed"
grep -F 'redmine_alpine_missing_plugin_fixture' "$tmp/missing.err" >/dev/null ||
  fail "missing plugin dependency was not reported"
grep -F 'plugin dependencies are not installed' "$tmp/missing.err" >/dev/null ||
  fail "missing plugin dependency diagnostic changed"
cmp -s "$app/Gemfile.lock" "$tmp/original.lock" ||
  fail "failed preparation changed the application lockfile"

printf '%s\n' 'plugin runtime bundle preparer: PASS'
