"""
migrate.py — Run this ONCE to create tables and import CSV data into PostgreSQL.

Usage:
    python migrate.py

Make sure db.py has the correct DB_HOST, DB_USER, DB_PASSWORD before running.
The three CSV files must be in the same folder as this script.
"""

import psycopg2
import pandas as pd
import os
from db import get_conn

CSV_DIR = os.path.dirname(os.path.abspath(__file__))


def create_tables(cursor):
    print("Creating tables...")

    # ── slis_substationdata ──────────────────────────────────────────────────
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS slis_substationdata (
            ss_id             SMALLINT PRIMARY KEY,
            dist_code         SMALLINT,
            dist_name         VARCHAR(100),
            sub_station_name  VARCHAR(200),
            voltage           VARCHAR(50),
            mobile_no         VARCHAR(20),
            password          VARCHAR(100),
            zone              VARCHAR(100),
            circle            VARCHAR(100)
        )
    """)

    # ── capacity_new ─────────────────────────────────────────────────────────
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS capacity_new (
            sno              SMALLINT PRIMARY KEY,
            ss_id            SMALLINT REFERENCES slis_substationdata(ss_id),
            ss_name          VARCHAR(200),
            "PTR_Capacity"   VARCHAR(50),
            "Voltage_Rating" VARCHAR(50),
            "Manufacturer"   VARCHAR(200),
            "ManufSerialNo"  VARCHAR(100),
            "YoM"            VARCHAR(20),
            "Doc"            VARCHAR(50)
        )
    """)

    # ── SubStationLoad ───────────────────────────────────────────────────────
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS "SubStationLoad" (
            id               SERIAL PRIMARY KEY,
            sno              INT,
            ss_id            INT REFERENCES slis_substationdata(ss_id),
            ss_name          VARCHAR(200),
            "PTR_Capacity"   VARCHAR(50),
            "Voltage_Rating" VARCHAR(50),
            maxload          VARCHAR(20),
            minload          VARCHAR(20),
            min_loadtime     VARCHAR(20),
            loaddate         DATE,
            loadtime         VARCHAR(20),
            created_by       VARCHAR(50),
            created_on       TIMESTAMP DEFAULT NOW(),
            remarks          VARCHAR(500),
            transid          VARCHAR(100)
        )
    """)

    # ── users (dashboard officers) ───────────────────────────────────────────
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id               SERIAL PRIMARY KEY,
            username         VARCHAR(100) UNIQUE NOT NULL,
            password_hash    VARCHAR(256) NOT NULL,
            is_admin         BOOLEAN DEFAULT FALSE,
            is_first_login   BOOLEAN DEFAULT TRUE,
            failed_attempts  INT DEFAULT 0,
            is_locked        BOOLEAN DEFAULT FALSE,
            lock_time        TIMESTAMP,
            password_expiry  TIMESTAMP,
            reset_token      VARCHAR(200),
            token_expiry     TIMESTAMP
        )
    """)

    print("Tables created.")


def import_substations(cursor, conn):
    path = os.path.join(CSV_DIR, "slis_substationdata.csv")
    print(f"Importing {path} ...")
    df = pd.read_csv(path, encoding="utf-8-sig")
    df.columns = [c.strip() for c in df.columns]

    # Replace NULL strings with None
    df = df.where(pd.notnull(df), None)

    for _, row in df.iterrows():
        cursor.execute("""
            INSERT INTO slis_substationdata
                (ss_id, dist_code, dist_name, sub_station_name, voltage,
                 mobile_no, password, zone, circle)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (ss_id) DO NOTHING
        """, (
            row.get("ss_id"), row.get("dist_code"), row.get("dist_name"),
            row.get("sub_station_name"), row.get("voltage"),
            None if str(row.get("mobile_no", "")).upper() in ("NULL", "NAN", "") else str(row.get("mobile_no")).split(".")[0],
            row.get("password"), row.get("zone"), row.get("circle")
        ))

    conn.commit()
    print(f"  → {len(df)} substations imported.")


def import_capacity(cursor, conn):
    path = os.path.join(CSV_DIR, "capacity_new.csv")
    print(f"Importing {path} ...")
    df = pd.read_csv(path, encoding="utf-8-sig")
    df.columns = [c.strip() for c in df.columns]
    df = df.where(pd.notnull(df), None)

    for _, row in df.iterrows():
        cursor.execute("""
            INSERT INTO capacity_new
                (sno, ss_id, ss_name, "PTR_Capacity", "Voltage_Rating",
                 "Manufacturer", "ManufSerialNo", "YoM", "Doc")
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (sno) DO NOTHING
        """, (
            row.get("sno"), row.get("ss_id"), row.get("ss_name"),
            row.get("PTR_Capacity"), row.get("Voltage_Rating"),
            row.get("Manufacturer"), row.get("ManufSerialNo"),
            row.get("YoM"), row.get("Doc")
        ))

    conn.commit()
    print(f"  → {len(df)} PTR records imported.")


