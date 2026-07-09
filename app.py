from flask import Flask, render_template, request, jsonify, redirect, url_for, session, send_file
import pandas as pd
import io
import os
import re
import secrets
import requests
from datetime import datetime, timedelta
from werkzeug.security import generate_password_hash, check_password_hash
from db import get_conn

app = Flask(__name__, template_folder="templates", static_folder="static")
app.secret_key = "slis_secret_2026"
app.config["API_TOKEN"] = "slis_api_token_2026"

def df_to_records(df):
    """..."""
    return df.astype(object).where(pd.notnull(df), None).to_dict(orient="records")


# ─── DAILY ENTRY CONSTANTS ────────────────────────────────────────────
PTR_ORDER = (
    ' ORDER BY NULLIF(SPLIT_PART("Voltage_Rating", \'/\', 1), \'\')::INT DESC NULLS LAST,'
    ' NULLIF("PTR_Capacity", \'\')::INT DESC NULLS LAST, sno'
)

UPSERT_SQL = """
    INSERT INTO "SubStationLoad"
        (id, sno, ss_id, ss_name, "PTR_Capacity", "Voltage_Rating", maxload, minload,
         min_loadtime, loaddate, loadtime, created_by, created_on, remarks)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, NOW(), %s)
    ON CONFLICT (ss_id, sno, loaddate) DO UPDATE SET
        maxload      = COALESCE(NULLIF(EXCLUDED.maxload, ''),      "SubStationLoad".maxload),
        loadtime     = COALESCE(NULLIF(EXCLUDED.loadtime, ''),     "SubStationLoad".loadtime),
        minload      = COALESCE(NULLIF(EXCLUDED.minload, ''),      "SubStationLoad".minload),
        min_loadtime = COALESCE(NULLIF(EXCLUDED.min_loadtime, ''), "SubStationLoad".min_loadtime),
        remarks      = COALESCE(NULLIF(EXCLUDED.remarks, ''),      "SubStationLoad".remarks),
        created_on   = NOW()
"""

def _norm(v):
    """'' / whitespace -> None so empty fields never overwrite saved values."""
    if v is None:
        return None
    v = str(v).strip()
    return v if v else None
def _next_available_id(cur, table="SubStationLoad"):
    """Find the smallest unused id (fills gaps from deleted rows)."""
    cur.execute(f'''
        SELECT COALESCE(MIN(t1.id + 1), 1)
        FROM "{table}" t1
        LEFT JOIN "{table}" t2 ON t1.id + 1 = t2.id
        WHERE t2.id IS NULL
    ''')
    result = cur.fetchone()[0]
    # Handle empty table case (MIN over empty LEFT JOIN can misbehave)
    cur.execute(f'SELECT COUNT(*) FROM "{table}"')
    if cur.fetchone()[0] == 0:
        return 1
    return result


# ─── GROQ / CHATBOT CONFIG ────────────────────────────────────────────
...



# ─── GROQ / CHATBOT CONFIG ────────────────────────────────────────────────────
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "GROQ_API_KEY")
GROQ_URL     = "https://api.groq.com/openai/v1/chat/completions"
GROQ_MODEL   = "llama-3.3-70b-versatile"

LLM_SYSTEM_PROMPT = """You rewrite a user's chat question into a short, literal command for a power-substation load-monitoring system. You do NOT answer the question. You only rewrite it.

Output ONLY the rewritten command on a single line. No explanation, no quotes, no markdown.

STRICT OUTPUT FORMAT:
[station max] [ptr] [substation name] [date phrase]   — for load/transformer questions
OR
master info [substation name]                          — for zone/circle/transformer-count questions about ONE substation
OR
list substations [circle:<name>] [zone:<name>] [voltage:<class>]   — for questions about MULTIPLE/ALL substations
(include only the parts that apply — never include anything else)

VOCABULARY THE DOWNSTREAM SYSTEM UNDERSTANDS:
- "station max" = the peak/highest/maximum load of a substation
- "ptr" = power transformer details
- "master info" = substation master details for ONE named substation
- "list substations" = a request for MULTIPLE substations
- Substation name: extract ONLY the bare proper-noun name (e.g. "gachibowli", "hyderabad", "warangal")
- Dates: convert any date the user mentions into "DD Month YYYY" format or keep relative terms as-is: "yesterday", "today", "last N days", "last week", "week before last", "this month", "last month", "this year", "last year"
- Greetings ("hi", "hello", "hey", "good morning", etc.) and anything unrelated to substation data: output the message UNCHANGED.

EXAMPLES:
User: "what was the highest load at hyderabad substation yesterday"
Output: station max hyderabad yesterday

User: "give me transformer info for nizamabad"
Output: ptr nizamabad

User: "hi"
Output: hi
"""


def llm_normalize_message(raw_message):
    if not GROQ_API_KEY or GROQ_API_KEY == "YOUR_GROQ_API_KEY_HERE" or not raw_message.strip():
        return raw_message
    try:
        resp = requests.post(
            GROQ_URL,
            headers={"Authorization": f"Bearer {GROQ_API_KEY}", "Content-Type": "application/json"},
            json={
                "model": GROQ_MODEL,
                "messages": [
                    {"role": "system", "content": LLM_SYSTEM_PROMPT},
                    {"role": "user",   "content": raw_message},
                ],
                "temperature": 0,
                "max_tokens":  60,
            },
            timeout=6,
        )
        resp.raise_for_status()
        rewritten = resp.json()["choices"][0]["message"]["content"].strip().strip('"\'')
        return rewritten if rewritten else raw_message
    except Exception as e:
        print("LLM NORMALIZE FAILED:", repr(e))
        return raw_message


def validate_password(password):
    if len(password) < 8:
        return "Password must be at least 8 characters"
    if not re.search(r"[A-Z]", password):
        return "Must contain uppercase letter"
    if not re.search(r"[a-z]", password):
        return "Must contain lowercase letter"
    if not re.search(r"[0-9]", password):
        return "Must contain number"
    if not re.search(r"[!@#$%^&*]", password):
        return "Must contain special character (!@#$%^&*)"
    return None


# ─── AUTH HELPERS ─────────────────────────────────────────────────────────────
def logged_in():
    if "user" in session:
        return True
    # Accept token from Flutter app
    token = request.headers.get("X-Auth-Token")
    if token and token == app.config.get("API_TOKEN", "slis_api_token_2026"):
        return True
    return False

def is_admin():
    if session.get("role") == "admin":
        return True
    token = request.headers.get("X-Auth-Token")
    if token and token == app.config.get("API_TOKEN", "slis_api_token_2026"):
        return True
    return False

def is_field_user():
    return session.get("role") == "field"

def can_edit_load_data():
    """Field users (data entry) and admin can edit/delete Load Data rows.
    Officers ("dashboard users" — view-only role) cannot."""
    if session.get("role") in ("admin", "field"):
        return True
    token = request.headers.get("X-Auth-Token")
    if token and token == app.config.get("API_TOKEN", "slis_api_token_2026"):
        return True
    return False

def is_officer():
    return session.get("role") == "officer"


# ─── HOME ─────────────────────────────────────────────────────────────────────
@app.route("/")
def home():
    return redirect(url_for("login"))


# ─── LOGIN ────────────────────────────────────────────────────────────────────
@app.route("/login", methods=["GET", "POST"])
def login():
    if logged_in():
        return redirect(url_for("dashboard"))

    if request.method == "GET":
        return render_template("login.html")

    username = request.form.get("username", "").strip()
    password = request.form.get("password", "").strip()

    if not username or not password:
        return render_template("login.html", error="Please enter username and password")

    # ── Path 1: Hardcoded admin ───────────────────────────────────────────────
    if username == "admin" and password == "admin@123":
        session["user"] = "admin"
        session["role"] = "admin"
        return redirect(url_for("dashboard"))

    conn = None
    try:
        conn = get_conn()
        cur  = conn.cursor()

        # ── Path 2: Dashboard officers (users table) ──────────────────────────
        cur.execute("SELECT * FROM users WHERE username = %s", (username,))
        cols = [d[0] for d in cur.description]
        row  = cur.fetchone()

        if row:
            user = dict(zip(cols, row))
            failed   = user.get("failed_attempts") or 0
            locked   = user.get("is_locked") or False
            locktime = user.get("lock_time")

            if locked:
                if locktime:
                    unlock_at = locktime + timedelta(minutes=5)
                    if datetime.now() < unlock_at:
                        mins = int((unlock_at - datetime.now()).total_seconds() / 60) + 1
                        conn.close()
                        return render_template("login.html", error=f"Account locked. Try again in {mins} minutes")
                    else:
                        cur.execute("UPDATE users SET failed_attempts=0, is_locked=FALSE, lock_time=NULL WHERE username=%s", (username,))
                        conn.commit()
                        failed = 0
                        locked = False
                else:
                    conn.close()
                    return render_template("login.html", error="Account locked. Contact admin")

            if not check_password_hash(user["password_hash"], password):
                attempts = failed + 1
                if attempts >= 3:
                    cur.execute("UPDATE users SET failed_attempts=%s, is_locked=TRUE, lock_time=NOW() WHERE username=%s", (attempts, username))
                else:
                    cur.execute("UPDATE users SET failed_attempts=%s WHERE username=%s", (attempts, username))
                conn.commit()
                conn.close()
                msg = "Account locked after 3 attempts (unlocks in 5 min)" if attempts >= 3 else f"Invalid credentials ({attempts}/3)"
                return render_template("login.html", error=msg)

            # Password correct — reset attempts
            cur.execute("UPDATE users SET failed_attempts=0, is_locked=FALSE, lock_time=NULL WHERE username=%s", (username,))
            conn.commit()

            if user.get("is_first_login"):
                session["reset_user"] = username
                conn.close()
                return redirect(url_for("change_password"))

            expiry = user.get("password_expiry")
            if expiry and expiry < datetime.now():
                session["reset_user"] = username
                conn.close()
                return redirect(url_for("change_password"))

            conn.close()
            session["user"] = username
            session["role"] = "admin" if user.get("is_admin") else "officer"
            return redirect(url_for("dashboard"))

        # ── Path 3: Field users (slis_substationdata) ─────────────────────────
        cur.execute(
            "SELECT ss_id, sub_station_name, mobile_no, password FROM slis_substationdata WHERE mobile_no = %s",
            (username,)
        )
        cols2 = [d[0] for d in cur.description]
        row2  = cur.fetchone()

        if row2:
            fu = dict(zip(cols2, row2))
            if fu["password"] == password:
                conn.close()
                session["user"]      = username
                session["role"]      = "field"
                session["ss_id"]     = fu["ss_id"]
                session["ss_name"]   = fu["sub_station_name"]
                session["mobile_no"] = username
                return redirect(url_for("dashboard"))
            else:
                conn.close()
                return render_template("login.html", error="Invalid credentials")

        conn.close()
        return render_template("login.html", error="User not found")

    except Exception as e:
        if conn:
            conn.close()
        print("LOGIN ERROR:", e)
        return render_template("login.html", error="Server error. Please try again.")


