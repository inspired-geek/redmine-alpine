#!/bin/sh
set -eu

is_default_puma_command() {
  [ "$#" -eq 5 ] &&
    [ "$1" = "bundle" ] &&
    [ "$2" = "exec" ] &&
    [ "$3" = "puma" ] &&
    [ "$4" = "-C" ] &&
    [ "$5" = "config/puma.rb" ]
}

child_pid=

forward_signal() {
  signal=$1
  status=$2
  trap - HUP INT TERM
  if [ -n "$child_pid" ]; then
    kill -"$signal" "$child_pid" >/dev/null 2>&1 || true
    wait "$child_pid" >/dev/null 2>&1 || true
  fi
  exit "$status"
}

run_child() {
  "$@" &
  child_pid=$!
  if wait "$child_pid"; then
    child_status=0
  else
    child_status=$?
  fi
  child_pid=
  return "$child_status"
}

trap 'forward_signal HUP 129' HUP
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

rails_env=${RAILS_ENV:-production}
if [ "$rails_env" != production ]; then
  printf 'ERROR: RAILS_ENV must be production, got: %s\n' "$rails_env" >&2
  exit 64
fi
RAILS_ENV=$rails_env
export RAILS_ENV

secret_key_base=${SECRET_KEY_BASE:-${REDMINE_SECRET_KEY_BASE:-}}
if [ -z "$secret_key_base" ]; then
  printf '%s\n' \
    'ERROR: SECRET_KEY_BASE or REDMINE_SECRET_KEY_BASE is required.' >&2
  exit 64
fi
SECRET_KEY_BASE=$secret_key_base
export SECRET_KEY_BASE

if is_default_puma_command "$@"; then
  application_root=$(pwd -P)
  original_gem_path=${GEM_PATH:-${GEM_HOME:-}}
  REDMINE_APPLICATION_GEMFILE=$application_root/Gemfile
  export REDMINE_APPLICATION_GEMFILE
  if runtime_gemfile=$(plugin-bundle-prepare "$application_root"); then
    runtime_bundle_root=${runtime_gemfile%/Gemfile}
    BUNDLE_APP_CONFIG=$runtime_bundle_root/config
    BUNDLE_GEMFILE=$runtime_gemfile
    GEM_HOME=$runtime_bundle_root/gems
    GEM_PATH=$GEM_HOME
    if [ -n "$original_gem_path" ]; then
      GEM_PATH=$GEM_PATH:$original_gem_path
    fi
    export BUNDLE_APP_CONFIG BUNDLE_GEMFILE GEM_HOME GEM_PATH
  else
    printf '%s\n' \
      'ERROR: Plugin dependencies are not available in the runtime image.' \
      'Add plugin dependencies to the repository plugins/ directory and rebuild' \
      'the image with scripts/image-build.' >&2
    exit 78
  fi
fi

if is_default_puma_command "$@" && [ -z "${REDMINE_NO_DB_MIGRATE:-}" ]; then
  retries=${REDMINE_DB_MIGRATE_RETRIES:-30}
  delay=${REDMINE_DB_MIGRATE_DELAY:-2}

  case $retries in
    ''|*[!0-9]*|0)
      printf '%s\n' \
        'ERROR: REDMINE_DB_MIGRATE_RETRIES must be a positive integer.' >&2
      exit 64
      ;;
  esac
  case $delay in
    ''|*[!0-9]*)
      printf '%s\n' \
        'ERROR: REDMINE_DB_MIGRATE_DELAY must be a non-negative integer.' >&2
      exit 64
      ;;
  esac

  attempt=1
  while :; do
    printf 'Running Redmine database migrations (attempt %s/%s)...\n' \
      "$attempt" "$retries"
    if run_child env SCHEMA=/tmp/redmine-schema.rb \
         bundle exec rake db:migrate &&
       run_child env SCHEMA=/tmp/redmine-schema.rb \
         bundle exec rake redmine:plugins:migrate; then
      printf '%s\n' 'Redmine database migrations completed.'
      break
    fi

    if [ "$attempt" -ge "$retries" ]; then
      printf 'ERROR: Redmine database migrations failed after %s attempts.\n' \
        "$retries" >&2
      exit 1
    fi

    attempt=$((attempt + 1))
    run_child sleep "$delay"
  done
fi

exec "$@"
