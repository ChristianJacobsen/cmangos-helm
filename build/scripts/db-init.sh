#!/usr/bin/env bash
# The chart runs this on every install and upgrade, so every step must be safe
# to repeat. Nothing here may drop characters, realmd or logs data. The world
# database holds only content, so a reinstall replaces it.
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

DB_HOST="${DB_HOST:?DB_HOST is required}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:?DB_USER is required}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD is required}"
DB_ADMIN_USER="${DB_ADMIN_USER:-}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"
EXPANSION="${CMANGOS_EXPANSION:?CMANGOS_EXPANSION is required}"
DB_WORLD="${DB_WORLD:-${EXPANSION}mangos}"
DB_CHARACTERS="${DB_CHARACTERS:-${EXPANSION}characters}"
DB_REALMD="${DB_REALMD:-${EXPANSION}realmd}"
DB_LOGS="${DB_LOGS:-${EXPANSION}logs}"
WORLD_REINSTALL="${WORLD_REINSTALL:-onChange}"
WORLD_LOCALES="${WORLD_LOCALES:-NO}"
WORLD_DEV_UPDATES="${WORLD_DEV_UPDATES:-NO}"
WORLD_EXTRA_SQL_DIR="${WORLD_EXTRA_SQL_DIR:-}"
REALM_ID="${REALM_ID:-1}"
REALM_NAME="${REALM_NAME:-}"
REALM_ADDRESS="${REALM_ADDRESS:-}"
REALM_PORT="${REALM_PORT:-}"
REMOVE_DEFAULT_ACCOUNTS="${REMOVE_DEFAULT_ACCOUNTS:-1}"
MYSQL_WAIT_ATTEMPTS="${MYSQL_WAIT_ATTEMPTS:-120}"
MYSQL_WAIT_INTERVAL_SECONDS="${MYSQL_WAIT_INTERVAL_SECONDS:-5}"
MYSQL_CONNECT_TIMEOUT_SECONDS="${MYSQL_CONNECT_TIMEOUT_SECONDS:-5}"

CORE_PATH=/opt/cmangos/core
DB_SRC=/opt/cmangos/db
BOTS_SQL="$CORE_PATH/src/modules/PlayerBots/sql"
FINGERPRINT="$(cat /opt/cmangos/world-content.sha256)"
# InstallFullDB.sh calls clear(1).
export TERM="${TERM:-dumb}"

case "$WORLD_REINSTALL" in onChange|never) ;; *) die "WORLD_REINSTALL must be onChange or never" ;; esac
[[ "$REALM_ID" =~ ^[0-9]+$ ]] || die "REALM_ID must be a number"
[[ -z "$REALM_PORT" || "$REALM_PORT" =~ ^[0-9]+$ ]] || die "REALM_PORT must be a number"

sql_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\'/\\\'}"; }

sql_as() {
  local user="$1" pass="$2" db="$3"; shift 3
  local args=(-h "$DB_HOST" -P "$DB_PORT" -u "$user" --batch --skip-column-names)
  [ -n "$db" ] && args+=(-D "$db")
  MYSQL_PWD="$pass" mysql "${args[@]}" "$@"
}
app() { local db="$1"; shift; sql_as "$DB_USER" "$DB_PASSWORD" "$db" "$@"; }
admin() { sql_as "$DB_ADMIN_USER" "$DB_ADMIN_PASSWORD" "" "$@"; }

table_count() {
  app "" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$(sql_escape "$1")';"
}
table_exists() {
  [ "$(app "" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$(sql_escape "$1")' AND table_name = '$(sql_escape "$2")';")" != 0 ]
}
load_sql() {
  log "applying $(basename "$2") to $1"
  app "$1" < "$2"
}
installer() {
  log "InstallFullDB.sh $*"
  bash ./InstallFullDB.sh "$@" || die "InstallFullDB.sh $* failed"
}