# ─── LOGOUT ───────────────────────────────────────────────────────────────────
@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ─── CHANGE PASSWORD ──────────────────────────────────────────────────────────
@app.route("/admin/change_password", methods=["POST"])
def admin_change_password():
    if not logged_in() or not is_admin():
        return redirect(url_for("login"))

    ss_id    = request.form.get("ss_id")
    new_pass = request.form.get("new_password")
    confirm  = request.form.get("confirm_password")

    if new_pass != confirm:
        return redirect(url_for("admin_settings"))

    conn = get_conn()
    cur  = conn.cursor()

    if ss_id.startswith("officer_"):
        officer_id = ss_id.replace("officer_", "")
        hashed = generate_password_hash(new_pass)
        cur.execute("UPDATE users SET password_hash=%s, is_first_login=FALSE WHERE id=%s", (hashed, officer_id))
    else:
        field_id = ss_id.replace("field_", "")
        cur.execute("UPDATE slis_substationdata SET password=%s WHERE ss_id=%s", (new_pass, field_id))

    conn.commit()
    conn.close()
    return redirect(url_for("admin_settings"))


# ─── CHANGE PASSWORD (forced: first login / expired password) ────────────────
# login() redirects here via url_for("change_password") when a users-table
# account (officer/admin) has is_first_login=True or a lapsed
# password_expiry, storing the pending username in session["reset_user"].
# This route didn't exist before — that redirect raised a BuildError and
# left those accounts stuck unable to log in at all.
@app.route("/change_password", methods=["GET", "POST"])
def change_password():
    username = session.get("reset_user")
    if not username:
        return redirect(url_for("login"))

    if request.method == "GET":
        return render_template("change_password.html")

    new_password     = request.form.get("new_password", "")
    confirm_password = request.form.get("confirm_password", "")

    if new_password != confirm_password:
        return render_template("change_password.html", error="Passwords do not match")

    validation_error = validate_password(new_password)
    if validation_error:
        return render_template("change_password.html", error=validation_error)

    conn = None
    try:
        conn = get_conn()
        cur  = conn.cursor()
        hashed = generate_password_hash(new_password)
        cur.execute(
            "UPDATE users SET password_hash=%s, is_first_login=FALSE, "
            "password_expiry=NOW() + INTERVAL '90 days' WHERE username=%s",
            (hashed, username)
        )
        conn.commit()

        cur.execute("SELECT is_admin FROM users WHERE username=%s", (username,))
        row = cur.fetchone()
        conn.close()

        # Reset succeeded — log them straight in rather than bouncing them
        # back to the login form to re-enter what they just typed.
        session.pop("reset_user", None)
        session["user"] = username
        session["role"] = "admin" if (row and row[0]) else "officer"
        return redirect(url_for("dashboard"))

    except Exception as e:
        if conn:
            conn.close()
        print("CHANGE PASSWORD ERROR:", e)
        return render_template("change_password.html", error="Server error. Please try again.")


# ─── PASSWORD RESET (token-based) ─────────────────────────────────────────────
@app.route("/request_reset", methods=["POST"])
def request_reset():
    username = request.json.get("username")
    conn     = get_conn()
    cur      = conn.cursor()
    cur.execute("SELECT id FROM users WHERE username=%s", (username,))
    if not cur.fetchone():
        conn.close()
        return jsonify({"error": "User not found"})
    token  = secrets.token_urlsafe(32)
    expiry = datetime.now() + timedelta(minutes=15)
    cur.execute("UPDATE users SET reset_token=%s, token_expiry=%s WHERE username=%s", (token, expiry, username))
    conn.commit()
    conn.close()
    return jsonify({"msg": "Token generated", "token": token})


@app.route("/reset_password", methods=["POST"])
def reset_password():
    data     = request.json
    token    = data.get("token")
    new_pass = data.get("new_password")
    hashed   = generate_password_hash(new_pass)
    conn     = get_conn()
    cur      = conn.cursor()
    cur.execute("SELECT username FROM users WHERE reset_token=%s AND token_expiry > NOW()", (token,))
    row = cur.fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "Invalid or expired token"})
    cur.execute("UPDATE users SET password_hash=%s, reset_token=NULL, token_expiry=NULL WHERE username=%s", (hashed, row[0]))
    conn.commit()
    conn.close()
    return jsonify({"msg": "Password reset successful"})


# ─── DASHBOARD ────────────────────────────────────────────────────────────────
@app.route("/dashboard")
def dashboard():
    if not logged_in():
        return redirect(url_for("login"))
    return render_template("dashboard.html",
        user=session.get("user"),
        role=session.get("role"),
        ss_name=session.get("ss_name", "")
    )


# ─── ZONES / CIRCLES / SUBSTATIONS ───────────────────────────────────────────
@app.route("/zones")
def get_zones():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql("SELECT DISTINCT zone FROM slis_substationdata ORDER BY zone", conn)
        conn.close()
        return jsonify(df["zone"].dropna().astype(str).tolist())
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/circles/<zone>")
def get_circles(zone):
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql(
            "SELECT DISTINCT circle FROM slis_substationdata WHERE zone=%s ORDER BY circle",
            conn, params=[zone]
        )
        conn.close()
        return jsonify(df["circle"].tolist())
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/substations/<circle>")
def get_substations(circle):
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql(
            "SELECT ss_id, sub_station_name FROM slis_substationdata WHERE circle=%s ORDER BY sub_station_name",
            conn, params=[circle]
        )
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/all_substations")
def get_all_substations():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql(
            "SELECT ss_id, sub_station_name FROM slis_substationdata ORDER BY sub_station_name",
            conn
        )
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    
@app.route("/api/substations_full")
def api_substations_full():
    """Every column of slis_substationdata — mirrors the website's Substation
    Master Data table (/table/substations) exactly, for the Flutter app's
    Substations tab."""
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql('SELECT * FROM slis_substationdata ORDER BY ss_id', conn)
        conn.close()
        def _clean_id(x):
            if pd.isnull(x):
                return ""
            s = str(x)
            if s.endswith(".0"):
                try:
                    return str(int(float(s)))
                except (ValueError, TypeError):
                    return s
            return s
        df["mobile_no"] = df["mobile_no"].apply(_clean_id)
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ─── MAIN DATA ────────────────────────────────────────────────────────────────
@app.route("/data", methods=["POST"])
def get_data():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401

    data      = request.json
    ss_ids    = data.get("ss_ids", [])
    from_date = data.get("from_date")
    to_date   = data.get("to_date")

    try:
        conn   = get_conn()
        params = list(ss_ids)

        # PostgreSQL voltage sorting using SPLIT_PART
        query = """
        SELECT
            s.ss_id, s.sub_station_name, s.zone, s.circle,
            c.sno, c."PTR_Capacity", c."Voltage_Rating",
            c."Manufacturer", c."ManufSerialNo", c."YoM", c."Doc",
            COALESCE(NULLIF(l.maxload, '')::FLOAT, 0)    AS maxload,
            COALESCE(NULLIF(l.minload, '')::FLOAT, 0)    AS minload,
            l.min_loadtime, l.loadtime, l.loaddate
        FROM slis_substationdata s
        JOIN capacity_new c ON s.ss_id = c.ss_id
        LEFT JOIN "SubStationLoad" l
            ON s.ss_id = l.ss_id AND c.sno = l.sno
        WHERE 1=1
        """

        if ss_ids:
            placeholders = ",".join(["%s"] * len(ss_ids))
            query += f" AND s.ss_id IN ({placeholders})"

        if from_date and to_date:
            query += " AND l.loaddate >= %s AND l.loaddate <= %s"
            params += [from_date, to_date]

        query += """
        ORDER BY
            l.loaddate ASC,
            NULLIF(SPLIT_PART(c."Voltage_Rating", '/', 1), '')::INT DESC NULLS LAST,
            NULLIF(c."PTR_Capacity", '')::INT DESC NULLS LAST
        """

        df = pd.read_sql(query, conn, params=params)
        conn.close()

        if df.empty:
            return jsonify([])

        df["loaddate"] = df["loaddate"].astype(str)
        return jsonify(df_to_records(df))

    except Exception as e:
        print("DATA ERROR:", e)
        return jsonify({"error": str(e)}), 500
