#!/bin/sh
set -eu

command_name=$1
shift

if [ "$command_name" = image ] && [ "${1:-}" = inspect ]; then
  case "$*" in
    *'{{.Config.User}}'*) printf '%s\n' 1001 ;;
    *'{{json .Config.Cmd}}'*)
      printf '%s\n' '["bundle","exec","puma","-C","config/puma.rb"]'
      ;;
    *'{{json .Config.Entrypoint}}'*)
      printf '%s\n' '["/usr/local/bin/docker-entrypoint"]'
      ;;
    *'{{.Architecture}}'*) printf '%s\n' amd64 ;;
    *) exit 64 ;;
  esac
  exit 0
fi

if [ "$command_name" = run ]; then
  for argument in "$@"; do
    case $argument in
      *'printf "%s" "$REDMINE_VERSION"'*)
        printf '%s' "$FAKE_REDMINE_VERSION"
        exit 0
        ;;
      *'convert -size 2x2'*)
        printf '%s\n' "$argument" >"$FAKE_CAPTURE"
        tool_dir=$(mktemp -d)
        trap 'rm -rf "$tool_dir"' EXIT HUP INT TERM
        for tool in convert identify gs; do
          printf '%s\n' '#!/bin/sh' 'exit 0' >"$tool_dir/$tool"
          chmod 0755 "$tool_dir/$tool"
        done
        printf '%s\n' '#!/bin/sh' 'exit 42' >"$tool_dir/convert"
        printf '%s\n' '#!/bin/sh' 'exit 0' >"$tool_dir/bundle"
        chmod 0755 "$tool_dir/convert" "$tool_dir/bundle"
        set +e
        PATH="$tool_dir:$PATH" sh -c "$argument"
        status=$?
        set -e
        printf '%s\n' "$status" >"$FAKE_CAPTURE_STATUS"
        exit "$status"
        ;;
    esac
  done

  case "$*" in
    *'exec puma --version'*)
      printf 'Puma %s\n' "$FAKE_PUMA_VERSION"
      ;;
  esac
  exit 0
fi

exit 0
