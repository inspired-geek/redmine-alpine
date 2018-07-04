#!/bin/sh
set -e

if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
  rake db:migrate
  rake redmine:plugins:migrate
fi

exec "$@"