@app.route("/api/admin/users", methods=["GET"])
def api_admin_users():
    try:
        conn = get_conn()
        df = pd.read_sql("SELECT ss_id, dist_name, sub_station_name, voltage, mobile_no, zone, circle FROM slis_substationdata ORDER BY ss_id", conn)
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/admin/add_user", methods=["POST"])
def api_admin_add_user():
    if not logged_in():
        return jsonify({"error": "Unauthorized"}), 403
    data      = request.json
    user_type = data.get("user_type", "field")
    conn = get_conn()
    cur = conn.cursor()
    try:
        if user_type == "officer":
            # Dashboard Officer — same `users` table admin/officer logins use,
            # mirrors the website's /admin/add_user officer branch.
            username = (data.get("username") or "").strip()
            password = (data.get("officer_password") or data.get("password") or "").strip() or "password@123"
            hashed   = generate_password_hash(password)
            cur.execute("""
                INSERT INTO users (username, password_hash, is_admin, is_first_login)
                VALUES (%s, %s, FALSE, TRUE)
            """, (username, hashed))
        else:
            cur.execute("""
                INSERT INTO slis_substationdata
                    (ss_id, dist_code, dist_name, sub_station_name, voltage, mobile_no, password, zone, circle)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            """, (
                data.get("ss_id"), data.get("dist_code"), data.get("dist_name"),
                data.get("sub_station_name"), data.get("voltage"),
                data.get("mobile_no"), data.get("password"),
                data.get("zone"), data.get("circle")
            ))
        conn.commit()
        conn.close()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        conn.close()
        return jsonify({"success": False, "error": str(e)})

@app.route("/api/admin/delete_user/<int:ss_id>", methods=["DELETE"])
def api_admin_delete_user(ss_id):
    if not logged_in():
        return jsonify({"error": "Unauthorized"}), 403
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("DELETE FROM slis_substationdata WHERE ss_id = %s", (ss_id,))
    conn.commit()
    conn.close()
    return jsonify({"success": True})




# ─── STATION MAX ──────────────────────────────────────────────────────────────
@app.route("/station_max", methods=["POST"])
def station_max():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401

    data      = request.json
    ss_ids    = data.get("ss_ids", [])
    from_date = data.get("from_date")
    to_date   = data.get("to_date")

    try:
        if not ss_ids:
            return jsonify({"peak": [], "full": []})

        conn         = get_conn()
        placeholders = ",".join(["%s"] * len(ss_ids))

        query = f"""
        WITH ptr_data AS (
            SELECT
                s.ss_id, s.sub_station_name, c.sno,
                NULLIF(SPLIT_PART(c."Voltage_Rating", '/', 1), '')::INT AS primary_voltage
            FROM slis_substationdata s
            JOIN capacity_new c ON s.ss_id = c.ss_id
            WHERE s.ss_id IN ({placeholders})
        ),
        max_voltage AS (
            SELECT ss_id, MAX(primary_voltage) AS max_v FROM ptr_data GROUP BY ss_id
        ),
        filtered_ptrs AS (
            SELECT p.ss_id, p.sub_station_name, p.sno
            FROM ptr_data p
            JOIN max_voltage m ON p.ss_id = m.ss_id AND p.primary_voltage = m.max_v
        ),
        station_daily AS (
            SELECT
                f.ss_id, f.sub_station_name, l.loaddate::DATE AS loaddate,
                SUM(COALESCE(NULLIF(l.maxload, '')::FLOAT, 0)) AS station_max_load
            FROM filtered_ptrs f
            JOIN "SubStationLoad" l ON f.ss_id = l.ss_id AND f.sno = l.sno
            WHERE l.loaddate::DATE BETWEEN %s AND %s
            GROUP BY f.ss_id, f.sub_station_name, l.loaddate::DATE
        )
        SELECT * FROM station_daily ORDER BY loaddate
        """

        df = pd.read_sql(query, conn, params=list(ss_ids) + [from_date, to_date])
        conn.close()

        if df.empty:
            return jsonify({"peak": [], "full": []})

        df["loaddate"] = df["loaddate"].astype(str)
        full_data = df_to_records(df)
        peak_row  = df.loc[df["station_max_load"].idxmax()].to_dict()

        return jsonify({"peak": [peak_row], "full": full_data})

    except Exception as e:
        print("STATION MAX ERROR:", e)
        return jsonify({"error": str(e)}), 500
@app.route("/api/test")
def api_test():
    return jsonify({"status": "ok", "count": 366})


# ─── PTR DETAILS ──────────────────────────────────────────────────────────────
@app.route("/ptr_details_peak", methods=["POST"])
def ptr_details_peak():
    if not logged_in():
        return jsonify([])

    data  = request.json
    ss_id = data.get("ss_id")
    date  = data.get("date")

    try:
        conn  = get_conn()
        query = """
        WITH ptr_data AS (
            SELECT c.ss_id, c.sno, c."PTR_Capacity", c."Voltage_Rating",
                c."Manufacturer", c."ManufSerialNo", c."YoM", c."Doc",
                NULLIF(SPLIT_PART(c."Voltage_Rating", '/', 1), '')::INT AS primary_voltage
            FROM capacity_new c WHERE c.ss_id = %s
        ),
        max_voltage AS (SELECT MAX(primary_voltage) AS max_v FROM ptr_data),
        filtered_ptrs AS (
            SELECT p.* FROM ptr_data p JOIN max_voltage m ON p.primary_voltage = m.max_v
        )
        SELECT
            f.sno, f."PTR_Capacity", f."Voltage_Rating", f."Manufacturer",
            f."ManufSerialNo", f."YoM", f."Doc",
            COALESCE(NULLIF(l.maxload, '')::FLOAT, 0)  AS maxload,
            l.loadtime,
            COALESCE(NULLIF(l.minload, '')::FLOAT, 0)  AS minload,
            l.min_loadtime,
            TO_CHAR(l.loaddate, 'DD-MM-YYYY') AS loaddate
        FROM filtered_ptrs f
        JOIN "SubStationLoad" l ON f.ss_id = l.ss_id AND f.sno = l.sno
        WHERE l.loaddate::DATE = %s::DATE
        ORDER BY f."PTR_Capacity"::INT DESC NULLS LAST
        """
        df = pd.read_sql(query, conn, params=[ss_id, date])
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        print("PTR DETAILS ERROR:", e)
        return jsonify([])


