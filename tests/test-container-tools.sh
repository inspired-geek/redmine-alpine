#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
wrapper=$root/scripts/container-tools
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
log=$tmp/engine.log
cat >"$tmp/bin/fake-engine" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$CONTAINER_TOOLS_TEST_LOG"
if [ "$1 $2" = "volume inspect" ]; then
  [ -f "$CONTAINER_TOOLS_TEST_VOLUME" ]
  exit
fi
if [ "$1 $2" = "volume create" ]; then
  : >"$CONTAINER_TOOLS_TEST_VOLUME"
  exit
fi
case $1 in
  run)
    printf '%s\n' fixture-container
    ;;
  logs)
    [ "$2" = --follow ]
    [ "$3" = fixture-container ]
    ;;
  wait)
    [ "$2" = fixture-container ]
    printf '%s\n' "${CONTAINER_TOOLS_TEST_STATUS:-0}"
    ;;
  rm)
    [ "$2" = -f ]
    [ "$3" = fixture-container ]
    ;;
esac
SH
chmod 0755 "$tmp/bin/fake-engine"

if [ ! -x "$wrapper" ]; then
  printf '%s\n' "FAIL: missing executable scripts/container-tools" >&2
  exit 1
fi

env PATH="$tmp/bin:$PATH" CONTAINER_TOOLS_ENGINE=fake-engine \
  CONTAINER_TOOLS_PLATFORM=linux/amd64 \
  CONTAINER_TOOLS_STORAGE=redmine-test-storage \
  CONTAINER_TOOLS_TEST_VOLUME="$tmp/volume" \
  CONTAINER_TOOLS_TEST_LOG="$log" \
  "$wrapper" sh -c 'printf ignored'

env PATH="$tmp/bin:$PATH" CONTAINER_TOOLS_ENGINE=fake-engine \
  CONTAINER_TOOLS_PLATFORM=linux/amd64 \
  CONTAINER_TOOLS_STORAGE=redmine-test-storage \
  CONTAINER_TOOLS_TEST_VOLUME="$tmp/volume" \
  CONTAINER_TOOLS_TEST_LOG="$log" \
  "$wrapper" true

registry_tool=$(
  ruby -rjson -e \
    'print JSON.parse(File.read(ARGV.fetch(0))).dig("tool_policy", "registry_tool")' \
    "$root/build/images.json"
)
env PATH="$tmp/bin:$PATH" CONTAINER_TOOLS_ENGINE=fake-engine \
  CONTAINER_TOOLS_PLATFORM=linux/amd64 \
  CONTAINER_TOOLS_STORAGE=redmine-test-storage \
  CONTAINER_TOOLS_IMAGE="$registry_tool" \
  CONTAINER_TOOLS_TEST_VOLUME="$tmp/volume" \
  CONTAINER_TOOLS_TEST_LOG="$log" \
  "$wrapper" true
grep -F -- "$registry_tool" "$log" >/dev/null ||
  fail "explicit pinned tool image override was ignored"

normal_repo=$tmp/normal-repo
normal_bin=$tmp/normal-bin
mkdir -p \
  "$normal_repo/.git" \
  "$normal_repo/build" \
  "$normal_repo/scripts" \
  "$normal_repo/subdir" \
  "$normal_bin"
cp "$root/build/images.json" "$normal_repo/build/images.json"
cp "$wrapper" "$normal_repo/scripts/container-tools"
normal_repo_physical=$(cd "$normal_repo" && pwd -P)
cat >"$normal_bin/git" <<'SH'
#!/bin/sh
set -eu
[ "$1" = -C ]
[ "$3 $4" = "rev-parse --git-common-dir" ]
printf '%s\n' .git
SH
chmod 0755 "$normal_bin/git"
(
  cd "$normal_repo/subdir"
  env PATH="$normal_bin:$tmp/bin:$PATH" CONTAINER_TOOLS_ENGINE=fake-engine \
    CONTAINER_TOOLS_PLATFORM=linux/amd64 \
    CONTAINER_TOOLS_STORAGE=redmine-test-storage \
    CONTAINER_TOOLS_TEST_VOLUME="$tmp/volume" \
    CONTAINER_TOOLS_TEST_LOG="$log" \
    "$normal_repo/scripts/container-tools" true
)

grep -F "volume create redmine-test-storage" "$log" >/dev/null ||
  fail "persistent storage volume was not created"
[ "$(grep -F -c "volume create redmine-test-storage" "$log")" -eq 1 ] ||
  fail "existing persistent storage volume was recreated"
run=$(grep '^run ' "$log")
for expected in \
  "--detach" \
  "--privileged" \
  "--platform linux/amd64" \
  "--entrypoint /usr/bin/env" \
  "--tmpfs /home/podman/.local/share/containers:rw" \
  "STORAGE_DRIVER=vfs" \
  "redmine-test-storage:/var/lib/containers" \
  "host.containers.internal:host-gateway" \
  "quay.io/podman/stable@sha256:766815d247ce0edfd8774770371d293728b0b500a219f35de98b408100f5d412" \
  "sh -c printf ignored"
do
  printf '%s\n' "$run" | grep -F -- "$expected" >/dev/null ||
    fail "outer run argv missing: $expected"
done

grep -F "logs --follow fixture-container" "$log" >/dev/null ||
  fail "detached container logs were not followed"
grep -F "wait fixture-container" "$log" >/dev/null ||
  fail "detached container exit status was not awaited"
grep -F "rm -f fixture-container" "$log" >/dev/null ||
  fail "detached container was not removed"
grep -F -- "--volume $normal_repo_physical:$normal_repo_physical" "$log" >/dev/null ||
  fail "normal checkout root was not mounted from a subdirectory"

if printf '%s\n' "$run" | grep -F -- "--rm" >/dev/null; then
  fail "detached container must not use --rm"
fi

set +e
env PATH="$tmp/bin:$PATH" CONTAINER_TOOLS_ENGINE=fake-engine \
  CONTAINER_TOOLS_PLATFORM=linux/amd64 \
  CONTAINER_TOOLS_STORAGE=redmine-test-storage \
  CONTAINER_TOOLS_TEST_VOLUME="$tmp/volume" \
  CONTAINER_TOOLS_TEST_LOG="$log" CONTAINER_TOOLS_TEST_STATUS=42 \
  "$wrapper" true >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 42 ] || fail "outer engine failure was not propagated"

set +e
"$wrapper" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 64 ] || fail "missing command did not exit 64"

printf '%s\n' "container tools wrapper: PASS"
