#!/bin/sh
set -e


if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
  rake db:migrate
fi

# remove PID file to enable restarting the container
rm -f /usr/src/redmine/tmp/pids/server.pid

exec "$@"
