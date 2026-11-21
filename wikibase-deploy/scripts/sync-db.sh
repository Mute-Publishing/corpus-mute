#!/bin/sh
# Runs INSIDE the mysql (MariaDB) container, locally and on the server, so both
# environments use exactly the same dump/restore logic. Credentials come from the
# container's own MYSQL_* environment (never passed on a command line).
#
#   sync-db.sh dump      FILE   content-only dump (see excluded tables below)
#   sync-db.sh dump-full FILE   complete dump of every table (safety backup / rollback)
#   sync-db.sh restore   FILE   load a dump made by this script, then clear caches
#
# Content-only means environment-specific tables are NOT copied, so each side keeps
# its own accounts, passwords, OAuth consumers (QuickStatements) and caches:
#   user*, oauth_*, oathauth_*, cu_*, echo_*, loginnotify_*, objectcache, l10n_cache,
#   module_deps, job, searchindex, urlshortcodes (short links hold absolute URLs of their own host)
#
# Every dump starts with a "-- MUTE-SYNC-USERS:" header (user id:name list). Restore
# refuses to run if the target's users differ, because actor rows in the dump point
# at user ids; both environments are created the same way, so they match.
set -eu

CMD="${1:?usage: sync-db.sh dump|dump-full|restore FILE | counts}"
FILE="${2:-}"
if [ "$CMD" != "counts" ] && [ -z "$FILE" ]; then echo "FILE argument required" >&2; exit 2; fi
export MYSQL_PWD="$MYSQL_PASSWORD"
DB="$MYSQL_DATABASE"
U="$MYSQL_USER"

q() { mariadb -u "$U" -N -B "$DB" -e "$1"; }
users() { q "select concat(user_id,':',user_name) from user order by user_id" | tr '\n' ','; }

excluded_tables() {
  q "select table_name from information_schema.tables where table_schema = database() and (
       table_name in ('user','user_groups','user_properties','user_autocreate_serial','user_newtalk',
                      'user_former_groups','user_email_token','objectcache','l10n_cache','module_deps',
                      'job','searchindex','urlshortcodes')
       or table_name like 'oauth\\_%' or table_name like 'oathauth\\_%' or table_name like 'cu\\_%'
       or table_name like 'echo\\_%' or table_name like 'loginnotify\\_%')"
}

write_dump() {
  ign=""
  if [ "$1" = "content" ]; then
    for t in $(excluded_tables); do ign="$ign --ignore-table=$DB.$t"; done
  fi
  {
    echo "-- MUTE-SYNC-KIND: $1"
    echo "-- MUTE-SYNC-USERS: $(users)"
    echo "-- MUTE-SYNC-CREATED: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$FILE"
  # shellcheck disable=SC2086
  mariadb-dump -u "$U" --single-transaction --quick --default-character-set=utf8mb4 \
    --max-allowed-packet=256M $ign "$DB" >> "$FILE"
  tail -n 3 "$FILE" | grep -q "Dump completed" || { echo "ABORT: dump looks truncated" >&2; exit 4; }
  echo "dump ok: $FILE ($(wc -c < "$FILE") bytes, kind=$1)"
}

case "$CMD" in
  dump)      write_dump content ;;
  dump-full) write_dump full ;;
  restore)
    [ -s "$FILE" ] || { echo "ABORT: $FILE missing or empty" >&2; exit 2; }
    want="$(head -n 5 "$FILE" | sed -n 's/^-- MUTE-SYNC-USERS: //p' | head -n 1)"
    have="$(users)"
    [ -n "$want" ] || { echo "ABORT: $FILE has no MUTE-SYNC header (not made by sync-db.sh)" >&2; exit 2; }
    if [ "$want" != "$have" ]; then
      echo "ABORT: user lists differ - source '$want' vs target '$have'" >&2
      exit 3
    fi
    tail -n 3 "$FILE" | grep -q "Dump completed" || { echo "ABORT: $FILE looks truncated" >&2; exit 4; }
    mariadb -u "$U" --default-character-set=utf8mb4 "$DB" < "$FILE"
    q "delete from objectcache; delete from l10n_cache;"
    echo "restore ok"
    ;;
  counts)
    echo "items=$(q 'select count(*) from page where page_namespace=120') properties=$(q 'select count(*) from page where page_namespace=122') pages=$(q 'select count(*) from page') revisions=$(q 'select count(*) from revision')"
    ;;
  *) echo "unknown command: $CMD" >&2; exit 2 ;;
esac
