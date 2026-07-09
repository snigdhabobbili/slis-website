import psycopg2
import psycopg2.extras

# ─── DATABASE CONFIG ──────────────────────────────────────────────────────────
# Change these values when moving to the production server (.185)
DB_HOST     = "localhost"
DB_PORT     = 5432
DB_NAME     = "slis"
DB_USER     = "postgres"
DB_PASSWORD = "snigdhapandu"


def get_conn():
    return psycopg2.connect(
        host     = DB_HOST,
        port     = DB_PORT,
        dbname   = DB_NAME,
        user     = DB_USER,
        password = DB_PASSWORD
    )


def get_dict_conn():
    """Returns connection with RealDictCursor — rows come back as dicts."""
    conn   = get_conn()
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    return conn, cursor