def import_load(cursor, conn):
    path = os.path.join(CSV_DIR, "SubStationLoad.csv")
    print(f"Importing {path} ...")
    df = pd.read_csv(path, encoding="utf-8-sig")
    df.columns = [c.strip() for c in df.columns]
    df = df.where(pd.notnull(df), None)

    for _, row in df.iterrows():
        cursor.execute("""
            INSERT INTO "SubStationLoad"
                (id, sno, ss_id, ss_name, "PTR_Capacity", "Voltage_Rating",
                 maxload, minload, min_loadtime, loaddate, loadtime,
                 created_by, created_on, remarks, transid)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id) DO NOTHING
        """, (
            row.get("id"), row.get("sno"), row.get("ss_id"), row.get("ss_name"),
            row.get("PTR_Capacity"), row.get("Voltage_Rating"),
            row.get("maxload"), row.get("minload"), row.get("min_loadtime"),
            row.get("loaddate"), row.get("loadtime"),
            row.get("created_by"), row.get("created_on"),
            row.get("remarks"), row.get("transid")
        ))

    conn.commit()
    print(f"  → {len(df)} load records imported.")


def create_default_users(cursor, conn):
    from werkzeug.security import generate_password_hash
    from datetime import datetime, timedelta
    print("Creating dashboard officer accounts...")

    officers = [
        "ce.400kv.vs","ce.civil","ce.comml.rac","ed.comml.tgppcc",
        "ce.const1","ce.const2","ce.training","ce.lis","ce.pmm","ce.ps",
        "ce.prlis.vs","ce.sldc","ce.trans","ce.knr","ce.metro","ce.rural",
        "ce.wgl","ce.400kv.wgl","ce.it",
        "se.omc.adb","se.omc.knr","se.omc.nzb","se.omc.rdm","se.omc.mc",
        "se.omc.me","se.omc.ms","se.omc.mw","se.omc.mbnr","se.omc.nlg",
        "se.omc.srd","se.omc.sdpt","se.omc.srpt","se.omc.wnpt",
        "se.omc.jngn","se.omc.khmm","se.omc.wgl",
        "ade.onm.srpr","de.onm.jgt","de.onm.knr","de.onm.mncl",
        "de.onm.nzb","de.onm.rdm","ade.onm.cemetro","de.onm.me",
        "de.onm.mw","de.onm.veltoor","de.onm.dindi","de.onm.mbnr",
        "de.onm.mlg","de.onm.nlg","de.onm.sdpt","de.onm.wnpt",
        "de.onm.ydml","de.onm1.wgl","de.onm2.wgl","de.onm.bdmp",
        "de.onm.jngn","de.4onm.dcpl","de.4onm.nrml","de.4mrt.metro",
        "de.4onm.mkm","de.4onm.mdp","de.4onm.gjwl","de.4onm.mhm",
        "de.4onm.nspr","de.4onm.skp","de.4onm.srpt","de.4mrt.rural",
        "de.4mrt.wgl","de.4onm.aspk","de.4onm.jlpd"
    ]

    expiry = datetime.now() + timedelta(days=90)

    for username in officers:
        hashed = generate_password_hash("Welcome@123")
        cursor.execute("""
            INSERT INTO users (username, password_hash, is_admin, is_first_login, password_expiry)
            VALUES (%s, %s, FALSE, TRUE, %s)
            ON CONFLICT (username) DO NOTHING
        """, (username, hashed, expiry))

    conn.commit()
    print(f"  → {len(officers)} officer accounts created (default password: Welcome@123)")


if __name__ == "__main__":
    print("=" * 50)
    print("SLIS PostgreSQL Migration")
    print("=" * 50)

    conn   = get_conn()
    cursor = conn.cursor()

    try:
        create_tables(cursor)
        conn.commit()
        import_substations(cursor, conn)
        import_capacity(cursor, conn)
        import_load(cursor, conn)
        create_default_users(cursor, conn)
        print("\n✅ Migration complete. Database is ready.")
    except Exception as e:
        conn.rollback()
        print(f"\n❌ Migration failed: {e}")
        raise
    finally:
        cursor.close()
        conn.close()