probe_user="$DB_USER"; probe_pass="$DB_PASSWORD"
if [ -n "$DB_ADMIN_USER" ]; then probe_user="$DB_ADMIN_USER"; probe_pass="$DB_ADMIN_PASSWORD"; fi
for attempt in $(seq 1 "$MYSQL_WAIT_ATTEMPTS"); do
  if sql_as "$probe_user" "$probe_pass" "" --connect-timeout="$MYSQL_CONNECT_TIMEOUT_SECONDS" -e 'SELECT 1' >/dev/null 2>&1; then break; fi
  [ "$attempt" = "$MYSQL_WAIT_ATTEMPTS" ] && die "cannot connect to MySQL at $DB_HOST:$DB_PORT as $probe_user"
  log "waiting for MySQL at $DB_HOST:$DB_PORT"
  sleep "$MYSQL_WAIT_INTERVAL_SECONDS"
done

if [ -n "$DB_ADMIN_USER" ]; then
  for db in "$DB_WORLD" "$DB_CHARACTERS" "$DB_REALMD" "$DB_LOGS"; do
    admin -e "CREATE DATABASE IF NOT EXISTS \`$db\` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;"
  done
  if [ "$DB_USER" != "$DB_ADMIN_USER" ]; then
    log "setting up database user $DB_USER"
    pw="$(sql_escape "$DB_PASSWORD")"
    admin <<SQL
