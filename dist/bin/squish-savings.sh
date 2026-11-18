#!/bin/sh
#
# Squish - Storage savings report
# ============================================
# Tells you (and the customer) how much storage Squish has reclaimed since
# activation, straight from the SQUISH_PROCESSED tracking table.
#
#   bin/squish-savings.sh                               # whole history
#   bin/squish-savings.sh --since 2026-01-01            # from a date
#   bin/squish-savings.sh --since 2026-01-01 --until 2026-03-31
#
# Reads the DB connection from config/squish.env (the same DB_URL / DB_USER /
# DB_PASSWORD the application uses). Requires sqlplus on PATH (Oracle Instant
# Client). Read-only: it runs one SELECT, never writes.
#
# The credentials are fed to sqlplus over stdin via `connect`, NOT on the
# command line, so the password never shows up in `ps` - same reason the app
# takes them from the environment.
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${SQUISH_ENV:-$SRC_DIR/config/squish.env}"
SQL_FILE="$SRC_DIR/sql/savings_report.sql"

SINCE=""
UNTIL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        --until) UNTIL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--since YYYY-MM-DD] [--until YYYY-MM-DD]"
            echo ""
            echo "  Reports cumulative storage saved by Squish (SUCCESS rows)."
            echo "  No window = whole history, i.e. since activation."
            exit 0 ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            echo "Usage: $0 [--since YYYY-MM-DD] [--until YYYY-MM-DD]" >&2
            exit 1 ;;
    esac
done

# Validate the dates before they go anywhere near the SQL stream.
for d in "$SINCE" "$UNTIL"; do
    if [ -n "$d" ] && ! echo "$d" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        echo "ERROR: date must be YYYY-MM-DD, got: $d" >&2
        exit 1
    fi
done

command -v sqlplus >/dev/null 2>&1 || {
    echo "ERROR: sqlplus not found on PATH (Oracle Instant Client needed)." >&2
    exit 1
}
[ -f "$ENV_FILE" ] || { echo "ERROR: env file not found: $ENV_FILE" >&2; exit 1; }
[ -f "$SQL_FILE" ] || { echo "ERROR: sql file not found: $SQL_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
. "$ENV_FILE"

: "${DB_USER:?DB_USER not set in $ENV_FILE}"
: "${DB_PASSWORD:?DB_PASSWORD not set in $ENV_FILE}"

# Derive the sqlplus easy-connect string from the JDBC URL unless the caller
# pins it with SQLPLUS_CONNECT. Handles the two common thin forms:
#   jdbc:oracle:thin:@//host:port/service   -> //host:port/service
#   jdbc:oracle:thin:@host:port:SID         -> host:port:SID
if [ -z "${SQLPLUS_CONNECT:-}" ]; then
    : "${DB_URL:?DB_URL not set in $ENV_FILE (or set SQLPLUS_CONNECT)}"
    SQLPLUS_CONNECT=$(printf '%s' "$DB_URL" | sed -E 's|^jdbc:oracle:thin:@||')
    if [ -z "$SQLPLUS_CONNECT" ] || [ "$SQLPLUS_CONNECT" = "$DB_URL" ]; then
        echo "ERROR: could not derive an sqlplus connect string from DB_URL." >&2
        echo "       Set SQLPLUS_CONNECT explicitly, e.g. //host:1521/SERVICE" >&2
        exit 1
    fi
fi

# -s silent (no banner), -L one login attempt (fail fast on bad creds instead
# of re-prompting). Credentials and the date window go in over stdin; DEFINEing
# the two vars means savings_report.sql never prompts.
sqlplus -s -L /nolog <<SQLPLUS
WHENEVER SQLERROR EXIT FAILURE
connect $DB_USER/$DB_PASSWORD@$SQLPLUS_CONNECT
DEFINE p_since = "$SINCE"
DEFINE p_until = "$UNTIL"
@$SQL_FILE
SQLPLUS
