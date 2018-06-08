#!/bin/bash
set -e

case "$1" in
	unicorn_rails|rails|rake)
		if [ ! -f './config/database.yml' ]; then
			if [ "$MYSQL_PORT_3306_TCP" ]; then
				: "${REDMINE_DB_MYSQL:=mysql}"
			elif [ "$POSTGRES_PORT_5432_TCP" ]; then
				: "${REDMINE_DB_POSTGRES:=postgres}"
			fi
			
			if [ "$REDMINE_DB_MYSQL" ]; then
				adapter='mysql2'
				host="$REDMINE_DB_MYSQL"
				: "${REDMINE_DB_PORT:=3306}"
				: "${REDMINE_DB_USERNAME:=${MYSQL_ENV_MYSQL_USER:-root}}"
				: "${REDMINE_DB_PASSWORD:=${MYSQL_ENV_MYSQL_PASSWORD:-${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}}"
				: "${REDMINE_DB_DATABASE:=${MYSQL_ENV_MYSQL_DATABASE:-${MYSQL_ENV_MYSQL_USER:-redmine}}}"
				: "${REDMINE_DB_ENCODING:=}"
			else
				echo >&2
				echo >&2 'warning: missing REDMINE_DB_MYSQL  environment variables'
				echo >&2
				echo >&2 '*** Using sqlite3 as fallback. ***'
				echo >&2
				
				adapter='sqlite3'
				host='localhost'
				: "${REDMINE_DB_PORT:=}"
				: "${REDMINE_DB_USERNAME:=redmine}"
				: "${REDMINE_DB_PASSWORD:=}"
				: "${REDMINE_DB_DATABASE:=sqlite/redmine.db}"
				: "${REDMINE_DB_ENCODING:=utf8}"
				
				mkdir -p "$(dirname "$REDMINE_DB_DATABASE")"
			fi
			
			REDMINE_DB_ADAPTER="$adapter"
			REDMINE_DB_HOST="$host"
			echo "$RAILS_ENV:" > config/database.yml
			for var in \
				adapter \
				host \
				port \
				username \
				password \
				database \
				encoding \
			; do
				env="REDMINE_DB_${var^^}"
				val="${!env}"
				[ -n "$val" ] || continue
				echo "  $var: \"$val\"" >> config/database.yml
			done
		fi
		
		# ensure the right database adapter is active in the Gemfile.lock
		bundle install --without development test
		
		if [ ! -s config/secrets.yml ]; then
			if [ "$REDMINE_SECRET_KEY_BASE" ]; then
				cat > 'config/secrets.yml' <<-YML
					$RAILS_ENV:
					  secret_key_base: "$REDMINE_SECRET_KEY_BASE"
				YML
			elif [ ! -f /usr/src/redmine/config/initializers/secret_token.rb ]; then
				rake generate_secret_token
			fi
		fi
		if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
			rake db:migrate
		fi
		
		# remove PID file to enable restarting the container
		rm -f /usr/src/redmine/tmp/pids/server.pid
		
		;;
esac

exec "$@"