CREATE USER IF NOT EXISTS '$(sql_escape "$DB_USER")'@'%' IDENTIFIED BY '$pw';
ALTER USER '$(sql_escape "$DB_USER")'@'%' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON \`$DB_WORLD\`.* TO '$(sql_escape "$DB_USER")'@'%';
GRANT ALL PRIVILEGES ON \`$DB_CHARACTERS\`.* TO '$(sql_escape "$DB_USER")'@'%';
GRANT ALL PRIVILEGES ON \`$DB_REALMD\`.* TO '$(sql_escape "$DB_USER")'@'%';
GRANT ALL PRIVILEGES ON \`$DB_LOGS\`.* TO '$(sql_escape "$DB_USER")'@'%';
SQL
  fi
fi

fresh_realmd=0
if [ "$(table_count "$DB_REALMD")" = 0 ]; then
  load_sql "$DB_REALMD" "$CORE_PATH/sql/base/realmd.sql"
  fresh_realmd=1
fi
if [ "$(table_count "$DB_CHARACTERS")" = 0 ]; then
  load_sql "$DB_CHARACTERS" "$CORE_PATH/sql/base/characters.sql"
fi
if [ "$(table_count "$DB_LOGS")" = 0 ]; then
  load_sql "$DB_LOGS" "$CORE_PATH/sql/base/logs.sql"
fi

# InstallFullDB.sh writes next to itself (its config, the unzipped dump), so run a copy.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$DB_SRC/." "$WORK/"
cd "$WORK"
{
  printf 'MYSQL_HOST=%q\n' "$DB_HOST"
  printf 'MYSQL_PORT=%q\n' "$DB_PORT"
  printf 'MYSQL_USERNAME=%q\n' "$DB_USER"
  printf 'MYSQL_PASSWORD=%q\n' "$DB_PASSWORD"
  printf 'MYSQL_USERIP=%q\n' "%"
  printf 'WORLD_DB_NAME=%q\n' "$DB_WORLD"
  printf 'REALM_DB_NAME=%q\n' "$DB_REALMD"
  printf 'CHAR_DB_NAME=%q\n' "$DB_CHARACTERS"
  printf 'LOGS_DB_NAME=%q\n' "$DB_LOGS"
  printf 'MYSQL_PATH=%q\n' "$(command -v mysql)"
  printf 'MYSQL_DUMP_PATH=%q\n' "$(command -v mysqldump)"
  printf 'CORE_PATH=%q\n' "$CORE_PATH"
  printf 'LOCALES=%q\n' "$WORLD_LOCALES"
  printf 'FORCE_WAIT=%q\n' "NO"
  printf 'DEV_UPDATES=%q\n' "$WORLD_DEV_UPDATES"
  printf 'AHBOT=%q\n' "YES"
  printf 'PLAYERBOTS_DB=%q\n' "YES"
} > InstallFullDB.config

install_world=0
if [ "$(table_count "$DB_WORLD")" = 0 ]; then
  log "world database $DB_WORLD is empty"
  load_sql "$DB_WORLD" "$CORE_PATH/sql/base/mangos.sql"
  install_world=1
else
  installed=""
  if table_exists "$DB_WORLD" cmangos_helm_state; then
    installed="$(app "$DB_WORLD" -e "SELECT v FROM cmangos_helm_state WHERE k = 'world_content';")"
  fi
  if [ "$installed" = "$FINGERPRINT" ]; then
    log "world content is current (${FINGERPRINT:0:12})"
  elif [ "$WORLD_REINSTALL" = onChange ]; then
    log "world content changed (${installed:0:12} -> ${FINGERPRINT:0:12}), reinstalling $DB_WORLD"
    install_world=1
  else
    log "world content changed (${installed:0:12} -> ${FINGERPRINT:0:12}), but WORLD_REINSTALL=never"
  fi
fi

if [ "$install_world" = 1 ]; then
  installer -World
  log "applying playerbots world SQL"
  for f in "$BOTS_SQL"/world/*.sql "$BOTS_SQL/world/$EXPANSION"/*.sql; do
    [ -e "$f" ] && load_sql "$DB_WORLD" "$f"
  done
  if [ -n "$WORLD_EXTRA_SQL_DIR" ] && [ -d "$WORLD_EXTRA_SQL_DIR" ]; then
    for f in "$WORLD_EXTRA_SQL_DIR"/*.sql; do
      [ -e "$f" ] && load_sql "$DB_WORLD" "$f"
    done
  fi
  app "$DB_WORLD" <<SQL
CREATE TABLE IF NOT EXISTS cmangos_helm_state (
  k VARCHAR(64) NOT NULL PRIMARY KEY,
  v VARCHAR(255) NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) COMMENT = 'Written by the cmangos Helm chart db-init Job';
REPLACE INTO cmangos_helm_state (k, v) VALUES ('world_content', '$FINGERPRINT');
SQL
fi

installer -UpdateCore

# These files start with DROP TABLE, so apply a file only when its first
# table does not exist yet. That keeps the bot data across upgrades.
for f in "$BOTS_SQL"/characters/*.sql; do
  [ -e "$f" ] || continue
  first_table="$(grep -o -m1 -i -E 'CREATE TABLE (IF NOT EXISTS )?`?[A-Za-z0-9_]+' "$f" | sed -E 's/.*[ `]//')"
  if [ -z "$first_table" ] || ! table_exists "$DB_CHARACTERS" "$first_table"; then
    load_sql "$DB_CHARACTERS" "$f"
  fi
done

if ! app "$DB_REALMD" -e "SELECT id FROM realmlist WHERE id = $REALM_ID;" | grep -q .; then
  log "creating realmlist row $REALM_ID"
  app "$DB_REALMD" -e "INSERT INTO realmlist (id, name, address, port) VALUES ($REALM_ID, '$(sql_escape "${REALM_NAME:-CMaNGOS}")', '$(sql_escape "${REALM_ADDRESS:-127.0.0.1}")', ${REALM_PORT:-8085});"
fi
set_parts=()
[ -n "$REALM_NAME" ] && set_parts+=("name = '$(sql_escape "$REALM_NAME")'")
[ -n "$REALM_ADDRESS" ] && set_parts+=("address = '$(sql_escape "$REALM_ADDRESS")'")
[ -n "$REALM_PORT" ] && set_parts+=("port = $REALM_PORT")
if [ "${#set_parts[@]}" -gt 0 ]; then
  sql="UPDATE realmlist SET $(IFS=,; echo "${set_parts[*]}") WHERE id = $REALM_ID;"
  log "$sql"
  app "$DB_REALMD" -e "$sql"
fi

# realmd.sql ships ADMINISTRATOR, GAMEMASTER, MODERATOR and PLAYER with the
# user name as the password. Remove them from a fresh database only, so that
# the Job never deletes accounts that somebody created later.
if [ "$fresh_realmd" = 1 ] && [ "$REMOVE_DEFAULT_ACCOUNTS" = 1 ]; then
  log "removing the default accounts"
  app "$DB_REALMD" <<'SQL'
DELETE FROM account WHERE username IN ('ADMINISTRATOR', 'GAMEMASTER', 'MODERATOR', 'PLAYER');
SQL
fi

cmangos-srp6 --self-test
accounts_sql="$(cmangos-srp6)"
if [ -n "$accounts_sql" ]; then
  app "$DB_REALMD" <<<"$accounts_sql"
fi

log "database initialization complete"
