#!/bin/bash
set -e

if [ "$1" = 'postgres' ]; then
	mkdir -p "$PGDATA"
	chmod 700 "$PGDATA"
	chown -R postgres "$PGDATA"

	chmod g+s /run/postgresql
	chown -R postgres /run/postgresql

	# look specifically for PG_VERSION, as it is expected in the DB dir
	if [ ! -s "$PGDATA/PG_VERSION" ]; then
		gosu postgres initdb

		# check password first so we can output the warning before postgres
		# messes it up
		if [ "$POSTGRES_PASSWORD" ]; then
			pass="PASSWORD '$POSTGRES_PASSWORD'"
			authMethod=md5
		else
			# The - option suppresses leading tabs but *not* spaces. :)
			cat >&2 <<-'EOWARN'
				****************************************************
				WARNING: No password has been set for the database.
				         This will allow anyone with access to the
				         Postgres port to access your database. In
				         Docker's default configuration, this is
				         effectively any other container on the same
				         system.

				         Use "-e POSTGRES_PASSWORD=password" to set
				         it in "docker run".
				****************************************************
			EOWARN

			pass=
			authMethod=trust
		fi

		cp /tmp/baseconfig/pg_hba.conf "$PGDATA/pg_hba.conf"

		# internal start of server in order to allow set-up using psql-client		
		# does not listen on TCP/IP and waits until start finishes
		gosu postgres pg_ctl -D "$PGDATA" \
			-o "-c listen_addresses=''" \
			-w start

		: ${POSTGRES_USER:=postgres}
		: ${POSTGRES_DB:=$POSTGRES_USER}
		export POSTGRES_USER POSTGRES_DB

		if [ "$POSTGRES_DB" != 'postgres' ]; then
			psql --username postgres <<-EOSQL
				CREATE DATABASE "$POSTGRES_DB" ;
			EOSQL
			echo
		fi

		if [ "$POSTGRES_USER" = 'postgres' ]; then
			op='ALTER'
		else
			op='CREATE'
		fi

		psql --username postgres <<-EOSQL
			$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
			CREATE USER rep REPLICATION LOGIN CONNECTION LIMIT 1 ENCRYPTED PASSWORD '$POSTGRES_REPLICATION_PASSWORD'';
		EOSQL
		echo

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)  echo "$0: running $f"; . "$f" ;;
				*.sql) 
					echo "$0: running $f"; 
					psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" < "$f"
					echo 
					;;
				*)     echo "$0: ignoring $f" ;;
			esac
			echo
		done

		gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop
		
		cp /tmp/baseconfig/postgresql.conf "$PGDATA/postgresql.conf"

		echo
		echo 'PostgreSQL init process complete; ready for start up.'
		echo
	fi

	exec gosu postgres "$@"
fi

if [ $POSTGRES_STARTUP_SLAVE = 'true' ]; then
	if [ $POSTGRES_STARTUP_SLAVE_SYNC = 'true' ]; then
		rm -r "$PGDATA/*" # This is scary
		pg_basebackup -h $POSTGRES_MASTER_IP -p $POSTGRES_MASTER_PORT -P -U rep -D $PGDATA --xlog-method=stream
		
		# Restore config files
		cp /tmp/baseconfig/pg_hba.conf "$PGDATA/pg_hba.conf"
		cp /tmp/baseconfig/postgresql.conf "$PGDATA/postgresql.conf"
	fi
	cp /tmp/baseconfig/recovery.conf "$PGDATA/recovery.conf"
	echo "primary_conninfo = 'host=$POSTGRES_MASTER_IP port=$POSTGRES_MASTER_PORT user=rep password=$POSTGRES_REPLICATION_PASSWORD'" >> "$PGDATA/recovery.conf"
	
fi

exec "$@"