# ─── CHATBOT ──────────────────────────────────────────────────────────────────
@app.route("/chat", methods=["POST"])
def chat():
    data             = request.get_json(force=True)
    raw_msg          = data.get("message", "").strip()
    selected_ss_id   = data.get("ss_id")
    already_resolved = bool(data.get("already_normalized"))
    conn             = None

    if already_resolved:
        msg = raw_msg.lower().strip()
    else:
        msg = llm_normalize_message(raw_msg).lower().strip()

    months_map = {
        "january":1,"february":2,"march":3,"april":4,"may":5,"june":6,
        "july":7,"august":8,"september":9,"october":10,"november":11,"december":12
    }

    try:
        conn = get_conn()

        GREETING_WORDS = {
            "hi","hii","hello","hey","hai","good morning","good afternoon",
            "good evening","morning","evening","thanks","thank you","thx","ok","okay","bye"
        }
        if msg in GREETING_WORDS:
            return jsonify({"type": "text", "reply": "👋 Hello! Ask me about a substation's load, PTR details, or type 'help'."})

        # Normalize aliases
        msg = re.sub(r'station\s+maximum\s+load', 'station max', msg)
        msg = re.sub(r'station\s+maximum',        'station max', msg)
        msg = re.sub(r'station\s+max\s+load',     'station max', msg)
        msg = re.sub(r'peak\s+load',              'station max', msg)
        msg = re.sub(r'\bpeter\b',                'ptr',         msg)
        msg = re.sub(r'\bp\.t\.r\.?\b',           'ptr',         msg)
        msg = re.sub(r'ptr\s+details?',           'ptr',         msg)
        msg = re.sub(r'transformer\s+details?',   'ptr',         msg)
        msg = re.sub(r'power\s+transformer',      'ptr',         msg)

        # Date parsing (same logic as original, adapted for PostgreSQL)
        filter_date     = None
        month_filter    = None
        year_filter     = None
        days_filter     = None
        single_prev_day = None
        year_only       = None

        this_year_flag        = "this year"   in msg
        last_year_flag        = "last year"   in msg
        this_month_flag       = "this month"  in msg
        last_month_flag       = "last month"  in msg
        week_before_last_flag = any(p in msg for p in ["week before last","two weeks ago","last before week","before last week"])
        last_week_flag        = (not week_before_last_flag) and any(p in msg for p in ["last week","previous week","past week"])

        date_match = re.search(r'(\d{1,2})[./-](\d{1,2})[./-](\d{4})', msg)
        if date_match:
            day, month, year = date_match.groups()
            filter_date = f"{year}-{int(month):02d}-{int(day):02d}"

        if not filter_date:
            nat_match = re.search(
                r'(\d{1,2})(?:st|nd|rd|th)?\s*(january|february|march|april|may|june|july|august'
                r'|september|october|november|december)(?:\s*,?\s*(\d{4}))?', msg
            )
            if nat_match:
                nd, nm, ny = nat_match.groups()
                nat_month  = months_map.get(nm)
                if nat_month:
                    nat_year    = int(ny) if ny else (datetime.today().year - 1 if last_year_flag else datetime.today().year)
                    filter_date = f"{nat_year}-{nat_month:02d}-{int(nd):02d}"

        if any(w in msg for w in ["yesterday","last date","previous date","previous day"]):
            single_prev_day = (datetime.today() - timedelta(days=1)).strftime("%Y-%m-%d")

        _WORD_NUMS = {
            "one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,
            "eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,"fifteen":15,"twenty":20,"thirty":30
        }
        _num_alts  = '|'.join(_WORD_NUMS.keys())
        days_match = re.search(r'(?:last|previous)\s+(' + _num_alts + r'|\d+)\s+(days?|weeks?)', msg, re.IGNORECASE)
        if days_match:
            n    = int(days_match.group(1)) if days_match.group(1).isdigit() else _WORD_NUMS.get(days_match.group(1).lower(), 0)
            unit = days_match.group(2).lower()
            if n:
                days_filter = n * 7 if unit.startswith("week") else n

        if not filter_date:
            ym = re.search(r'\b(20\d{2})\b', msg)
            if ym:
                year_only = int(ym.group(1))

        for m in months_map:
            if m in msg.replace("this month","").replace("last month","").replace("this year","").replace("last year",""):
                month_filter = months_map[m]
                year_filter  = year_only if year_only else datetime.now().year

        if this_month_flag:
            month_filter = datetime.today().month
            year_filter  = datetime.today().year
        if last_month_flag:
            first        = datetime.today().replace(day=1)
            last         = first - timedelta(days=1)
            month_filter = last.month
            year_filter  = last.year
        if this_year_flag:
            year_only = datetime.today().year
        if last_year_flag:
            year_only = datetime.today().year - 1

        if last_week_flag or week_before_last_flag:
            today_dt    = datetime.today()
            this_monday = today_dt - timedelta(days=today_dt.weekday())
            if last_week_flag:
                week_start = (this_monday - timedelta(weeks=1)).strftime("%Y-%m-%d")
                week_end   = (this_monday - timedelta(days=1)).strftime("%Y-%m-%d")
            else:
                week_start = (this_monday - timedelta(weeks=2)).strftime("%Y-%m-%d")
                week_end   = (this_monday - timedelta(weeks=1) - timedelta(days=1)).strftime("%Y-%m-%d")
        else:
            week_start = None
            week_end   = None

        if filter_date and month_filter:
            month_filter = None
            year_filter  = None

        year_range_filter = (year_only is not None) and (month_filter is None) and (not filter_date)

        # Resolve substation
        SINGLE_SS_INTENT = not (msg.startswith("list substations") or "help" in msg)
        ss_id = str(selected_ss_id).strip() if selected_ss_id else None

        if SINGLE_SS_INTENT and not ss_id:
            id_match = re.search(r'\b(?:ss_id|ss id|substation id|id)\s*[:\-]?\s*(\d{1,5})\b', msg)
            ss_id    = id_match.group(1) if id_match else None

        if SINGLE_SS_INTENT and not ss_id:
            words_to_remove = [
                "station","substation","maximum","max","load","peak","highest",
                "ptr","details","detail","info","master","all","dates","date",
                "day","days","wise","this","last","previous","year","month",
                "yesterday","week","before","what","whats","is","was","are",
                "the","of","for","at","in","on","demand","value","reading",
                "please","kindly","can","you","tell","me","show","give","know",
                "want","find","get","need","would","like","to","a","an",
                "january","february","march","april","may","june","july",
                "august","september","october","november","december",
                "which","does","belong","belongs","zone","circle","region"
            ]
            ss_name = msg
            ss_name = re.sub(r'\d{1,2}[./-]\d{1,2}[./-]\d{4}', '', ss_name)
            ss_name = re.sub(r'(?:last|previous)\s+(?:' + _num_alts + r'|\d+)\s+(?:days?|weeks?)', '', ss_name, flags=re.IGNORECASE)
            ss_name = re.sub(r'\b20\d{2}\b', '', ss_name)
            ss_name = re.sub(r'\d{1,2}(?:st|nd|rd|th)?\s*(?:january|february|march|april|may|june|july|august|september|october|november|december)', '', ss_name)
            for w in words_to_remove:
                ss_name = re.sub(rf'\b{w}\b', '', ss_name)
            ss_name = re.sub(r'\s+', ' ', ss_name).strip()

            if not ss_name:
                return jsonify({"type": "text", "reply": "❌ Please enter a substation name. Type 'help'"})

            # PostgreSQL uses ILIKE for case-insensitive
            df_names = pd.read_sql(
                "SELECT ss_id, sub_station_name FROM slis_substationdata WHERE LOWER(sub_station_name) LIKE %s",
                conn, params=[f"%{ss_name}%"]
            )

            if df_names.empty and " " in ss_name:
                last_word = ss_name.split()[-1]
                df_names  = pd.read_sql(
                    "SELECT ss_id, sub_station_name FROM slis_substationdata WHERE LOWER(sub_station_name) LIKE %s",
                    conn, params=[f"%{last_word}%"]
                )

            if len(df_names) > 1:
                return jsonify({
                    "type":           "options",
                    "message":        "Multiple substations found. Please select:",
                    "resolved_query": msg,
                    "options":        [{"ss_id": str(r["ss_id"]), "name": r["sub_station_name"]} for _, r in df_names.iterrows()]
                })
            if df_names.empty:
                return jsonify({"type": "text", "reply": "❌ Substation not found. Type 'help'"})

            ss_id = str(df_names.iloc[0]["ss_id"])

        if SINGLE_SS_INTENT and not ss_id:
            return jsonify({"type": "text", "reply": "❌ Could not identify substation. Type 'help'"})

        # ── STATION MAX ───────────────────────────────────────────────────────
        if "station max" in msg:
            # PostgreSQL CTE (uses SPLIT_PART instead of CHARINDEX)
            SM_CTE = """
            WITH ptr_data AS (
                SELECT c.sno,
                    NULLIF(SPLIT_PART(c."Voltage_Rating", '/', 1), '')::INT AS primary_voltage
                FROM capacity_new c WHERE c.ss_id = %s
            ),
            max_v AS (SELECT MAX(primary_voltage) AS max_v FROM ptr_data),
            filtered_ptrs AS (SELECT p.sno FROM ptr_data p JOIN max_v m ON p.primary_voltage = m.max_v)
            """

            if filter_date:
                query = SM_CTE + """
                SELECT s.ss_id, s.sub_station_name,
                    SUM(COALESCE(NULLIF(l.maxload,'')::FLOAT, 0)) AS station_max_load,
                    TO_CHAR(%s::DATE, 'DD-MM-YYYY') AS loaddate
                FROM slis_substationdata s
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN "SubStationLoad" l ON s.ss_id = l.ss_id AND f.sno = l.sno AND l.loaddate::DATE = %s::DATE
                WHERE s.ss_id = %s
                GROUP BY s.ss_id, s.sub_station_name
                """
                params     = [ss_id, filter_date, filter_date, ss_id]
                show_graph = False

            elif single_prev_day:
                query = SM_CTE + """
                SELECT s.ss_id, s.sub_station_name,
                    SUM(COALESCE(NULLIF(l.maxload,'')::FLOAT, 0)) AS station_max_load,
                    TO_CHAR(%s::DATE, 'DD-MM-YYYY') AS loaddate
                FROM slis_substationdata s
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN "SubStationLoad" l ON s.ss_id = l.ss_id AND f.sno = l.sno AND l.loaddate::DATE = %s::DATE
                WHERE s.ss_id = %s
                GROUP BY s.ss_id, s.sub_station_name
                """
                params     = [ss_id, single_prev_day, single_prev_day, ss_id]
                show_graph = False

            elif days_filter:
                start_date = (datetime.today() - timedelta(days=days_filter)).strftime("%Y-%m-%d")
                end_date   = datetime.today().strftime("%Y-%m-%d")
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT l.loaddate::DATE AS loaddate
                    FROM "SubStationLoad" l JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = %s AND l.loaddate::DATE BETWEEN %s AND %s
                )
                SELECT s.ss_id, s.sub_station_name,
                    SUM(COALESCE(NULLIF(l.maxload,'')::FLOAT, 0)) AS station_max_load,
                    TO_CHAR(d.loaddate, 'DD-MM-YYYY') AS loaddate
                FROM slis_substationdata s
                JOIN all_dates d ON 1=1
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN "SubStationLoad" l ON s.ss_id = l.ss_id AND f.sno = l.sno AND l.loaddate::DATE = d.loaddate
                WHERE s.ss_id = %s
                GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                ORDER BY d.loaddate
                """
                params     = [ss_id, ss_id, start_date, end_date, ss_id]
                show_graph = True

            elif (last_week_flag or week_before_last_flag) and week_start:
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT l.loaddate::DATE AS loaddate
                    FROM "SubStationLoad" l JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = %s AND l.loaddate::DATE BETWEEN %s AND %s
                )
                SELECT s.ss_id, s.sub_station_name,
                    SUM(COALESCE(NULLIF(l.maxload,'')::FLOAT, 0)) AS station_max_load,
                    TO_CHAR(d.loaddate, 'DD-MM-YYYY') AS loaddate
                FROM slis_substationdata s
                JOIN all_dates d ON 1=1
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN "SubStationLoad" l ON s.ss_id = l.ss_id AND f.sno = l.sno AND l.loaddate::DATE = d.loaddate
                WHERE s.ss_id = %s
                GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                ORDER BY d.loaddate
                """
                params     = [ss_id, ss_id, week_start, week_end, ss_id]
                show_graph = True

            elif month_filter:
                if not year_filter:
                    year_filter = datetime.now().year
                start_date = f"{year_filter}-{month_filter:02d}-01"
                end_date   = f"{year_filter+1}-01-01" if month_filter == 12 else f"{year_filter}-{month_filter+1:02d}-01"
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT l.loaddate::DATE AS loaddate
                    FROM "SubStationLoad" l JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = %s AND l.loaddate::DATE >= %s AND l.loaddate::DATE < %s
                )
                SELECT s.ss_id, s.sub_station_name,
                    SUM(COALESCE(NULLIF(l.maxload,'')::FLOAT, 0)) AS station_max_load,
                    TO_CHAR(d.loaddate, 'DD-MM-YYYY') AS loaddate
                FROM slis_substationdata s
                JOIN all_dates d ON 1=1
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN "SubStationLoad" l ON s.ss_id = l.ss_id AND f.sno = l.sno AND l.loaddate::DATE = d.loaddate
                WHERE s.ss_id = %s
                GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                ORDER BY d.loaddate
                """
                params     = [ss_id, ss_id, start_date, end_date, ss_id]
                show_graph = True

            elif year_range_filter:
                y_start = f"{year_only}-01-01"
                y_end   = f"{year_only}-12-31"
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT l.loaddate::DATE AS loaddate
                    FROM "SubStationLoad" l JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = %s AND l.loaddate::DATE BETWEEN %s AND %s
                ),
                daily_totals AS (
                    SELECT s.ss_id, s.sub_station_name,
                        SUM(COALESCE(NULLIF(l.maxload,'')::FLOAT, 0)) AS station_max_load,
                        TO_CHAR(d.loaddate, 'DD-MM-YYYY') AS loaddate
                    FROM slis_substationdata s
                    JOIN all_dates d ON 1=1
                    JOIN filtered_ptrs f ON 1=1
                    LEFT JOIN "SubStationLoad" l ON s.ss_id = l.ss_id AND f.sno = l.sno AND l.loaddate::DATE = d.loaddate
                    WHERE s.ss_id = %s
                    GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                )
                SELECT * FROM daily_totals ORDER BY station_max_load DESC LIMIT 1
                """
                params     = [ss_id, ss_id, y_start, y_end, ss_id]
                show_graph = False

            else:
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT l.loaddate::DATE AS loaddate
                    FROM "SubStationLoad" l JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = %s
                ),
                daily_totals AS (
                    SELECT s.ss_id, s.sub_station_name,
                        SUM(COALESCE(NULLIF(l.maxload,'')::FLOAT, 0)) AS station_max_load,
                        TO_CHAR(d.loaddate, 'DD-MM-YYYY') AS loaddate
                    FROM slis_substationdata s
                    JOIN all_dates d ON 1=1
                    JOIN filtered_ptrs f ON 1=1
                    LEFT JOIN "SubStationLoad" l ON s.ss_id = l.ss_id AND f.sno = l.sno AND l.loaddate::DATE = d.loaddate
                    WHERE s.ss_id = %s
                    GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                )
                SELECT * FROM daily_totals ORDER BY station_max_load DESC LIMIT 1
                """
                params     = [ss_id, ss_id, ss_id]
                show_graph = False

            df = pd.read_sql(query, conn, params=params)

            if df.empty:
                return jsonify({"type": "text", "reply": "⚠️ No data found"})

            records = df_to_records(df)
            chart   = None

            if show_graph and len(df) > 1:
                labels  = df["loaddate"].tolist()
                values  = [round(float(v), 2) if v else 0 for v in df["station_max_load"].tolist()]
                ss_lbl  = str(df["sub_station_name"].iloc[0])
                chart   = {"labels": labels, "datasets": [{"label": ss_lbl + " — Station Max Load", "data": values}]}

            if any(w in msg for w in ["ptr", "transformer"]) and records:
                peak_rec      = records[0]
                peak_date_raw = str(peak_rec.get("loaddate", ""))
                try:
                    peak_date_sql = datetime.strptime(peak_date_raw, "%d-%m-%Y").strftime("%Y-%m-%d")
                except:
                    peak_date_sql = peak_date_raw

                ptr_query = """
                WITH ptr_data AS (
                    SELECT c.sno, c."PTR_Capacity", c."Voltage_Rating", c."Manufacturer", c."ManufSerialNo", c."YoM", c."Doc",
                        NULLIF(SPLIT_PART(c."Voltage_Rating", '/', 1), '')::INT AS primary_voltage
                    FROM capacity_new c WHERE c.ss_id = %s
                ),
                max_voltage AS (SELECT MAX(primary_voltage) AS max_v FROM ptr_data),
                filtered_ptrs AS (SELECT p.* FROM ptr_data p JOIN max_voltage m ON p.primary_voltage = m.max_v)
                SELECT f."Voltage_Rating", f."PTR_Capacity", f."Manufacturer", f."ManufSerialNo", f."YoM", f."Doc",
                    COALESCE(NULLIF(l.maxload,'')::FLOAT, 0) AS max_load,
                    COALESCE(NULLIF(l.minload,'')::FLOAT, 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    TO_CHAR(l.loaddate, 'DD-MM-YYYY') AS loaddate, f.sno
                FROM filtered_ptrs f
                LEFT JOIN "SubStationLoad" l ON l.ss_id = %s AND f.sno = l.sno AND l.loaddate::DATE = %s::DATE
                ORDER BY f."PTR_Capacity"::INT DESC NULLS LAST
                """
                df_ptr      = pd.read_sql(ptr_query, conn, params=[ss_id, ss_id, peak_date_sql])
                ptr_records = df_to_records(df_ptr) if not df_ptr.empty else []
                return jsonify({"type": "table", "data": records, "chart": chart, "ptr_data": ptr_records, "ptr_label": f"PTR Details on Station Max Date ({peak_date_raw})"})

            return jsonify({"type": "table", "data": records, "chart": chart})

        # ── PTR DETAILS ───────────────────────────────────────────────────────
        elif "ptr" in msg:
            PTR_CTE_ALL = """
            WITH filtered_ptrs AS (
                SELECT c.sno, c."PTR_Capacity", c."Voltage_Rating", c."Manufacturer", c."ManufSerialNo", c."YoM", c."Doc"
                FROM capacity_new c WHERE c.ss_id = %s
            )
            """

            if filter_date:
                query = PTR_CTE_ALL + """
                SELECT f."Voltage_Rating", f."PTR_Capacity", f."Manufacturer", f."ManufSerialNo", f."YoM", f."Doc",
                    COALESCE(NULLIF(l.maxload,'')::FLOAT, 0) AS max_load,
                    COALESCE(NULLIF(l.minload,'')::FLOAT, 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    TO_CHAR(l.loaddate, 'DD-MM-YYYY') AS loaddate, f.sno
                FROM filtered_ptrs f
                LEFT JOIN "SubStationLoad" l ON l.ss_id = %s AND f.sno = l.sno AND l.loaddate::DATE = %s::DATE
                ORDER BY NULLIF(SPLIT_PART(f."Voltage_Rating",'/',1),'')::INT DESC NULLS LAST, f."PTR_Capacity"::INT DESC NULLS LAST
                """
                params     = [ss_id, ss_id, filter_date]
                show_graph = False

            elif single_prev_day:
                query = PTR_CTE_ALL + """
                SELECT f."Voltage_Rating", f."PTR_Capacity", f."Manufacturer", f."ManufSerialNo", f."YoM", f."Doc",
                    COALESCE(NULLIF(l.maxload,'')::FLOAT, 0) AS max_load,
                    COALESCE(NULLIF(l.minload,'')::FLOAT, 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    TO_CHAR(l.loaddate, 'DD-MM-YYYY') AS loaddate, f.sno
                FROM filtered_ptrs f
                LEFT JOIN "SubStationLoad" l ON l.ss_id = %s AND f.sno = l.sno AND l.loaddate::DATE = %s::DATE
                ORDER BY NULLIF(SPLIT_PART(f."Voltage_Rating",'/',1),'')::INT DESC NULLS LAST
                """
                params     = [ss_id, ss_id, single_prev_day]
                show_graph = False

            else:
                # Overall peak per PTR
                query = PTR_CTE_ALL + """
                SELECT f."Voltage_Rating", f."PTR_Capacity", f."Manufacturer", f."ManufSerialNo", f."YoM", f."Doc",
                    COALESCE(MAX(NULLIF(l.maxload,'')::FLOAT), 0) AS max_load,
                    COALESCE(MAX(NULLIF(l.minload,'')::FLOAT), 0) AS min_load,
                    TO_CHAR(
                        (SELECT l2.loaddate::DATE FROM "SubStationLoad" l2
                         WHERE l2.ss_id = %s AND l2.sno = f.sno
                         ORDER BY NULLIF(l2.maxload,'')::FLOAT DESC NULLS LAST LIMIT 1), 'DD-MM-YYYY'
                    ) AS peak_date, f.sno
                FROM filtered_ptrs f
                LEFT JOIN "SubStationLoad" l ON l.ss_id = %s AND f.sno = l.sno
                GROUP BY f.sno, f."PTR_Capacity", f."Voltage_Rating", f."Manufacturer", f."ManufSerialNo", f."YoM", f."Doc"
                ORDER BY NULLIF(SPLIT_PART(f."Voltage_Rating",'/',1),'')::INT DESC NULLS LAST, max_load DESC
                """
                params     = [ss_id, ss_id, ss_id]
                show_graph = False

            df = pd.read_sql(query, conn, params=params)
            if df.empty:
                return jsonify({"type": "text", "reply": "⚠️ No PTR data found"})

            return jsonify({"type": "table", "data": df_to_records(df), "chart": None})

        # ── LIST SUBSTATIONS ──────────────────────────────────────────────────
        elif msg.startswith("list substations"):
            filters_part  = msg[len("list substations"):].strip()
            circle_match  = re.search(r'circle:(\S+)',  filters_part)
            zone_match    = re.search(r'zone:(\S+)',    filters_part)
            voltage_match = re.search(r'voltage:(\S+)', filters_part)

            where_clauses = []
            params        = []

            if circle_match:
                where_clauses.append("LOWER(circle) LIKE %s")
                params.append(f"%{circle_match.group(1).lower()}%")
            if zone_match:
                where_clauses.append("LOWER(zone) LIKE %s")
                params.append(f"%{zone_match.group(1).lower()}%")

            where_sql = ("WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
            df_list   = pd.read_sql(
                f"SELECT ss_id, sub_station_name, zone, circle FROM slis_substationdata {where_sql} ORDER BY sub_station_name",
                conn, params=params
            )

            if voltage_match and not df_list.empty:
                target = voltage_match.group(1).lower().replace("kv", "").strip()
                def _has_v(name):
                    prefix = name.lower().split("kv")[0]
                    return target in re.split(r'[/\s]+', prefix)
                df_list = df_list[df_list["sub_station_name"].apply(_has_v)]

            if df_list.empty:
                return jsonify({"type": "text", "reply": "❌ No substations found. Type 'help'"})

            return jsonify({"type": "table", "data": df_to_records(df_list), "chart": None,
                            "message": f"📋 {len(df_list)} substation(s) found"})

        # ── MASTER INFO ───────────────────────────────────────────────────────
        elif "master info" in msg:
            df_master = pd.read_sql("""
                SELECT s.ss_id, s.sub_station_name, s.zone, s.circle, COUNT(c.sno) AS ptr_count
                FROM slis_substationdata s
                LEFT JOIN capacity_new c ON s.ss_id = c.ss_id
                WHERE s.ss_id = %s
                GROUP BY s.ss_id, s.sub_station_name, s.zone, s.circle
            """, conn, params=[ss_id])

            if df_master.empty:
                return jsonify({"type": "text", "reply": "❌ Substation not found"})

            row   = df_master.iloc[0]
            reply = (f"🏭 **{row['sub_station_name']}**\n\n"
                     f"• Zone: {row['zone']}\n• Circle: {row['circle']}\n"
                     f"• Power Transformers: {row['ptr_count']}")
            return jsonify({"type": "text", "reply": reply})

        # ── HELP ──────────────────────────────────────────────────────────────
        elif "help" in msg:
            return jsonify({"type": "text", "reply": (
                "📋 Commands:\n\n"
                "STATION MAX:\n"
                "• station max <name>\n"
                "• station max <name> yesterday\n"
                "• station max <name> last 7 days\n"
                "• station max <name> april\n"
                "• station max <name> this month\n"
                "• station max <name> last week\n"
                "• station max <name> 2025\n\n"
                "PTR DETAILS:\n"
                "• ptr <name>\n"
                "• ptr <name> 20.04.2026\n"
                "• ptr <name> yesterday\n\n"
                "MASTER INFO:\n"
                "• master info <name>\n\n"
                "SUBSTATION LISTS:\n"
                "• list substations\n"
                "• list substations circle:<name>\n"
                "• list substations zone:<name>\n"
                "• list substations voltage:<kv>"
            )})

        return jsonify({"type": "text", "reply": "❌ Not understood. Type 'help'"})

    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"type": "text", "reply": "❌ Server error."})
    finally:
        if conn:
            conn.close()


# ─── EXPORT ───────────────────────────────────────────────────────────────────
@app.route("/export", methods=["POST"])
def export_excel():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401

    data      = request.json
    ss_ids    = data.get("ss_ids", [])
    from_date = data.get("from_date")
    to_date   = data.get("to_date")

    conn = get_conn()
    if ss_ids:
        placeholders = ",".join(["%s"] * len(ss_ids))
        df = pd.read_sql(
            f'SELECT * FROM "SubStationLoad" WHERE ss_id IN ({placeholders}) AND loaddate BETWEEN %s AND %s',
            conn, params=list(ss_ids) + [from_date, to_date]
        )
    else:
        df = pd.read_sql(
            'SELECT * FROM "SubStationLoad" WHERE loaddate BETWEEN %s AND %s',
            conn, params=[from_date, to_date]
        )
    conn.close()

    output = io.BytesIO()
    df.to_excel(output, index=False)
    output.seek(0)
    return send_file(output, download_name="load_data.xlsx", as_attachment=True)


# ═══════════════════════════════════════════════════════════════════════════════
# NEW ROUTES
# ═══════════════════════════════════════════════════════════════════════════════

# ─── DAILY ENTRY ──────────────────────────────────────────────────────────────
@app.route("/daily-entry", methods=["GET", "POST"])
def daily_entry():
    if not logged_in():
        return redirect(url_for("login"))
    if not is_field_user():
        return redirect(url_for("dashboard"))

    ss_id = session.get("ss_id")
    conn  = get_conn()

    def _render(success=None, error=None, selected_date=None):
        # Which date's entries to show/prefill — default to today
        target_date = selected_date or request.values.get("date") or datetime.today().strftime("%Y-%m-%d")

        df_ptrs = pd.read_sql(
            '''
            SELECT
                c.sno, c.ss_id, c.ss_name, c."PTR_Capacity", c."Voltage_Rating",
                c."Manufacturer", c."ManufSerialNo",
                l.maxload, l.loadtime, l.minload, l.min_loadtime
            FROM capacity_new c
            LEFT JOIN "SubStationLoad" l
                ON c.ss_id = l.ss_id AND c.sno = l.sno AND l.loaddate = %s
            WHERE c.ss_id = %s
            ORDER BY
                NULLIF(SPLIT_PART(c."Voltage_Rating", '/', 1), '')::INT DESC NULLS LAST,
                NULLIF(c."PTR_Capacity", '')::INT DESC NULLS LAST,
                c.sno
            ''',
            conn, params=[target_date, ss_id]
        )
        conn.close()

        # Clean time values to HH:MM in case they carry seconds ("14:30:00")
        for col in ("loadtime", "min_loadtime"):
            df_ptrs[col] = df_ptrs[col].apply(
                lambda v: str(v)[:5] if v not in (None, "") and not pd.isnull(v) else None
            )

        return render_template("daily_entry.html",
            ptrs          = df_to_records(df_ptrs),
            ss_name       = session.get("ss_name", ""),
            success       = success,
            error         = error,
            selected_date = target_date
        )

    if request.method == "GET":
        return _render()

    # POST — upsert every PTR that has at least one value entered
    try:
        cur  = conn.cursor()
        form = request.form
        loaddate = form.get("loaddate")
        remarks  = _norm(form.get("remarks"))

        if not loaddate:
            return _render(error="Load date is required")

        cur.execute(
            'SELECT sno, ss_name, "PTR_Capacity", "Voltage_Rating" '
            'FROM capacity_new WHERE ss_id = %s' + PTR_ORDER, (ss_id,)
        )
        ptrs = cur.fetchall()

        saved = 0
        for sno, ss_name, ptr_cap, volt in ptrs:
            maxload  = _norm(form.get(f"maxload_{sno}"))
            loadtime = _norm(form.get(f"loadtime_{sno}"))
            minload  = _norm(form.get(f"minload_{sno}"))
            min_time = _norm(form.get(f"min_loadtime_{sno}"))
            if not any([maxload, loadtime, minload, min_time]):
                continue
            next_id = _next_available_id(cur)
            cur.execute(UPSERT_SQL, (
                next_id,sno, ss_id, ss_name, ptr_cap, volt,
                maxload, minload, min_time, loaddate, loadtime,
                session.get("mobile_no"), remarks
            ))
            saved += 1

        if saved == 0:
            conn.rollback()
            return _render(error="Enter at least one value before saving", selected_date=loaddate)

        conn.commit()
        return _render(
            success=f"Saved values for {saved} PTR(s). You can fill the rest later — they'll be added to the same rows.",
            selected_date=loaddate
        )

    except Exception as e:
        conn.rollback()
        print("DAILY ENTRY ERROR:", e)
        return _render(error="Failed to save. Please try again.")
 
# ─── TABLE VIEWS ──────────────────────────────────────────────────────────────
@app.route("/table/substationload")
def table_substationload():
    if not logged_in():
        return redirect(url_for("login"))
    conn = get_conn()
    # Field users only see load entries for their own substation.
    # Admin and officers ("dashboard users") see every substation's rows.
    if session.get("role") == "field":
        df = pd.read_sql(
            'SELECT * FROM "SubStationLoad" WHERE ss_id = %s ORDER BY id DESC',
            conn, params=[session.get("ss_id")]
        )
    else:
        df = pd.read_sql('SELECT * FROM "SubStationLoad" ORDER BY id DESC', conn)
    conn.close()
    df["loaddate"] = pd.to_datetime(df["loaddate"]).dt.strftime("%d-%m-%Y")
    df["created_on"] = pd.to_datetime(df["created_on"]).dt.strftime("%d-%m-%Y %H:%M:%S")
    # FIX: created_by mixes numeric phone numbers with plain usernames (e.g. "admin"),
    # and has some NULLs — pandas responds by casting the whole column to float64,
    # which prints whole numbers as "8712463403.0". Strip the trailing ".0" only
    # for genuinely numeric-looking values; leave text usernames untouched.
    def _clean_id(x):
        if pd.isnull(x):
            return ""
        s = str(x)
        if s.endswith(".0"):
            try:
                return str(int(float(s)))
            except (ValueError, TypeError):
                return s
        return s
    df["created_by"] = df["created_by"].apply(_clean_id)
   
    return render_template(
        "table_substationload.html",
        rows=df.to_dict(orient="records"),
        columns=list(df.columns),
        can_edit=can_edit_load_data(),
    )


@app.route("/table/capacity")
def table_capacity():
    if not logged_in():
        return redirect(url_for("login"))
    conn = get_conn()
    df   = pd.read_sql('SELECT * FROM capacity_new ORDER BY ss_id, sno', conn)
    conn.close()
    return render_template("table_capacity.html", rows=df.to_dict(orient="records"), columns=list(df.columns))


@app.route("/table/substations")
def table_substations():
    if not logged_in():
        return redirect(url_for("login"))
    conn = get_conn()
    df   = pd.read_sql('SELECT * FROM slis_substationdata ORDER BY ss_id', conn)
    conn.close()
    # FIX: mobile_no has some NULLs, which forces pandas to cast the whole column
    # to float64 — whole numbers then print as "8712463332.0", and true NULLs print
    # as the literal string "nan" once Jinja/str() touches them. Clean both cases.
    def _clean_id(x):
        if pd.isnull(x):
            return ""
        s = str(x)
        if s.endswith(".0"):
            try:
                return str(int(float(s)))
            except (ValueError, TypeError):
                return s
        return s
    df["mobile_no"] = df["mobile_no"].apply(_clean_id)
    return render_template("table_substations.html", rows=df.to_dict(orient="records"), columns=list(df.columns))


@app.route("/api/admin/update_load_entry/<int:entry_id>", methods=["POST"])
def update_load_entry(entry_id):
    """Edit an existing SubStationLoad row from the Load Data table page.
    Every editable column on the row is accepted here (id is excluded since
    it's the primary key used to locate the row, not something to change)."""
    if not can_edit_load_data():
        return jsonify({"success": False, "error": "Unauthorized"}), 403
    data = request.get_json(force=True)
    conn = get_conn()
    try:
        cur = conn.cursor()
        cur.execute("""
            UPDATE "SubStationLoad"
            SET sno = %s, ss_id = %s, ss_name = %s, "PTR_Capacity" = %s, "Voltage_Rating" = %s,
                maxload = %s, minload = %s, min_loadtime = %s, loaddate = %s, loadtime = %s,
                created_by = %s, created_on = %s, remarks = %s
            WHERE id = %s
        """, (
            data.get("sno"), data.get("ss_id"), data.get("ss_name"),
            data.get("PTR_Capacity"), data.get("Voltage_Rating"),
            data.get("maxload"), data.get("minload"), data.get("min_loadtime"),
            data.get("loaddate"), data.get("loadtime"),
            data.get("created_by"), data.get("created_on"),
            data.get("remarks", ""), 
            entry_id
        ))
        conn.commit()
        conn.close()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        conn.close()
        print("UPDATE LOAD ENTRY ERROR:", e)
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/admin/delete_load_entry/<int:entry_id>", methods=["DELETE"])
def delete_load_entry(entry_id):
    """Delete a SubStationLoad row from the Load Data table page."""
    if not can_edit_load_data():
        return jsonify({"success": False, "error": "Unauthorized"}), 403
    conn = get_conn()
    try:
        cur = conn.cursor()
        cur.execute('DELETE FROM "SubStationLoad" WHERE id = %s', (entry_id,))
        conn.commit()
        conn.close()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        conn.close()
        print("DELETE LOAD ENTRY ERROR:", e)
        return jsonify({"success": False, "error": str(e)}), 500


# ─── ADMIN SETTINGS ───────────────────────────────────────────────────────────
@app.route("/admin/settings", methods=["GET"])
def admin_settings():
    if not logged_in():
        return redirect(url_for("login"))
    if not is_admin():
        return redirect(url_for("dashboard"))

    conn   = get_conn()
    df     = pd.read_sql("SELECT ss_id, dist_name, sub_station_name, voltage, mobile_no, zone, circle FROM slis_substationdata ORDER BY ss_id", conn)
    df_off = pd.read_sql("SELECT id, username, is_admin, is_first_login, password_expiry FROM users ORDER BY username", conn)
    df_zones   = pd.read_sql("SELECT DISTINCT zone FROM slis_substationdata ORDER BY zone", conn)
    df_circles = pd.read_sql("SELECT DISTINCT circle FROM slis_substationdata ORDER BY circle", conn)
    conn.close()

    # FIX: mobile_no has some NULLs, forcing pandas to cast the whole column to
    # float64 — whole numbers print as "8712463038.0" and true NULLs print as "nan".
    def _clean_id(x):
        if pd.isnull(x):
            return ""
        s = str(x)
        if s.endswith(".0"):
            try:
                return str(int(float(s)))
            except (ValueError, TypeError):
                return s
        return s
    df["mobile_no"] = df["mobile_no"].apply(_clean_id)

    return render_template("admin_settings.html",
        substations = df.to_dict(orient="records"),
        officers    = df_off.to_dict(orient="records"),
        zones       = df_zones["zone"].tolist(),
        circles     = df_circles["circle"].tolist()
    )


@app.route("/admin/add_user", methods=["POST"])
def admin_add_user():
    if not logged_in() or not is_admin():
        return redirect(url_for("login"))

    form      = request.form
    user_type = form.get("user_type", "field")
    conn = get_conn()
    cur  = conn.cursor()

    try:
        if user_type == "officer":
            # Dashboard Officer — goes into the `users` table (view-only role),
            # same table admin/officer logins use, not slis_substationdata.
            username = form.get("username", "").strip()
            password = form.get("officer_password", "").strip() or "password@123"
            hashed   = generate_password_hash(password)
            cur.execute("""
                INSERT INTO users (username, password_hash, is_admin, is_first_login)
                VALUES (%s, %s, FALSE, TRUE)
            """, (username, hashed))
        else:
            cur.execute("""
                INSERT INTO slis_substationdata
                    (ss_id, dist_code, dist_name, sub_station_name, voltage, mobile_no, password, zone, circle)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            """, (
                form.get("ss_id"), form.get("dist_code"), form.get("dist_name"),
                form.get("sub_station_name"), form.get("voltage"),
                form.get("mobile_no"), form.get("password"),
                form.get("zone"), form.get("circle")
            ))
        conn.commit()
        conn.close()
        return redirect(url_for("admin_settings"))
    except Exception as e:
        conn.rollback()
        conn.close()
        return redirect(url_for("admin_settings"))

@app.route("/api/admin/officers", methods=["GET"])
def api_admin_officers():
    if not logged_in():
        return jsonify({"error": "Unauthorized"}), 403
    conn = get_conn()
    df = pd.read_sql("SELECT id, username, is_first_login FROM users ORDER BY username", conn)
    conn.close()
    return jsonify(df_to_records(df))
@app.route("/admin/delete_user/<int:ss_id>", methods=["POST"])
def admin_delete_user(ss_id):
    if not logged_in() or not is_admin():
        return redirect(url_for("login"))

    conn = get_conn()
    cur  = conn.cursor()
    cur.execute("DELETE FROM slis_substationdata WHERE ss_id = %s", (ss_id,))
    conn.commit()
    conn.close()
    return redirect(url_for("admin_settings"))



@app.route("/api/capacity")
def api_capacity():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df = pd.read_sql('SELECT c.sno, c.ss_id, c.ss_name, c."PTR_Capacity", c."Voltage_Rating", c."Manufacturer", c."ManufSerialNo", c."YoM", c."Doc" FROM capacity_new c ORDER BY c.ss_id, c.sno', conn)
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500
@app.route("/api/load_data_all")
def api_load_data_all():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        # The Flutter app authenticates with one shared static token (no
        # per-user session), so it tells us who's asking via query params
        # sourced from its own AuthProvider. Field users only get their own
        # substation's rows; admin/officer (no role or role != field) get all.
        role  = request.args.get("role", "")
        ss_id = request.args.get("ss_id", "")
        if role == "field" and ss_id:
            df = pd.read_sql(
                'SELECT * FROM "SubStationLoad" WHERE ss_id = %s ORDER BY id DESC',
                conn, params=[ss_id]
            )
        else:
            df = pd.read_sql('SELECT * FROM "SubStationLoad" ORDER BY id DESC', conn)
        conn.close()
        df["loaddate"] = df["loaddate"].astype(str)
        df["created_on"] = df["created_on"].astype(str)
        # Same NaN/".0" cleanup applied to the website's Load Data table —
        # created_by mixes numeric mobile numbers with plain usernames and has
        # some NULLs, which forces pandas to cast the whole column to float64.
        def _clean_id(x):
            if pd.isnull(x):
                return ""
            s = str(x)
            if s.endswith(".0"):
                try:
                    return str(int(float(s)))
                except (ValueError, TypeError):
                    return s
            return s
        df["created_by"] = df["created_by"].apply(_clean_id)
        
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500
# ─── API ENDPOINTS (for Flutter app) ─────────────────────────────────────────
@app.route("/api/login", methods=["POST"])
def api_login():
    data     = request.get_json(force=True)
    username = data.get("username", "").strip()
    password = data.get("password", "").strip()

    if not username or not password:
        return jsonify({"success": False, "error": "Username and password required"}), 400

    # Admin
    if username == "admin" and password == "admin@123":
        return jsonify({"success": True, "role": "admin", "user": "admin", "ss_id": None, "ss_name": None})

    conn = None
    try:
        conn = get_conn()
        cur  = conn.cursor()

        # Officers
        cur.execute("SELECT * FROM users WHERE username = %s", (username,))
        cols = [d[0] for d in cur.description]
        row  = cur.fetchone()

        if row:
            user = dict(zip(cols, row))
            if user.get("is_locked"):
                conn.close()
                return jsonify({"success": False, "error": "Account locked. Contact admin"}), 403
            if check_password_hash(user["password_hash"], password):
                cur.execute("UPDATE users SET failed_attempts=0, is_locked=FALSE, lock_time=NULL WHERE username=%s", (username,))
                conn.commit()
                conn.close()
                role = "admin" if user.get("is_admin") else "officer"
                return jsonify({"success": True, "role": role, "user": username, "ss_id": None, "ss_name": None,
                                "first_login": bool(user.get("is_first_login"))})
            else:
                attempts = (user.get("failed_attempts") or 0) + 1
                if attempts >= 3:
                    cur.execute("UPDATE users SET failed_attempts=%s, is_locked=TRUE, lock_time=NOW() WHERE username=%s", (attempts, username))
                else:
                    cur.execute("UPDATE users SET failed_attempts=%s WHERE username=%s", (attempts, username))
                conn.commit()
                conn.close()
                return jsonify({"success": False, "error": f"Invalid credentials ({attempts}/3)"}), 401

        # Field users
        cur.execute("SELECT ss_id, sub_station_name, mobile_no, password FROM slis_substationdata WHERE mobile_no = %s", (username,))
        cols2 = [d[0] for d in cur.description]
        row2  = cur.fetchone()

        if row2:
            fu = dict(zip(cols2, row2))
            conn.close()
            if fu["password"] == password:
                return jsonify({"success": True, "role": "field", "user": username,
                                "ss_id": fu["ss_id"], "ss_name": fu["sub_station_name"]})
            return jsonify({"success": False, "error": "Invalid credentials"}), 401

        conn.close()
        return jsonify({"success": False, "error": "User not found"}), 404

    except Exception as e:
        if conn:
            conn.close()
        print("API LOGIN ERROR:", e)
        return jsonify({"success": False, "error": "Server error"}), 500


@app.route("/api/ptrs/<int:ss_id>")
def api_ptrs(ss_id):
    """Get PTRs for a substation — highest primary voltage first.
    Optionally prefills today's (or ?date=YYYY-MM-DD) existing SubStationLoad
    values, same as the website's Daily Entry page."""
    try:
        target_date = request.args.get("date") or datetime.today().strftime("%Y-%m-%d")
        conn = get_conn()
        df = pd.read_sql(
            '''
            SELECT
                c.sno, c.ss_id, c.ss_name, c."PTR_Capacity", c."Voltage_Rating",
                c."Manufacturer", c."ManufSerialNo",
                l.maxload, l.loadtime, l.minload, l.min_loadtime
            FROM capacity_new c
            LEFT JOIN "SubStationLoad" l
                ON c.ss_id = l.ss_id AND c.sno = l.sno AND l.loaddate = %s
            WHERE c.ss_id = %s
            ORDER BY
                NULLIF(SPLIT_PART(c."Voltage_Rating", '/', 1), '')::INT DESC NULLS LAST,
                NULLIF(c."PTR_Capacity", '')::INT DESC NULLS LAST,
                c.sno
            ''',
            conn, params=[target_date, ss_id]
        )
        conn.close()

        # Clean time values to HH:MM in case they carry seconds
        for col in ("loadtime", "min_loadtime"):
            df[col] = df[col].apply(
                lambda v: str(v)[:5] if v not in (None, "") and not pd.isnull(v) else None
            )

        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/submit_entry", methods=["POST"])
def api_submit_entry():
    if not logged_in():
        return jsonify({"success": False, "error": "Not logged in"}), 401
 
    data    = request.get_json(force=True)
    entries = data.get("entries", [])
 
    # Keep only entries that actually contain a value
    entries = [
        e for e in entries
        if any([_norm(e.get("maxload")), _norm(e.get("loadtime")),
                _norm(e.get("minload")), _norm(e.get("min_loadtime"))])
    ]
    if not entries:
        return jsonify({"success": False, "error": "Enter at least one value before saving"}), 400
 
    conn = get_conn()
    cur  = conn.cursor()
    try:
        for e in entries:
            if not e.get("sno") or not e.get("loaddate"):
                conn.rollback(); conn.close()
                return jsonify({"success": False, "error": "sno and loaddate are required"}), 400
            next_id = _next_available_id(cur) 
            cur.execute(UPSERT_SQL, (
                next_id, e.get("sno"), e.get("ss_id"), e.get("ss_name"),
                
                e.get("PTR_Capacity"), e.get("Voltage_Rating"),
                _norm(e.get("maxload")), _norm(e.get("minload")),
                _norm(e.get("min_loadtime")), e.get("loaddate"),
                _norm(e.get("loadtime")),
                e.get("created_by"), _norm(e.get("remarks"))
            ))
 
        conn.commit()
        conn.close()
        return jsonify({"success": True, "saved": len(entries),
                        "message": f"Saved values for {len(entries)} PTR(s)"})
    except Exception as e:
        conn.rollback()
        conn.close()
        print("API SUBMIT ERROR:", e)
        return jsonify({"success": False, "error": str(e)}), 500
 
 
 
@app.route("/api/load_data", methods=["POST"])
def api_load_data():
    """Load data for Flutter dashboard."""
    try:
        data      = request.get_json(force=True)
        ss_ids    = data.get("ss_ids", [])
        from_date = data.get("from_date")
        to_date   = data.get("to_date")

        if not ss_ids:
            return jsonify([])

        placeholders = ",".join(["%s"] * len(ss_ids))
        conn = get_conn()
        df   = pd.read_sql(
            f'SELECT * FROM "SubStationLoad" WHERE ss_id IN ({placeholders}) AND loaddate BETWEEN %s AND %s ORDER BY loaddate DESC',
            conn, params=list(ss_ids) + [from_date, to_date]
        )
        conn.close()
        df["loaddate"]   = df["loaddate"].astype(str)
        df["created_on"] = df["created_on"].astype(str)
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/substations")
def api_substations():
    """All substations for Flutter filter dropdowns."""
    try:
        conn = get_conn()
        df   = pd.read_sql("SELECT ss_id, sub_station_name, zone, circle FROM slis_substationdata ORDER BY sub_station_name", conn)
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/chat", methods=["POST"])
def api_chat():
    """Chatbot for Flutter app — delegates to same logic as web chat."""
    return chat()
@app.route("/api/admin/change_password", methods=["POST"])
def api_admin_change_password():
    if not logged_in():
        return jsonify({"error": "Unauthorized"}), 403
    data = request.json
    ss_id = data.get("ss_id")
    new_pass = data.get("new_password")
    conn = get_conn()
    cur = conn.cursor()
    if ss_id.startswith("officer_"):
        officer_id = ss_id.replace("officer_", "")
        hashed = generate_password_hash(new_pass)
        cur.execute("UPDATE users SET password_hash=%s, is_first_login=FALSE WHERE id=%s", (hashed, officer_id))
    else:
        field_id = ss_id.replace("field_", "")
        cur.execute("UPDATE slis_substationdata SET password=%s WHERE ss_id=%s", (new_pass, field_id))
    conn.commit()
    conn.close()
    return jsonify({"success": True})


if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=8080)