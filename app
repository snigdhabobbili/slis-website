from flask import Flask, render_template, request, jsonify, redirect, url_for, session, send_file
import pyodbc
import pandas as pd
from captcha.image import ImageCaptcha
import random
import string
import io
import os
import re
import requests
from datetime import datetime, timedelta
import secrets
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__, template_folder="templates", static_folder="static")

# ─── SECRETS (never hardcode — set these in the environment) ──────────────────
# Windows/Apache note: mod_wsgi services do NOT inherit `setx` variables.
# Set them in httpd.conf with:  SetEnv SLIS_SECRET_KEY "..."
# or in the WSGI file with:    os.environ.setdefault("SLIS_SECRET_KEY", "...")
app.secret_key = os.environ.get("SLIS_SECRET_KEY") or secrets.token_hex(32)

# Shared token for the Flutter app. This is an AUTHENTICATION token only —
# it no longer grants admin rights (see is_admin()). Anyone who decompiles
# the APK can read it, so it must not be a privilege grant.
app.config["API_TOKEN"] = os.environ.get("SLIS_API_TOKEN", "")


# ─── DATABASE CONNECTION ──────────────────────────────────────────────────────
DB_SERVER   = os.environ.get("SLIS_DB_SERVER",   "172.17.4.185,1433")
DB_NAME     = os.environ.get("SLIS_DB_NAME",     "SubstationLoad")
DB_USER     = os.environ.get("SLIS_DB_USER",     "dashboard_user")
DB_PASSWORD = os.environ.get("SLIS_DB_PASSWORD", "")


def get_conn():
    return pyodbc.connect(
        "DRIVER={ODBC Driver 17 for SQL Server};"
        f"SERVER={DB_SERVER};"
        f"DATABASE={DB_NAME};"
        f"UID={DB_USER};"
        f"PWD={DB_PASSWORD};"
    )


def df_to_records(df):
    """NaN/NaT-safe -> JSON. pandas turns SQL NULLs into NaN, which
    json.dumps can't serialize properly."""
    return df.astype(object).where(pd.notnull(df), None).to_dict(orient="records")


def _clean_id(x):
    """Some ID/mobile columns mix numbers and NULLs, which forces pandas to
    cast the whole column to float64 -> prints as '8712463403.0' or 'nan'."""
    if pd.isnull(x):
        return ""
    s = str(x)
    if s.endswith(".0"):
        try:
            return str(int(float(s)))
        except (ValueError, TypeError):
            return s
    return s


# ─── DAILY ENTRY CONSTANTS (SQL Server) ───────────────────────────────────────
PTR_ORDER = (
    " ORDER BY TRY_CAST(LEFT(Voltage_Rating, CHARINDEX('/', Voltage_Rating + '/') - 1) AS INT) DESC, sno"
)

# SQL Server has no native UPSERT — use MERGE. next_id is computed by the
# caller (see _next_available_id) and passed in.
#
# HOLDLOCK on the MERGE target is required: without it two concurrent field
# users can both compute the same next_id and both take the NOT MATCHED
# branch, causing a duplicate-key error (or duplicate rows if no PK exists).
UPSERT_SQL = """
MERGE INTO SubStationLoad WITH (HOLDLOCK) AS target
USING (SELECT ? AS ss_id, ? AS sno, ? AS loaddate) AS src
    ON target.ss_id = src.ss_id AND target.sno = src.sno AND target.loaddate = src.loaddate
WHEN MATCHED THEN
    UPDATE SET
        maxload      = COALESCE(NULLIF(?, ''), target.maxload),
        loadtime     = COALESCE(NULLIF(?, ''), target.loadtime),
        minload      = COALESCE(NULLIF(?, ''), target.minload),
        min_loadtime = COALESCE(NULLIF(?, ''), target.min_loadtime),
        remarks      = COALESCE(NULLIF(?, ''), target.remarks),
        created_on   = GETDATE()
WHEN NOT MATCHED THEN
    INSERT (id, sno, ss_id, ss_name, PTR_Capacity, Voltage_Rating, maxload, minload,
            min_loadtime, loaddate, loadtime, created_by, created_on, remarks)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, GETDATE(), ?);
"""
# Param order for UPSERT_SQL (23 placeholders total):
#   MATCH: ss_id, sno, loaddate
#   UPDATE: maxload, loadtime, minload, min_loadtime, remarks
#   INSERT: id, sno, ss_id, ss_name, PTR_Capacity, Voltage_Rating, maxload, minload,
#           min_loadtime, loaddate, loadtime, created_by, remarks


def _norm(v):
    """'' / whitespace -> None so empty fields never overwrite saved values."""
    if v is None:
        return None
    v = str(v).strip()
    return v if v else None


def _next_available_id(cursor, table="SubStationLoad"):
    """Find the smallest unused id (fills gaps from deleted rows).

    NOTE: this is only safe because every caller runs it inside the same
    transaction as the MERGE, and the MERGE holds a range lock (HOLDLOCK).
    If you can alter the schema, make `id` an IDENTITY column and delete
    this function plus `id` from the INSERT column list above."""
    cursor.execute(f"SELECT COUNT(*) FROM {table} WITH (UPDLOCK, HOLDLOCK)")
    if cursor.fetchone()[0] == 0:
        return 1
    cursor.execute(f"""
        SELECT MIN(t1.id + 1)
        FROM {table} t1 WITH (UPDLOCK, HOLDLOCK)
        LEFT JOIN {table} t2 ON t1.id + 1 = t2.id
        WHERE t2.id IS NULL
    """)
    result = cursor.fetchone()[0]
    return result if result else 1


def upsert_load_row(cursor, next_id, sno, ss_id, ss_name, ptr_cap, volt,
                    maxload, minload, min_time, loaddate, loadtime,
                    created_by, remarks):
    cursor.execute(
        UPSERT_SQL,
        ss_id, sno, loaddate,                                               # MATCH
        maxload, loadtime, minload, min_time, remarks,                      # UPDATE
        next_id, sno, ss_id, ss_name, ptr_cap, volt,                        # INSERT
        maxload, minload, min_time, loaddate, loadtime, created_by, remarks  # INSERT (cont.)
    )


# ─── LLM-BASED FREE-TEXT NORMALIZATION (Groq, free tier) ──────────────────────
# Converts ANY way a user phrases a question into the exact keyword style the
# existing regex engine below already understands (e.g. "station max", "ptr",
# "20 april 2026", "last 7 days"). The regex engine itself is NOT changed —
# this just rewrites the sentence before it reaches that engine.
#
# The key MUST come from the environment. Under Apache/mod_wsgi, set it with
# SetEnv in httpd.conf or os.environ.setdefault() in the .wsgi file — Windows
# services do not inherit `setx` variables.
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_URL     = "https://api.groq.com/openai/v1/chat/completions"
GROQ_MODEL   = "llama-3.3-70b-versatile"

if not GROQ_API_KEY:
    print("⚠️  GROQ_API_KEY is not set — chatbot will fall back to plain keyword matching only.")
else:
    print(f"✅ GROQ_API_KEY loaded (starts with: {GROQ_API_KEY[:8]}...)")

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
- "station max" = the peak/highest/maximum load of a substation (use this exact phrase whenever the user asks about peak load, highest load, max load, maximum demand, busiest reading, etc.)
- "ptr" = power transformer details (capacity, voltage rating, manufacturer, serial number, year of manufacture). Use this exact word whenever the user asks about transformer(s), PTR, power transformer info, equipment details, transformer specs, etc.
- "master info" = substation master details for ONE named substation: which zone, which circle, or how many power transformers it has. Use this exact phrase whenever the user names a SPECIFIC substation and asks about zone, circle, region, division, or "how many transformers/PTRs does X have". "master info" is always standalone — never combine it with "station max" or "ptr", and never add a date phrase to it.
- "list substations" = a request for MULTIPLE substations or a count of substations, NOT about one named substation. Use this whenever the user asks for "all substations", "total substations", "list of substations", "how many substations", or substations filtered by circle/zone/voltage WITHOUT naming one specific substation. Optionally append filters in the exact form "circle:<name>", "zone:<name>", "voltage:<class>" (e.g. "voltage:400" for 400KV, "voltage:220" for 220KV, "voltage:132" for 132KV, "voltage:33" for 33KV, "voltage:11" for 11KV) — only include a filter the user actually asked for. Examples of filter values: circle:sangareddy, zone:rural, voltage:400. If no filter is mentioned, output just "list substations" with no filters.
- "station max" and "ptr" can appear together, e.g. "station max ptr" if the user wants peak load AND the transformer that produced it.
- Substation name: extract ONLY the bare proper-noun name (e.g. "gachibowli", "hyderabad", "warangal"). NEVER include surrounding question words, verbs, or filler — strip ALL of: "what is", "what was", "can you tell me", "show me", "give me", "tell me", "the", "of", "for", "at", "demand", "load", "value", "reading", "is", "was", "please", "kindly", "which", "how many". The substation name is normally the LAST proper noun in the sentence, often followed by the word "substation" which you should also drop.
- Dates: convert any date the user mentions into "DD Month YYYY" format (e.g. "20 april 2026") or keep relative terms as-is: "yesterday", "today", "last N days", "last week", "week before last", "this month", "last month", "this year", "last year", a 4-digit year alone, or a month name alone. If NO date is mentioned at all, output NO date phrase (do not invent one).
- "last week" = the previous calendar week (Monday–Sunday before the current week). Use this exact phrase whenever the user says "last week", "previous week", "the week before", "past week".
- "week before last" = two calendar weeks ago. Use this exact phrase whenever the user says "week before last", "the week before last week", "two weeks ago", "last before week", "before last week".
- "last N weeks" or "last N days" where N is a word number: convert to digits (e.g. "last ten weeks" -> "last 10 weeks", "last three days" -> "last 3 days", "last three weeks" -> "last 3 weeks").
- "all dates" / "day wise" / "date wise" — keep these exact phrases if the user wants a day-by-day breakdown rather than a single peak value.
- Greetings ("hi", "hello", "hey", "good morning", etc.) and anything unrelated to substation data: output the message UNCHANGED, exactly as the user wrote it. NEVER attach a substation name to a plain greeting.

EXAMPLES:
User: "what was the highest load at hyderabad substation yesterday"
Output: station max hyderabad yesterday

User: "can you tell me the peak demand for warangal on 5th of march 2026"
Output: station max warangal 5 march 2026

User: "give me transformer info for nizamabad"
Output: ptr nizamabad

User: "show day by day max load for karimnagar last month"
Output: station max karimnagar all dates last month

User: "whats the busiest reading khammam had this year and which transformer caused it"
Output: station max ptr khammam this year

User: "what is the station max demand of gachibowli substation last week"
Output: station max gachibowli last week

User: "station maximum demand of gachibowli substation last before week"
Output: station max gachibowli week before last

User: "show me gachibowli substation demand for week before last"
Output: station max gachibowli week before last

User: "what is the maximum demand of gachibowli substation"
Output: station max gachibowli

User: "what is the station maximum demand of gachibowli substation"
Output: station max gachibowli

User: "which zone is gachibowli substation in"
Output: master info gachibowli

User: "which circle does warangal substation belong to"
Output: master info warangal

User: "how many transformers does nizamabad have"
Output: master info nizamabad

User: "please give the total substations list"
Output: list substations

User: "show me all substations data"
Output: list substations

User: "please give only sangareddy circle substations list"
Output: list substations circle:sangareddy

User: "how many substations available in rural zone"
Output: list substations zone:rural

User: "please give only 400KV substations list"
Output: list substations voltage:400

User: "hi"
Output: hi

User: "help"
Output: help
"""


def llm_normalize_message(raw_message):
    """
    Sends the user's raw free-text message to Groq to rewrite it into the
    keyword style the regex parser expects. Always falls back to the original
    message on any error (no key, no internet, rate limit, timeout) so the
    chatbot never breaks because of this step.
    """
    if not GROQ_API_KEY or not raw_message.strip():
        return raw_message

    try:
        resp = requests.post(
            GROQ_URL,
            headers={
                "Authorization": f"Bearer {GROQ_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": GROQ_MODEL,
                "messages": [
                    {"role": "system", "content": LLM_SYSTEM_PROMPT},
                    {"role": "user", "content": raw_message},
                ],
                "temperature": 0,
                "max_tokens": 60,
            },
            timeout=6,
        )
        resp.raise_for_status()
        rewritten = resp.json()["choices"][0]["message"]["content"].strip()
        rewritten = rewritten.strip('"\'')   # strip stray quotes the model adds
        print("LLM RAW:", raw_message, "→ LLM NORMALIZED:", rewritten, flush=True)
        return rewritten if rewritten else raw_message
    except Exception as e:
        print("LLM NORMALIZE FAILED, using raw message. Reason:", repr(e), flush=True)
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
        return "Must contain special character"
    return None


# ─── AUTH / RBAC HELPERS ─────────────────────────────────────────────────────
# The API token authenticates the Flutter client but grants NO privileges.
# Role still comes from the session (web) or from the X-Auth-Role header set
# after a successful /api/login. Admin-only routes therefore cannot be reached
# with the shared token alone.
def _api_token_ok():
    tok = request.headers.get("X-Auth-Token")
    return bool(tok) and bool(app.config.get("API_TOKEN")) and \
        secrets.compare_digest(tok, app.config["API_TOKEN"])


def logged_in():
    return "user" in session or _api_token_ok()


def current_role():
    """Role of the caller: session role for the web, or the role the mobile
    client reports alongside a valid API token."""
    if "user" in session:
        return session.get("role")
    if _api_token_ok():
        return request.headers.get("X-Auth-Role", "")
    return None


def is_admin():
    return current_role() == "admin"


def is_field_user():
    return current_role() == "field"


def is_officer():
    return current_role() == "officer"


def can_edit_load_data():
    """Field users (data entry) and admin can edit/delete Load Data rows.
    Officers (view-only) cannot."""
    return current_role() in ("admin", "field")


def caller_ss_id():
    """The substation a field caller is scoped to."""
    if "user" in session:
        return session.get("ss_id")
    return request.headers.get("X-Auth-SSID")


@app.route("/")
def home():
    return redirect(url_for("login"))


# ─── LOGIN ────────────────────────────────────────────────────────────────────
MAX_ATTEMPTS = 3
LOCK_MINUTES = 15


@app.route("/login", methods=["GET", "POST"])
def login():
    if "user" in session:
        return redirect(url_for("dashboard"))

    if request.method == "GET":
        return render_template("login.html")

    conn = None
    try:
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()

        if not username or not password:
            return render_template("login.html")

        # ── Path 1: Hardcoded bootstrap admin ──────────────────────────────
        # TODO: remove once a real admin row exists in `users`.
        if username == "admin" and password == os.environ.get("SLIS_BOOTSTRAP_ADMIN_PW", "admin@123"):
            session["user"] = "admin"
            session["role"] = "admin"
            return redirect(url_for("dashboard"))

        conn   = get_conn()
        cursor = conn.cursor()

        # ── Path 2: Dashboard users (officers/admins in `users`) ────────────
        # This must NOT early-return when empty — a field user's mobile number
        # is never in `users`, so an empty result has to fall through to
        # Path 3 below. (This is the bug that broke field login.)
        df = pd.read_sql("SELECT * FROM users WHERE username=?", conn, params=[username])

        if not df.empty:
            user            = df.iloc[0].to_dict()
            failed_attempts = user.get("failed_attempts") or 0
            is_locked       = user.get("is_locked") or 0
            lock_time       = user.get("lock_time")

            # Auto-unlock after 5 minutes
            if is_locked == 1:
                if lock_time:
                    unlock_time = lock_time + timedelta(minutes=5)
                    if datetime.now() >= unlock_time:
                        cursor.execute(
                            "UPDATE users SET failed_attempts=0, is_locked=0, lock_time=NULL WHERE username=?",
                            username
                        )
                        conn.commit()
                        failed_attempts = 0
                    else:
                        remaining = int((unlock_time - datetime.now()).total_seconds() / 60)
                        return render_template(
                            "login.html",
                            error=f"Account locked. Try again in {remaining} minutes"
                        )
                else:
                    return render_template("login.html", error="Account locked. Contact admin")

            # Wrong password
            if not check_password_hash(user["password_hash"], password):
                attempts = failed_attempts + 1
                if attempts >= MAX_ATTEMPTS:
                    cursor.execute(
                        "UPDATE users SET failed_attempts=?, is_locked=1, lock_time=GETDATE() WHERE username=?",
                        attempts, username
                    )
                    conn.commit()
                    return render_template(
                        "login.html",
                        error="Account locked after 3 attempts (Unlock after 5 min)"
                    )
                cursor.execute(
                    "UPDATE users SET failed_attempts=? WHERE username=?",
                    attempts, username
                )
                conn.commit()
                return render_template("login.html", error=f"Invalid Credentials ({attempts}/3)")

            # Success — reset counters
            cursor.execute(
                "UPDATE users SET failed_attempts=0, is_locked=0, lock_time=NULL WHERE username=?",
                username
            )
            conn.commit()

            if user.get("is_first_login"):
                session["reset_user"] = username
                return redirect(url_for("change_password"))

            # Password expiry applies to non-admin dashboard users only
            if not user.get("is_admin"):
                expiry = user.get("password_expiry")
                if expiry and expiry < datetime.now():
                    session["reset_user"] = username
                    return redirect(url_for("change_password"))

            session["user"] = username
            session["role"] = "admin" if user.get("is_admin") else "officer"
            return redirect(url_for("dashboard"))

        # ── Path 3: Field users (slis_substationdata, keyed by mobile_no) ───
        df_field = pd.read_sql(
            "SELECT ss_id, sub_station_name, mobile_no, password, zone, circle "
            "FROM slis_substationdata WHERE mobile_no=?",
            conn, params=[username]
        )

        if not df_field.empty:
            fu = df_field.iloc[0].to_dict()
            if str(fu["password"]) == password:
                session["user"]      = username
                session["role"]      = "field"
                session["ss_id"]     = fu["ss_id"]
                session["ss_name"]   = fu["sub_station_name"]
                session["mobile_no"] = username
                return redirect(url_for("dashboard"))
            return render_template("login.html", error="Invalid Credentials")

        return render_template("login.html", error="Invalid user")

    except Exception as e:
        print("LOGIN ERROR:", e)
        return "Internal Server Error", 500
    finally:
        if conn:
            conn.close()


# ─── CAPTCHA ──────────────────────────────────────────────────────────────────
@app.route("/captcha", endpoint="captcha")
def captcha():
    captcha_text = ''.join(random.choices(string.ascii_uppercase + string.digits, k=5))
    session["captcha"] = captcha_text
    image = ImageCaptcha()
    data  = image.generate(captcha_text)
    return send_file(data, mimetype='image/png')


# ─── PASSWORD RESET ───────────────────────────────────────────────────────────
@app.route("/request_reset", methods=["POST"])
def request_reset():
    username = request.json.get("username")
    conn     = get_conn()
    cursor   = conn.cursor()
    df = pd.read_sql("SELECT * FROM users WHERE username=?", conn, params=[username])
    if df.empty:
        conn.close()
        # Don't leak which usernames exist.
        return jsonify({"msg": "If that user exists, a reset token has been generated"})
    token  = secrets.token_urlsafe(32)
    expiry = datetime.now() + timedelta(minutes=15)
    cursor.execute(
        "UPDATE users SET reset_token=?, token_expiry=? WHERE username=?",
        token, expiry, username
    )
    conn.commit()
    conn.close()
    # NOTE: the token is returned here only because there is no mail server.
    # Once SMTP is available, email it instead of returning it in the response.
    return jsonify({"msg": "Reset token generated", "token": token})


@app.route("/reset_password", methods=["POST"])
def reset_password():
    data  = request.json
    token = data.get("token")
    raw   = data.get("new_password") or ""

    err = validate_password(raw)
    if err:
        return jsonify({"error": err}), 400

    new_password = generate_password_hash(raw)
    conn   = get_conn()
    cursor = conn.cursor()
    df = pd.read_sql(
        "SELECT * FROM users WHERE reset_token=? AND token_expiry > GETDATE()",
        conn, params=[token]
    )
    if df.empty:
        conn.close()
        return jsonify({"error": "Invalid or expired token"}), 400
    username = df.iloc[0]["username"]
    cursor.execute(
        "UPDATE users SET password_hash=?, reset_token=NULL, token_expiry=NULL, "
        "is_first_login=0, password_expiry=? WHERE username=?",
        new_password, datetime.now() + timedelta(days=90), username
    )
    conn.commit()
    conn.close()
    return jsonify({"msg": "Password reset successful"})


@app.route("/change_password", methods=["GET", "POST"])
def change_password():
    if "reset_user" not in session:
        return redirect(url_for("login"))
    if request.method == "POST":
        new_pass = request.form.get("new_password")
        confirm  = request.form.get("confirm_password")
        if new_pass != confirm:
            return render_template("change_password.html", error="Passwords do not match")
        err = validate_password(new_pass)
        if err:
            return render_template("change_password.html", error=err)

        hashed = generate_password_hash(new_pass)
        conn   = get_conn()
        cursor = conn.cursor()
        expiry = datetime.now() + timedelta(days=90)
        cursor.execute(
            "UPDATE users SET password_hash=?, is_first_login=0, password_expiry=? WHERE username=?",
            hashed, expiry, session["reset_user"]
        )
        conn.commit()

        cursor.execute("SELECT is_admin FROM users WHERE username=?", session["reset_user"])
        row = cursor.fetchone()
        conn.close()

        username = session.pop("reset_user")
        session["user"] = username
        session["role"] = "admin" if (row and row[0]) else "officer"
        return redirect(url_for("dashboard"))
    return render_template("change_password.html")


@app.route("/admin/change_password", methods=["POST"])
def admin_change_password():
    if not is_admin():
        return redirect(url_for("login"))

    ss_id    = request.form.get("ss_id", "")
    new_pass = request.form.get("new_password", "")
    confirm  = request.form.get("confirm_password", "")

    if not new_pass or new_pass != confirm:
        return redirect(url_for("admin_settings"))

    conn   = get_conn()
    cursor = conn.cursor()
    try:
        if ss_id.startswith("officer_"):
            officer_id = ss_id.replace("officer_", "")
            hashed = generate_password_hash(new_pass)
            cursor.execute(
                "UPDATE users SET password_hash=?, is_first_login=0 WHERE id=?",
                hashed, officer_id
            )
        else:
            field_id = ss_id.replace("field_", "")
            cursor.execute(
                "UPDATE slis_substationdata SET password=? WHERE ss_id=?",
                new_pass, field_id
            )
        conn.commit()
    except Exception as e:
        conn.rollback()
        print("ADMIN CHANGE PW ERROR:", e)
    finally:
        conn.close()
    return redirect(url_for("admin_settings"))


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/dashboard")
def dashboard():
    if not logged_in():
        return redirect(url_for("login"))
    return render_template(
        "dashboard.html",
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
        df   = pd.read_sql("SELECT DISTINCT zone FROM dbo.slis_substationdata", conn)
        conn.close()
        return jsonify(df["zone"].dropna().astype(str).tolist())
    except Exception as e:
        print("ZONES ERROR:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/circles/<zone>")
def get_circles(zone):
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql(
            "SELECT DISTINCT circle FROM dbo.slis_substationdata WHERE zone=?",
            conn, params=[zone]
        )
        conn.close()
        return jsonify(df["circle"].dropna().astype(str).tolist())
    except Exception as e:
        print("CIRCLES ERROR:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/substations/<circle>")
def get_substations(circle):
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql(
            "SELECT ss_id, sub_station_name FROM dbo.slis_substationdata WHERE circle=?",
            conn, params=[circle]
        )
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        print("SUBSTATIONS ERROR:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/all_substations")
def get_all_substations():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql(
            "SELECT ss_id, sub_station_name FROM dbo.slis_substationdata ORDER BY sub_station_name",
            conn
        )
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        print("ALL SS ERROR:", e)
        return jsonify({"error": str(e)}), 500


@app.route("/api/substations_full")
def api_substations_full():
    """Every column of slis_substationdata for the Flutter app's Substations tab.
    The password column is stripped — it must never leave the server."""
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql("SELECT * FROM slis_substationdata ORDER BY ss_id", conn)
        conn.close()
        df = df.drop(columns=[c for c in ("password",) if c in df.columns])
        if "mobile_no" in df.columns:
            df["mobile_no"] = df["mobile_no"].apply(_clean_id)
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ─── MAIN DATA ────────────────────────────────────────────────────────────────
@app.route("/data", methods=["POST"])
def get_data():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401

    data      = request.json or {}
    ss_ids    = data.get("ss_ids", [])
    from_date = data.get("from_date")
    to_date   = data.get("to_date")

    # Field users are hard-scoped to their own substation server-side.
    if is_field_user() and caller_ss_id():
        ss_ids = [caller_ss_id()]

    try:
        conn = get_conn()

        placeholders = ",".join(["?" for _ in ss_ids])
        params       = list(ss_ids)

        query = f"""
        SELECT
            s.ss_id, s.sub_station_name, s.zone, s.circle,
            c.sno, c.PTR_Capacity, c.Voltage_Rating,
            c.Manufacturer, c.ManufSerialNo, c.YoM, c.Doc,
            ISNULL(TRY_CAST(NULLIF(l.maxload, '') AS FLOAT), 0) AS maxload,
            ISNULL(TRY_CAST(NULLIF(l.minload, '') AS FLOAT), 0) AS minload,
            l.min_loadtime, l.loadtime, l.loaddate
        FROM dbo.slis_substationdata s
        JOIN dbo.capacity_new c ON s.ss_id = c.ss_id
        LEFT JOIN dbo.SubStationLoad l
            ON s.ss_id = l.ss_id AND c.sno = l.sno
        WHERE 1=1
        """

        if ss_ids:
            query += f" AND s.ss_id IN ({placeholders})"

        if from_date and to_date:
            query += " AND l.loaddate >= ? AND l.loaddate <= ?"
            params += [from_date + " 00:00:00", to_date + " 23:59:59"]

        query += """
        ORDER BY
            CAST(l.loaddate AS DATE) ASC,
            TRY_CAST(LEFT(c.Voltage_Rating, CHARINDEX('/', c.Voltage_Rating) - 1) AS INT) DESC,
            TRY_CAST(
                SUBSTRING(
                    c.Voltage_Rating,
                    CHARINDEX('/', c.Voltage_Rating) + 1,
                    CHARINDEX('K', c.Voltage_Rating) - CHARINDEX('/', c.Voltage_Rating) - 1
                ) AS INT
            ) DESC,
            TRY_CAST(c.PTR_Capacity AS INT) DESC
        """

        df = pd.read_sql(query, conn, params=params)
        conn.close()

        if df.empty:
            return jsonify([])
        return jsonify(df_to_records(df))

    except Exception as e:
        print("DATA ERROR:", e)
        return jsonify({"error": str(e)}), 500


# ─── STATION MAX ──────────────────────────────────────────────────────────────
@app.route("/station_max", methods=["POST"])
def station_max():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401

    data      = request.json or {}
    ss_ids    = data.get("ss_ids", [])
    from_date = data.get("from_date")
    to_date   = data.get("to_date")

    # Field users are hard-scoped to their own substation regardless of what
    # ss_ids the client sends — client-side selection is UX only. The scope is
    # taken from the SESSION / authenticated header, never from the body.
    if is_field_user() and caller_ss_id():
        ss_ids = [caller_ss_id()]

    try:
        if not ss_ids:
            return jsonify({"peak": [], "full": []})

        conn = get_conn()

        # Parameterised — ss_ids comes from the request body and must never be
        # interpolated into the SQL string.
        placeholders = ",".join(["?" for _ in ss_ids])

        query = f"""
        WITH ptr_data AS (
            SELECT
                s.ss_id, s.sub_station_name, c.sno, c.Voltage_Rating,
                TRY_CAST(LEFT(c.Voltage_Rating, CHARINDEX('/', c.Voltage_Rating + '/') - 1) AS INT) AS primary_voltage
            FROM dbo.slis_substationdata s
            JOIN dbo.capacity_new c ON s.ss_id = c.ss_id
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
        all_dates AS (
            SELECT DISTINCT l.ss_id, CAST(l.loaddate AS DATE) AS loaddate
            FROM dbo.SubStationLoad l
            JOIN filtered_ptrs f ON l.ss_id = f.ss_id
            WHERE CAST(l.loaddate AS DATE) BETWEEN ? AND ?
        ),
        station_daily AS (
            SELECT
                f.ss_id, f.sub_station_name, d.loaddate,
                SUM(ISNULL(TRY_CAST(NULLIF(l.maxload, '') AS FLOAT), 0)) AS station_max_load
            FROM filtered_ptrs f
            JOIN all_dates d ON f.ss_id = d.ss_id
            LEFT JOIN dbo.SubStationLoad l
                ON f.ss_id = l.ss_id AND f.sno = l.sno
                AND CAST(l.loaddate AS DATE) = d.loaddate
            GROUP BY f.ss_id, f.sub_station_name, d.loaddate
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


# ─── PTR DETAILS (dashboard) ─────────────────────────────────────────────────
@app.route("/ptr_details_peak", methods=["POST"])
def ptr_details_peak():
    if not logged_in():
        return jsonify([])

    data  = request.json or {}
    ss_id = data.get("ss_id")
    date  = data.get("date")

    # Server-side scope check — the client no longer supplies its own role.
    if is_field_user():
        own = caller_ss_id()
        if not own or str(ss_id) != str(own):
            return jsonify([])

    try:
        conn  = get_conn()
        query = """
        WITH ptr_data AS (
            SELECT c.ss_id, c.sno, c.PTR_Capacity, c.Voltage_Rating,
                c.Manufacturer, c.ManufSerialNo, c.YoM, c.Doc,
                TRY_CAST(LEFT(c.Voltage_Rating, CHARINDEX('/', c.Voltage_Rating + '/') - 1) AS INT) AS primary_voltage
            FROM capacity_new c WHERE c.ss_id = ?
        ),
        max_voltage AS (SELECT MAX(primary_voltage) AS max_v FROM ptr_data),
        filtered_ptrs AS (
            SELECT p.* FROM ptr_data p JOIN max_voltage m ON p.primary_voltage = m.max_v
        )
        SELECT
            f.sno, f.PTR_Capacity, f.Voltage_Rating, f.Manufacturer,
            f.ManufSerialNo, f.YoM, f.Doc,
            ISNULL(TRY_CAST(NULLIF(l.maxload, '') AS FLOAT), 0) AS maxload,
            l.loadtime,
            ISNULL(TRY_CAST(NULLIF(l.minload, '') AS FLOAT), 0) AS minload,
            l.min_loadtime,
            CONVERT(VARCHAR(10), l.loaddate, 105) AS loaddate
        FROM filtered_ptrs f
        JOIN SubStationLoad l ON f.ss_id = l.ss_id AND f.sno = l.sno
        WHERE CONVERT(DATE, l.loaddate) = ?
        ORDER BY f.PTR_Capacity DESC
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
    if not logged_in():
        return jsonify({"type": "text", "reply": "❌ Not logged in"}), 401

    data = request.get_json(force=True)
    print("INPUT:", data)

    raw_msg          = data.get("message", "").strip()
    selected_ss_id   = data.get("ss_id")
    already_resolved = bool(data.get("already_normalized"))
    conn             = None

    # ── Free-text understanding ─────────────────────────────────────
    # Rewrite whatever phrasing the user typed into the keyword style the
    # parser below expects. Falls back to raw_msg automatically if the LLM
    # call fails for any reason (see llm_normalize_message).
    #
    # SKIPPED when already_normalized=True: this happens when the user is
    # re-submitting a command after picking a substation from a multi-match
    # picker (see /chat "options" responses + selectSS() in the frontend). In
    # that case `raw_msg` IS ALREADY the normalized command from the first LLM
    # call, and re-running the LLM on it a second time is both wasteful and
    # risky — minor wording variation between two separate LLM calls for the
    # same input could produce a slightly different command that no longer
    # matches any intent branch below, causing a false "Not understood" after
    # a valid pick.
    if already_resolved:
        msg = raw_msg.lower().strip()
    else:
        msg = llm_normalize_message(raw_msg).lower().strip()

    # months_map defined early so natural date parsing can reference it
    months_map = {
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12
    }

    try:
        conn = get_conn()

        # ── Greeting / small-talk short-circuit ─────────────────────
        # MUST run before any substation lookup. Without this, a plain "hi"
        # survives the filler-word stripping below (since "hi" isn't itself a
        # filler word) and gets used as a substation-name search via
        # LIKE '%hi%' — which matches dozens of real substation names that
        # happen to contain "hi" (Hathighat, Chilkalguda, Madhira, etc.),
        # producing a giant, meaningless picker instead of a friendly reply.
        GREETING_WORDS = {
            "hi", "hii", "hiii", "hello", "hey", "heyy", "hai",
            "good morning", "good afternoon", "good evening", "morning", "evening",
            "thanks", "thank you", "thx", "ok", "okay", "bye", "goodbye"
        }
        if msg in GREETING_WORDS:
            return jsonify({"type": "text", "reply": "👋 Hello! Ask me about a substation's load, transformer (PTR) details, master info, or type 'help' to see all commands."})

        # ── Normalize ────────────────────────────────────────────────
        msg = re.sub(r'station\s+maximum\s+load', 'station max', msg)
        msg = re.sub(r'station\s+maximum',        'station max', msg)
        msg = re.sub(r'station\s+max\s+load',     'station max', msg)
        msg = re.sub(r'peak\s+load',              'station max', msg)
        msg = re.sub(r'\bpeter\b',                'ptr',         msg)
        msg = re.sub(r'\bp\.t\.r\.?\b',           'ptr',         msg)
        msg = re.sub(r'\bp\s+t\s+r\b',            'ptr',         msg)
        msg = re.sub(r'ptr\s+details?',           'ptr',         msg)
        msg = re.sub(r'ptr\s+info',               'ptr',         msg)
        msg = re.sub(r'transformer\s+details?',   'ptr',         msg)
        msg = re.sub(r'power\s+transformer',      'ptr',         msg)

        print("NORMALIZED:", msg)

        # ── Date / period parsing ────────────────────────────────────
        filter_date     = None
        month_filter    = None
        year_filter     = None
        days_filter     = None
        single_prev_day = None
        year_only       = None

        # --- this year / last year flags (parsed early so natural date can use them) ---
        this_year_flag  = "this year"  in msg
        last_year_flag  = "last year"  in msg
        this_month_flag = "this month" in msg
        last_month_flag = "last month" in msg
        week_before_last_flag = any(p in msg for p in [
            "week before last", "two weeks ago", "last before week",
            "before last week", "the week before last"
        ])
        # last_week_flag must only fire if week_before_last phrases are absent
        last_week_flag = (not week_before_last_flag) and any(p in msg for p in [
            "last week", "previous week", "past week", "the week before"
        ])

        # --- Numeric date formats: dd.mm.yyyy / dd-mm-yyyy / dd/mm/yyyy ---
        date_match = re.search(r'(\d{1,2})[./-](\d{1,2})[./-](\d{4})', msg)
        if date_match:
            day, month, year = date_match.groups()
            filter_date = f"{year}-{int(month):02d}-{int(day):02d}"

        # --- Natural language date: "20th april 2026", "20 april 2026",
        #     "20april2026", "20 april this year", "20 april" ---
        if not filter_date:
            nat_match = re.search(
                r'(\d{1,2})(?:st|nd|rd|th)?\s*'
                r'(january|february|march|april|may|june|july|august'
                r'|september|october|november|december)'
                r'(?:\s*,?\s*(\d{4}))?',
                msg
            )
            if nat_match:
                nd, nm, ny = nat_match.groups()
                nat_month = months_map.get(nm)
                if nat_month:
                    if ny:
                        nat_year = int(ny)
                    elif last_year_flag:
                        nat_year = datetime.today().year - 1
                    elif this_year_flag:
                        nat_year = datetime.today().year
                    else:
                        # peek for a standalone 4-digit year elsewhere in message
                        ym = re.search(r'\b(20\d{2})\b', msg)
                        nat_year = int(ym.group(1)) if ym else datetime.today().year
                    filter_date = f"{nat_year}-{nat_month:02d}-{int(nd):02d}"
                    print(f"NATURAL DATE PARSED: {filter_date}")

        if any(w in msg for w in ["yesterday", "last date", "previous date", "previous day", "last day"]):
            single_prev_day = (datetime.today() - timedelta(days=1)).strftime("%Y-%m-%d")

        # Word-number to integer map (supports "last ten weeks", "last 3 days", etc.)
        _WORD_NUMS = {
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
            "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
            "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
            "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50
        }

        def _parse_num(s):
            s = s.strip()
            if s.isdigit():
                return int(s)
            return _WORD_NUMS.get(s.lower())

        _num_alts = '|'.join(_WORD_NUMS.keys())
        days_match = re.search(
            r'(?:last|previous)\s+(' + _num_alts + r'|\d+)\s+(days?|weeks?)',
            msg, re.IGNORECASE
        )
        if days_match:
            n = _parse_num(days_match.group(1))
            unit = days_match.group(2).lower()
            if n:
                days_filter = n * 7 if unit.startswith('week') else n

        if not filter_date:
            year_match = re.search(r'\b(20\d{2})\b', msg)
            if year_match:
                year_only = int(year_match.group(1))

        msg_for_month = msg.replace("this month", "").replace("last month", "") \
                           .replace("this year", "").replace("last year", "")

        for m in months_map:
            if m in msg_for_month:
                month_filter = months_map[m]
                year_filter  = year_only if year_only else datetime.now().year

        if this_month_flag:
            today        = datetime.today()
            month_filter = today.month
            year_filter  = today.year

        if last_month_flag:
            today        = datetime.today()
            first        = today.replace(day=1)
            last         = first - timedelta(days=1)
            month_filter = last.month
            year_filter  = last.year

        if this_year_flag:
            year_only = datetime.today().year
        if last_year_flag:
            year_only = datetime.today().year - 1

        # Compute Monday–Sunday boundaries for week-based filters
        if last_week_flag or week_before_last_flag:
            today_dt = datetime.today()
            this_monday = today_dt - timedelta(days=today_dt.weekday())
            if last_week_flag:
                week_start = (this_monday - timedelta(weeks=1)).strftime("%Y-%m-%d")
                week_end   = (this_monday - timedelta(days=1)).strftime("%Y-%m-%d")
            else:  # week_before_last_flag
                week_start = (this_monday - timedelta(weeks=2)).strftime("%Y-%m-%d")
                week_end   = (this_monday - timedelta(weeks=1) - timedelta(days=1)).strftime("%Y-%m-%d")
        else:
            week_start = None
            week_end   = None

        # If a natural-language date was parsed, clear month_filter so it doesn't
        # hijack the specific-date branch (e.g. "20 april" also sets month=april)
        if filter_date and month_filter:
            month_filter = None
            year_filter  = None

        year_range_filter = (year_only is not None) and (month_filter is None) and (not filter_date)

        print("filter_date:", filter_date, "| month:", month_filter,
              "| year_filter:", year_filter, "| year_only:", year_only,
              "| year_range:", year_range_filter,
              "| prev:", single_prev_day, "| days:", days_filter,
              "| last_week:", last_week_flag, "| wbl:", week_before_last_flag,
              "| week_start:", week_start, "| week_end:", week_end)

        # ── Resolve SS ID ────────────────────────────────────────────
        # Skipped for intents that aren't about ONE specific substation (e.g.
        # "list substations ...", "help") — running name lookup for these would
        # either error out or, worse, wrongly match a filter word (like "rural"
        # or "sangareddy") against a substation name.
        SINGLE_SUBSTATION_INTENT = not (
            msg.startswith("list substations") or msg == "help" or "help" in msg
        )

        ss_id = str(selected_ss_id).strip() if selected_ss_id else None

        # Field users can only ever ask about their own substation.
        if is_field_user() and caller_ss_id():
            ss_id = str(caller_ss_id())

        if SINGLE_SUBSTATION_INTENT and not ss_id:
            # Only treat a number as a literal ss_id if it's explicitly flagged
            # with "id" (e.g. "ss_id 292", "id 292"). Matching ANY bare number
            # in the message is unsafe with free text / voice input — stray
            # digits from dates ("5 may 2026"), misheard voice numbers, etc.
            # would otherwise silently hijack the substation lookup and skip
            # name matching entirely (this is exactly what caused
            # wrong-substation results for date queries).
            id_match = re.search(r'\b(?:ss_id|ss id|substation id|id)\s*[:\-]?\s*(\d{1,5})\b', msg)
            ss_id    = id_match.group(1) if id_match else None

        if SINGLE_SUBSTATION_INTENT and not ss_id:
            words_to_remove = [
                "station", "substation", "maximum", "max", "load", "peak", "highest",
                "ptr", "details", "detail", "info", "master", "all", "dates", "date", "datewise",
                "day", "days", "daywise", "wise", "this", "last", "previous", "next", "year",
                "month", "yesterday", "week", "before",
                "january", "february", "march", "april", "may", "june",
                "july", "august", "september", "october", "november", "december",
                # filler / question words from natural sentences (voice or typed)
                "what", "whats", "is", "was", "are", "the", "of", "for", "at", "in", "on",
                "demand", "value", "reading", "please", "kindly", "can", "you", "tell",
                "me", "show", "give", "know", "want", "find", "get", "need", "would",
                "like", "to", "a", "an", "busiest", "biggest",
                # master-info related filler words
                "which", "does", "belong", "belongs", "zone", "circle", "region", "division"
            ]
            ss_name = msg
            ss_name = re.sub(r'\d{1,2}[./-]\d{1,2}[./-]\d{4}', '', ss_name)
            # Strip "last N days", "last N weeks", "last ten weeks", etc.
            _wn = ('one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|'
                   'thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|'
                   'twenty|thirty|forty|fifty')
            ss_name = re.sub(r'(?:last|previous)\s+(?:' + _wn + r'|\d+)\s+(?:days?|weeks?)',
                             '', ss_name, flags=re.IGNORECASE)
            # Strip week-based date phrases before individual word removal
            ss_name = re.sub(r'\b(?:week\s+before\s+last|last\s+before\s+week|the\s+week\s+before\s+last|two\s+weeks?\s+ago)\b', '', ss_name)
            ss_name = re.sub(r'\b(?:last\s+week|previous\s+week|past\s+week|the\s+week\s+before)\b', '', ss_name)
            ss_name = re.sub(r'\b20\d{2}\b', '', ss_name)
            # Also strip natural-language date fragments so they don't pollute the name search
            ss_name = re.sub(
                r'\d{1,2}(?:st|nd|rd|th)?\s*'
                r'(?:january|february|march|april|may|june|july|august'
                r'|september|october|november|december)',
                '', ss_name
            )
            for w in words_to_remove:
                ss_name = re.sub(rf'\b{w}\b', '', ss_name)
            ss_name = re.sub(r'\s+', ' ', ss_name).strip()

            print("CLEAN NAME:", repr(ss_name))

            if not ss_name:
                return jsonify({"type": "text", "reply": "❌ Please enter a substation name. Type 'help'"})

            df_names = pd.read_sql(
                "SELECT ss_id, sub_station_name FROM slis_substationdata WHERE LOWER(sub_station_name) LIKE ?",
                conn, params=[f"%{ss_name}%"]
            )

            # Fallback: voice transcription sometimes leaves an extra stray word
            # in front of the real name (e.g. "registration gachibowli" when
            # speech recognition misheard "station"). If the full cleaned phrase
            # matches nothing, retry using just the last word, which is usually
            # the actual substation name.
            if df_names.empty and " " in ss_name:
                last_word = ss_name.split()[-1]
                df_names = pd.read_sql(
                    "SELECT ss_id, sub_station_name FROM slis_substationdata WHERE LOWER(sub_station_name) LIKE ?",
                    conn, params=[f"%{last_word}%"]
                )

            if len(df_names) > 1:
                return jsonify({
                    "type": "options",
                    "message": "Multiple substations found. Please select:",
                    "resolved_query": msg,
                    "options": [{"ss_id": str(r["ss_id"]), "name": r["sub_station_name"]}
                                for _, r in df_names.iterrows()]
                })
            if df_names.empty:
                return jsonify({"type": "text", "reply": "❌ Substation not found. Type 'help'"})

            ss_id = str(df_names.iloc[0]["ss_id"])

        print("FINAL ss_id:", ss_id)

        if SINGLE_SUBSTATION_INTENT and not ss_id:
            return jsonify({"type": "text", "reply": "❌ Could not identify substation. Type 'help'"})

        # ════════════════════════════════════════════════════════════
        # STATION MAX
        # ════════════════════════════════════════════════════════════
        if "station max" in msg:

            if month_filter and not year_filter:
                year_filter = datetime.now().year

            # Reusable CTE prefix for station max queries
            SM_CTE = """
            WITH ptr_data AS (
                SELECT c.sno,
                    TRY_CAST(LEFT(c.Voltage_Rating, CHARINDEX('/',c.Voltage_Rating+'/')-1) AS INT) AS primary_voltage
                FROM capacity_new c WHERE c.ss_id = ?
            ),
            max_v AS (SELECT MAX(primary_voltage) AS max_v FROM ptr_data),
            filtered_ptrs AS (SELECT p.sno FROM ptr_data p JOIN max_v m ON p.primary_voltage = m.max_v)
            """

            # ── Specific date ─────────────────────────────────────────
            if filter_date:
                print("SM: SPECIFIC DATE")
                query = SM_CTE + """
                SELECT s.ss_id, s.sub_station_name,
                    SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                    CONVERT(VARCHAR(10), CAST(? AS DATE), 105) AS loaddate
                FROM slis_substationdata s
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN SubStationLoad l
                    ON s.ss_id = l.ss_id AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = ?
                WHERE s.ss_id = ?
                GROUP BY s.ss_id, s.sub_station_name
                """
                params     = [ss_id, filter_date, filter_date, ss_id]
                show_graph = False

            # ── Yesterday ─────────────────────────────────────────────
            elif single_prev_day:
                print("SM: YESTERDAY")
                query = SM_CTE + """
                SELECT s.ss_id, s.sub_station_name,
                    SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                    CONVERT(VARCHAR(10), CAST(? AS DATE), 105) AS loaddate
                FROM slis_substationdata s
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN SubStationLoad l
                    ON s.ss_id = l.ss_id AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = ?
                WHERE s.ss_id = ?
                GROUP BY s.ss_id, s.sub_station_name
                """
                params     = [ss_id, single_prev_day, single_prev_day, ss_id]
                show_graph = False

            # ── Last N days ───────────────────────────────────────────
            elif days_filter:
                print(f"SM: LAST {days_filter} DAYS")
                start_date = (datetime.today() - timedelta(days=days_filter)).strftime("%Y-%m-%d")
                end_date   = datetime.today().strftime("%Y-%m-%d")
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT CAST(l.loaddate AS DATE) AS loaddate
                    FROM SubStationLoad l
                    JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = ?
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                )
                SELECT s.ss_id, s.sub_station_name,
                    SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                    CONVERT(VARCHAR(10), d.loaddate, 105) AS loaddate
                FROM slis_substationdata s
                JOIN all_dates d ON 1=1
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN SubStationLoad l
                    ON s.ss_id = l.ss_id AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = d.loaddate
                WHERE s.ss_id = ?
                GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                ORDER BY d.loaddate
                """
                params     = [ss_id, ss_id, start_date, end_date, ss_id]
                show_graph = True

            # ── Last week ─────────────────────────────────────────────
            elif last_week_flag and week_start:
                print(f"SM: LAST WEEK ({week_start} to {week_end})")
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT CAST(l.loaddate AS DATE) AS loaddate
                    FROM SubStationLoad l
                    JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = ?
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                )
                SELECT s.ss_id, s.sub_station_name,
                    SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                    CONVERT(VARCHAR(10), d.loaddate, 105) AS loaddate
                FROM slis_substationdata s
                JOIN all_dates d ON 1=1
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN SubStationLoad l
                    ON s.ss_id = l.ss_id AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = d.loaddate
                WHERE s.ss_id = ?
                GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                ORDER BY d.loaddate
                """
                params     = [ss_id, ss_id, week_start, week_end, ss_id]
                show_graph = True

            # ── Week before last ──────────────────────────────────────
            elif week_before_last_flag and week_start:
                print(f"SM: WEEK BEFORE LAST ({week_start} to {week_end})")
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT CAST(l.loaddate AS DATE) AS loaddate
                    FROM SubStationLoad l
                    JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = ?
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                )
                SELECT s.ss_id, s.sub_station_name,
                    SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                    CONVERT(VARCHAR(10), d.loaddate, 105) AS loaddate
                FROM slis_substationdata s
                JOIN all_dates d ON 1=1
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN SubStationLoad l
                    ON s.ss_id = l.ss_id AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = d.loaddate
                WHERE s.ss_id = ?
                GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                ORDER BY d.loaddate
                """
                params     = [ss_id, ss_id, week_start, week_end, ss_id]
                show_graph = True

            # ── Month wise ────────────────────────────────────────────
            elif month_filter:
                print("SM: MONTH WISE")
                start_date = f"{year_filter}-{month_filter:02d}-01"
                end_date   = f"{year_filter+1}-01-01" if month_filter == 12 \
                             else f"{year_filter}-{month_filter+1:02d}-01"
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT CAST(l.loaddate AS DATE) AS loaddate
                    FROM SubStationLoad l
                    JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = ?
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) < ?
                )
                SELECT s.ss_id, s.sub_station_name,
                    SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                    CONVERT(VARCHAR(10), d.loaddate, 105) AS loaddate
                FROM slis_substationdata s
                JOIN all_dates d ON 1=1
                JOIN filtered_ptrs f ON 1=1
                LEFT JOIN SubStationLoad l
                    ON s.ss_id = l.ss_id AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = d.loaddate
                WHERE s.ss_id = ?
                GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                ORDER BY d.loaddate
                """
                params     = [ss_id, ss_id, start_date, end_date, ss_id]
                show_graph = True

            # ── Year wise (peak day for that year) ────────────────────
            elif year_range_filter:
                print(f"SM: YEAR WISE {year_only}")
                y_start = f"{year_only}-01-01"
                y_end   = f"{year_only}-12-31"
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT CAST(l.loaddate AS DATE) AS loaddate
                    FROM SubStationLoad l
                    JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = ?
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                ),
                daily_totals AS (
                    SELECT s.ss_id, s.sub_station_name,
                        SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                        CONVERT(VARCHAR(10), d.loaddate, 105) AS loaddate
                    FROM slis_substationdata s
                    JOIN all_dates d ON 1=1
                    JOIN filtered_ptrs f ON 1=1
                    LEFT JOIN SubStationLoad l
                        ON s.ss_id = l.ss_id AND f.sno = l.sno
                        AND CAST(l.loaddate AS DATE) = d.loaddate
                    WHERE s.ss_id = ?
                    GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                )
                SELECT TOP 1 * FROM daily_totals ORDER BY station_max_load DESC
                """
                params     = [ss_id, ss_id, y_start, y_end, ss_id]
                show_graph = False

            # ── Overall peak (no date/period specified) ───────────────
            else:
                print("SM: OVERALL PEAK")
                query = SM_CTE + """
                , all_dates AS (
                    SELECT DISTINCT CAST(l.loaddate AS DATE) AS loaddate
                    FROM SubStationLoad l
                    JOIN filtered_ptrs f ON l.sno = f.sno
                    WHERE l.ss_id = ?
                ),
                daily_totals AS (
                    SELECT s.ss_id, s.sub_station_name,
                        SUM(ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0)) AS station_max_load,
                        CONVERT(VARCHAR(10), d.loaddate, 105) AS loaddate
                    FROM slis_substationdata s
                    JOIN all_dates d ON 1=1
                    JOIN filtered_ptrs f ON 1=1
                    LEFT JOIN SubStationLoad l
                        ON s.ss_id = l.ss_id AND f.sno = l.sno
                        AND CAST(l.loaddate AS DATE) = d.loaddate
                    WHERE s.ss_id = ?
                    GROUP BY s.ss_id, s.sub_station_name, d.loaddate
                )
                SELECT TOP 1 * FROM daily_totals ORDER BY station_max_load DESC
                """
                params     = [ss_id, ss_id, ss_id]
                show_graph = False

            # ── Execute and respond ───────────────────────────────────
            print("SM PARAMS:", params)
            df = pd.read_sql(query, conn, params=params)
            print("SM ROWS:", len(df))

            if df.empty:
                return jsonify({"type": "text", "reply": "⚠️ No data found"})

            records = df_to_records(df)

            chart = None
            if show_graph and len(df) > 1:
                labels = df["loaddate"].tolist()
                values = []
                for v in df["station_max_load"].tolist():
                    try:
                        values.append(round(float(v), 2) if v is not None else 0)
                    except (TypeError, ValueError):
                        values.append(0)
                ss_lbl = str(df["sub_station_name"].iloc[0]) if "sub_station_name" in df.columns else "Station"
                chart  = {"labels": labels, "datasets": [{"label": ss_lbl + " — Station Max Load", "data": values}]}

            # Also fetch PTR details if "ptr" keyword present
            if any(w in msg for w in ["ptr", "transformer"]) and len(records) > 0:
                peak_rec      = records[0]
                peak_date_raw = str(peak_rec.get("loaddate", ""))
                try:
                    peak_date_sql = datetime.strptime(peak_date_raw, "%d-%m-%Y").strftime("%Y-%m-%d")
                except ValueError:
                    peak_date_sql = peak_date_raw

                ptr_query = """
                WITH ptr_data AS (
                    SELECT c.sno, c.PTR_Capacity, c.Voltage_Rating,
                        c.Manufacturer, c.ManufSerialNo, c.YoM, c.Doc,
                        TRY_CAST(LEFT(c.Voltage_Rating, CHARINDEX('/', c.Voltage_Rating + '/') - 1) AS INT) AS primary_voltage
                    FROM capacity_new c WHERE c.ss_id = ?
                ),
                max_voltage AS (SELECT MAX(primary_voltage) AS max_v FROM ptr_data),
                filtered_ptrs AS (
                    SELECT p.sno, p.PTR_Capacity, p.Voltage_Rating, p.Manufacturer, p.ManufSerialNo, p.YoM, p.Doc
                    FROM ptr_data p JOIN max_voltage m ON p.primary_voltage = m.max_v
                )
                SELECT
                    f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0) AS max_load,
                    ISNULL(TRY_CAST(NULLIF(l.minload,'') AS FLOAT), 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    CONVERT(VARCHAR(10), l.loaddate, 105) AS loaddate, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l
                    ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = ?
                ORDER BY f.PTR_Capacity DESC
                """
                df_ptr      = pd.read_sql(ptr_query, conn, params=[ss_id, ss_id, peak_date_sql])
                ptr_records = df_to_records(df_ptr) if not df_ptr.empty else []

                return jsonify({
                    "type":      "table",
                    "data":      records,
                    "chart":     chart,
                    "ptr_data":  ptr_records,
                    "ptr_label": f"PTR Details on Station Max Date ({peak_date_raw})"
                })

            return jsonify({"type": "table", "data": records, "chart": chart})

        # ════════════════════════════════════════════════════════════
        # PTR DETAILS
        # ════════════════════════════════════════════════════════════
        elif "ptr" in msg:

            if month_filter and not year_filter:
                year_filter = datetime.now().year

            all_dates_mode = any(w in msg for w in [
                "all dates", "all date", "all days", "day wise", "daywise", "date wise", "datewise"
            ])
            month_max_mode = (month_filter is not None) and (not all_dates_mode) and \
                             any(w in msg for w in ["max", "peak", "highest"])

            # ALL modes use PTR_CTE_ALL so every PTR at the substation is shown,
            # regardless of voltage level. The highest-voltage-only filter is
            # kept exclusively for the "station max + ptr" combined command,
            # which is handled in the SM branch above.
            PTR_CTE_ALL = """
            WITH filtered_ptrs AS (
                SELECT c.sno, c.PTR_Capacity, c.Voltage_Rating,
                    c.Manufacturer, c.ManufSerialNo, c.YoM, c.Doc
                FROM capacity_new c WHERE c.ss_id = ?
            )
            """

            # ── MODE 2 — specific date ────────────────────────────────
            if filter_date:
                print("PTR MODE 2: SPECIFIC DATE — ALL PTRs")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0) AS max_load,
                    ISNULL(TRY_CAST(NULLIF(l.minload,'') AS FLOAT), 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    CONVERT(VARCHAR(10), l.loaddate, 105) AS loaddate, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = ?
                ORDER BY
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    f.PTR_Capacity DESC
                """
                params     = [ss_id, ss_id, filter_date]
                show_graph = False
                mode_label = f"PTR Details (All PTRs) — {filter_date}"

            # ── MODE 2b — yesterday ───────────────────────────────────
            elif single_prev_day:
                print("PTR MODE 2b: YESTERDAY — ALL PTRs")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0) AS max_load,
                    ISNULL(TRY_CAST(NULLIF(l.minload,'') AS FLOAT), 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    CONVERT(VARCHAR(10), l.loaddate, 105) AS loaddate, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) = ?
                ORDER BY
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    f.PTR_Capacity DESC
                """
                params     = [ss_id, ss_id, single_prev_day]
                show_graph = False
                mode_label = f"PTR Details (All PTRs) — Yesterday ({single_prev_day})"

            # ── MODE 4 — all dates in month ───────────────────────────
            elif all_dates_mode and month_filter:
                print("PTR MODE 4: ALL DATES IN MONTH — ALL PTRs")
                start_date = f"{year_filter}-{month_filter:02d}-01"
                end_date   = f"{year_filter+1}-01-01" if month_filter == 12 \
                             else f"{year_filter}-{month_filter+1:02d}-01"
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0) AS max_load,
                    ISNULL(TRY_CAST(NULLIF(l.minload,'') AS FLOAT), 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    CONVERT(VARCHAR(10), CAST(l.loaddate AS DATE), 105) AS loaddate, f.sno
                FROM filtered_ptrs f
                JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) < ?
                ORDER BY CAST(l.loaddate AS DATE) ASC,
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    f.PTR_Capacity DESC
                """
                params     = [ss_id, ss_id, start_date, end_date]
                show_graph = True
                mode_label = f"PTR All Dates (All PTRs) — {start_date[:7]}"

            # ── MODE 4b — all dates last N days ──────────────────────
            elif all_dates_mode and days_filter:
                print(f"PTR MODE 4b: ALL DATES LAST {days_filter} DAYS — ALL PTRs")
                start_date = (datetime.today() - timedelta(days=days_filter)).strftime("%Y-%m-%d")
                end_date   = datetime.today().strftime("%Y-%m-%d")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0) AS max_load,
                    ISNULL(TRY_CAST(NULLIF(l.minload,'') AS FLOAT), 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    CONVERT(VARCHAR(10), CAST(l.loaddate AS DATE), 105) AS loaddate, f.sno
                FROM filtered_ptrs f
                JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                ORDER BY CAST(l.loaddate AS DATE) ASC,
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    f.PTR_Capacity DESC
                """
                params     = [ss_id, ss_id, start_date, end_date]
                show_graph = True
                mode_label = f"PTR All Dates (All PTRs) — Last {days_filter} Days"

            # ── MODE 4c — all dates last week ────────────────────────
            elif all_dates_mode and last_week_flag and week_start:
                print(f"PTR MODE 4c: ALL DATES LAST WEEK ({week_start} to {week_end}) — ALL PTRs")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0) AS max_load,
                    ISNULL(TRY_CAST(NULLIF(l.minload,'') AS FLOAT), 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    CONVERT(VARCHAR(10), CAST(l.loaddate AS DATE), 105) AS loaddate, f.sno
                FROM filtered_ptrs f
                JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                ORDER BY CAST(l.loaddate AS DATE) ASC,
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    f.PTR_Capacity DESC
                """
                params     = [ss_id, ss_id, week_start, week_end]
                show_graph = True
                mode_label = f"PTR All Dates (All PTRs) — Last Week ({week_start} to {week_end})"

            # ── MODE 4d — all dates week before last ─────────────────
            elif all_dates_mode and week_before_last_flag and week_start:
                print(f"PTR MODE 4d: ALL DATES WEEK BEFORE LAST ({week_start} to {week_end}) — ALL PTRs")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT), 0) AS max_load,
                    ISNULL(TRY_CAST(NULLIF(l.minload,'') AS FLOAT), 0) AS min_load,
                    l.loadtime AS max_time, l.min_loadtime AS min_time,
                    CONVERT(VARCHAR(10), CAST(l.loaddate AS DATE), 105) AS loaddate, f.sno
                FROM filtered_ptrs f
                JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                ORDER BY CAST(l.loaddate AS DATE) ASC,
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    f.PTR_Capacity DESC
                """
                params     = [ss_id, ss_id, week_start, week_end]
                show_graph = True
                mode_label = f"PTR All Dates (All PTRs) — Week Before Last ({week_start} to {week_end})"

            # ── MODE 3 — month + max/peak keyword ────────────────────
            elif month_max_mode:
                print("PTR MODE 3: MONTH MAX — ALL PTRs")
                start_date = f"{year_filter}-{month_filter:02d}-01"
                end_date   = f"{year_filter+1}-01-01" if month_filter == 12 \
                             else f"{year_filter}-{month_filter+1:02d}-01"
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT)), 0) AS max_load,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.minload,'') AS FLOAT)), 0) AS min_load,
                    CONVERT(VARCHAR(10),
                        (SELECT TOP 1 CAST(l2.loaddate AS DATE)
                         FROM SubStationLoad l2
                         WHERE l2.ss_id = ? AND l2.sno = f.sno
                           AND CAST(l2.loaddate AS DATE) >= ?
                           AND CAST(l2.loaddate AS DATE) < ?
                         ORDER BY TRY_CAST(NULLIF(l2.maxload,'') AS FLOAT) DESC), 105
                    ) AS peak_date, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) < ?
                GROUP BY f.sno, f.PTR_Capacity, f.Voltage_Rating,
                         f.Manufacturer, f.ManufSerialNo, f.YoM, f.Doc
                ORDER BY
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    max_load DESC
                """
                params     = [ss_id, ss_id, start_date, end_date, ss_id, start_date, end_date]
                show_graph = True
                mode_label = f"PTR Month Max (All PTRs) — {start_date[:7]}"

            # ── MODE 3b — last N days + max ───────────────────────────
            elif days_filter and any(w in msg for w in ["max", "peak", "highest"]):
                print(f"PTR MODE 3b: LAST {days_filter} DAYS MAX — ALL PTRs")
                start_date = (datetime.today() - timedelta(days=days_filter)).strftime("%Y-%m-%d")
                end_date   = datetime.today().strftime("%Y-%m-%d")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT)), 0) AS max_load,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.minload,'') AS FLOAT)), 0) AS min_load,
                    CONVERT(VARCHAR(10),
                        (SELECT TOP 1 CAST(l2.loaddate AS DATE)
                         FROM SubStationLoad l2
                         WHERE l2.ss_id = ? AND l2.sno = f.sno
                           AND CAST(l2.loaddate AS DATE) >= ?
                           AND CAST(l2.loaddate AS DATE) <= ?
                         ORDER BY TRY_CAST(NULLIF(l2.maxload,'') AS FLOAT) DESC), 105
                    ) AS peak_date, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                GROUP BY f.sno, f.PTR_Capacity, f.Voltage_Rating,
                         f.Manufacturer, f.ManufSerialNo, f.YoM, f.Doc
                ORDER BY
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    max_load DESC
                """
                params     = [ss_id, ss_id, start_date, end_date, ss_id, start_date, end_date]
                show_graph = True
                mode_label = f"PTR Peak (All PTRs) — Last {days_filter} Days"

            # ── MODE 3c — last week + max ─────────────────────────────
            elif last_week_flag and week_start:
                print(f"PTR MODE 3c: LAST WEEK MAX ({week_start} to {week_end}) — ALL PTRs")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT)), 0) AS max_load,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.minload,'') AS FLOAT)), 0) AS min_load,
                    CONVERT(VARCHAR(10),
                        (SELECT TOP 1 CAST(l2.loaddate AS DATE)
                         FROM SubStationLoad l2
                         WHERE l2.ss_id = ? AND l2.sno = f.sno
                           AND CAST(l2.loaddate AS DATE) >= ?
                           AND CAST(l2.loaddate AS DATE) <= ?
                         ORDER BY TRY_CAST(NULLIF(l2.maxload,'') AS FLOAT) DESC), 105
                    ) AS peak_date, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                GROUP BY f.sno, f.PTR_Capacity, f.Voltage_Rating,
                         f.Manufacturer, f.ManufSerialNo, f.YoM, f.Doc
                ORDER BY
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    max_load DESC
                """
                params     = [ss_id, ss_id, week_start, week_end, ss_id, week_start, week_end]
                show_graph = True
                mode_label = f"PTR Peak (All PTRs) — Last Week ({week_start} to {week_end})"

            # ── MODE 3d — week before last + max ─────────────────────
            elif week_before_last_flag and week_start:
                print(f"PTR MODE 3d: WEEK BEFORE LAST MAX ({week_start} to {week_end}) — ALL PTRs")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT)), 0) AS max_load,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.minload,'') AS FLOAT)), 0) AS min_load,
                    CONVERT(VARCHAR(10),
                        (SELECT TOP 1 CAST(l2.loaddate AS DATE)
                         FROM SubStationLoad l2
                         WHERE l2.ss_id = ? AND l2.sno = f.sno
                           AND CAST(l2.loaddate AS DATE) >= ?
                           AND CAST(l2.loaddate AS DATE) <= ?
                         ORDER BY TRY_CAST(NULLIF(l2.maxload,'') AS FLOAT) DESC), 105
                    ) AS peak_date, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                    AND CAST(l.loaddate AS DATE) >= ? AND CAST(l.loaddate AS DATE) <= ?
                GROUP BY f.sno, f.PTR_Capacity, f.Voltage_Rating,
                         f.Manufacturer, f.ManufSerialNo, f.YoM, f.Doc
                ORDER BY
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    max_load DESC
                """
                params     = [ss_id, ss_id, week_start, week_end, ss_id, week_start, week_end]
                show_graph = True
                mode_label = f"PTR Peak (All PTRs) — Week Before Last ({week_start} to {week_end})"

            # ── MODE 1 — all PTRs, all-time peak per PTR ──────────────
            else:
                print("PTR MODE 1: ALL PTRs OVERALL PEAK")
                query = PTR_CTE_ALL + """
                SELECT f.Voltage_Rating, f.PTR_Capacity, f.Manufacturer, f.ManufSerialNo,
                    f.YoM, f.Doc,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.maxload,'') AS FLOAT)), 0) AS max_load,
                    ISNULL(MAX(TRY_CAST(NULLIF(l.minload,'') AS FLOAT)), 0) AS min_load,
                    CONVERT(VARCHAR(10),
                        (SELECT TOP 1 CAST(l2.loaddate AS DATE)
                         FROM SubStationLoad l2
                         WHERE l2.ss_id = ? AND l2.sno = f.sno
                         ORDER BY TRY_CAST(NULLIF(l2.maxload,'') AS FLOAT) DESC), 105
                    ) AS peak_date, f.sno
                FROM filtered_ptrs f
                LEFT JOIN SubStationLoad l ON l.ss_id = ? AND f.sno = l.sno
                GROUP BY f.sno, f.PTR_Capacity, f.Voltage_Rating,
                         f.Manufacturer, f.ManufSerialNo, f.YoM, f.Doc
                ORDER BY
                    TRY_CAST(LEFT(f.Voltage_Rating, CHARINDEX('/',f.Voltage_Rating+'/')-1) AS INT) DESC,
                    max_load DESC
                """
                params     = [ss_id, ss_id, ss_id]
                show_graph = False
                mode_label = "PTR Details — All PTRs (Overall Peak)"

            print("PTR PARAMS:", params)
            df = pd.read_sql(query, conn, params=params)
            print("PTR ROWS:", len(df))

            if df.empty:
                return jsonify({"type": "text", "reply": "⚠️ No PTR data found"})

            records = df_to_records(df)

            chart = None
            if show_graph and mode_label.startswith("PTR All Dates"):
                ptr_map  = {}
                date_set = []
                seen     = set()
                for r in records:
                    d = str(r.get("loaddate", ""))
                    if d not in seen:
                        date_set.append(d)
                        seen.add(d)
                    key = f"PTR {r.get('sno','')} ({r.get('PTR_Capacity','')}MVA {r.get('Voltage_Rating','')})"
                    ptr_map.setdefault(key, {})[d] = r.get("max_load", 0)

                datasets = []
                colors   = ["#1a56db", "#00c2cb", "#f59e0b", "#10b981",
                            "#ef4444", "#8b5cf6", "#f97316", "#06b6d4", "#ec4899", "#6366f1"]
                for i, (ptr_key, date_vals) in enumerate(ptr_map.items()):
                    datasets.append({
                        "label":           ptr_key,
                        "data":            [round(float(date_vals.get(d, 0) or 0), 2) for d in date_set],
                        "borderColor":     colors[i % len(colors)],
                        "backgroundColor": colors[i % len(colors)] + "18",
                        "fill":            False,
                        "tension":         0.3,
                        "pointRadius":     3
                    })
                if len(date_set) > 1:
                    chart = {"labels": date_set, "datasets": datasets}

            elif show_graph and len(df) > 1:
                chart = {
                    "labels": [f"PTR {str(r.get('sno',''))} ({str(r.get('PTR_Capacity',''))}MVA)" for r in records],
                    "datasets": [{
                        "label": "Peak Max Load (MVA)",
                        "data":  [round(float(r.get("max_load", 0) or 0), 2) for r in records],
                        "type":  "bar"
                    }]
                }

            return jsonify({"type": "table", "data": records, "chart": chart})

        # ════════════════════════════════════════════════════════════
        # LIST SUBSTATIONS  (all / filtered by circle, zone, or voltage)
        # ════════════════════════════════════════════════════════════
        elif msg.startswith("list substations"):
            filters_part = msg[len("list substations"):].strip()

            circle_match  = re.search(r'circle:(\S+)',  filters_part)
            zone_match    = re.search(r'zone:(\S+)',    filters_part)
            voltage_match = re.search(r'voltage:(\S+)', filters_part)

            where_clauses = []
            params        = []

            if circle_match:
                where_clauses.append("LOWER(circle) LIKE ?")
                params.append(f"%{circle_match.group(1).lower()}%")
            if zone_match:
                where_clauses.append("LOWER(zone) LIKE ?")
                params.append(f"%{zone_match.group(1).lower()}%")
            # NOTE: voltage filtering is NOT done here via SQL LIKE. Voltage
            # class isn't its own column — it's embedded in the substation
            # name's prefix (e.g. "132/33KV SS ...", "220/132KV SS ...",
            # "400/220/132KV SS ..."). The number the user wants can appear
            # ANYWHERE in that slash-separated prefix, not just immediately
            # before "KV" — so a plain SQL LIKE '%400kv%' misses
            # "400/220/132KV" entirely. Instead, all matching rows are fetched
            # first and filtered precisely in Python below (see _has_voltage),
            # checking each "/"-separated number in the prefix individually.

            where_sql = ("WHERE " + " AND ".join(where_clauses)) if where_clauses else ""

            df_list = pd.read_sql(
                f"""
                SELECT ss_id, sub_station_name, zone, circle
                FROM slis_substationdata
                {where_sql}
                ORDER BY sub_station_name
                """,
                conn, params=params
            )

            if voltage_match and not df_list.empty:
                target_voltage = voltage_match.group(1).lower().replace("kv", "").strip()

                def _has_voltage(name):
                    # Voltage prefix looks like "400/220/132KV SS ..." or
                    # "132/33KV SS ...". Take everything before "KV", split on
                    # "/", and check if the target number is exactly one of
                    # those parts (not a substring match, so searching "20"
                    # never wrongly matches "220").
                    prefix = str(name).lower().split("kv")[0]
                    parts  = re.split(r'[/\s]+', prefix)
                    return target_voltage in parts

                df_list = df_list[df_list["sub_station_name"].apply(_has_voltage)]

            if df_list.empty:
                return jsonify({"type": "text", "reply": "❌ No substations found matching that filter. Type 'help'"})

            filter_desc = []
            if circle_match:
                filter_desc.append(f"circle: {circle_match.group(1)}")
            if zone_match:
                filter_desc.append(f"zone: {zone_match.group(1)}")
            if voltage_match:
                filter_desc.append(f"voltage: {voltage_match.group(1)}KV")
            header = f"📋 {len(df_list)} substation(s)" + (f" ({', '.join(filter_desc)})" if filter_desc else "")

            return jsonify({"type": "table", "data": df_to_records(df_list),
                            "chart": None, "message": header})

        # ════════════════════════════════════════════════════════════
        # MASTER INFO  (zone / circle / PTR count)
        # ════════════════════════════════════════════════════════════
        elif "master info" in msg:
            # NOTE: ss_id was already resolved earlier in this function (either
            # from selected_ss_id passed by the picker, or from name-matching
            # msg against slis_substationdata). Reuse it here instead of
            # re-deriving the name and re-querying — otherwise a picker click
            # loops back into another picker.
            df_master = pd.read_sql(
                """
                SELECT s.ss_id, s.sub_station_name, s.zone, s.circle,
                       COUNT(c.sno) AS ptr_count
                FROM slis_substationdata s
                LEFT JOIN capacity_new c ON s.ss_id = c.ss_id
                WHERE s.ss_id = ?
                GROUP BY s.ss_id, s.sub_station_name, s.zone, s.circle
                """,
                conn, params=[ss_id]
            )

            if df_master.empty:
                return jsonify({"type": "text", "reply": "❌ Substation not found. Type 'help'"})

            row = df_master.iloc[0]
            reply = (
                f"🏭 **{row['sub_station_name']}**\n\n"
                f"• Zone: {row['zone']}\n"
                f"• Circle: {row['circle']}\n"
                f"• Power Transformers installed: {row['ptr_count']}"
            )
            return jsonify({"type": "text", "reply": reply})

        # ════════════════════════════════════════════════════════════
        # HELP
        # ════════════════════════════════════════════════════════════
        elif "help" in msg:
            return jsonify({"type": "text", "reply": (
                "📋 Commands:\n\n"
                "STATION MAX:\n"
                "• station max <name>\n"
                "• station max <name> 20.04.2026\n"
                "• station max <name> yesterday\n"
                "• station max <name> last 7 days\n"
                "• station max <name> april\n"
                "• station max <name> april 2025\n"
                "• station max <name> this month\n"
                "• station max <name> last month\n"
                "• station max <name> 2025\n"
                "• station max <name> last year\n"
                "• station max <name> this year\n"
                "• station max <name> ptr  → Peak + PTR details\n\n"
                "PTR DETAILS (shows ALL PTRs at substation):\n"
                "• ptr details <name>  → All PTRs, all-time peak\n"
                "• ptr details <name> 20.04.2026\n"
                "• ptr details <name> 20th april 2026\n"
                "• ptr details <name> 20 april 2026\n"
                "• ptr details <name> 20 april this year\n"
                "• ptr details <name> yesterday\n"
                "• ptr details <name> april max\n"
                "• ptr details <name> april all dates\n"
                "• ptr details <name> last 7 days max\n"
                "• ptr details <name> last 7 days all dates\n\n"
                "MASTER INFO (zone, circle, transformer count):\n"
                "• master info <name>\n\n"
                "SUBSTATION LISTS:\n"
                "• list all substations\n"
                "• list substations circle:<circle name>\n"
                "• list substations zone:<zone name>\n"
                "• list substations voltage:<400/220/132/33/11>"
            )})

        return jsonify({"type": "text", "reply": "❌ Not understood. Type 'help'"})

    except Exception as e:
        import traceback
        print("CHAT ERROR:", e)
        traceback.print_exc()
        return jsonify({"type": "text", "reply": "❌ Server error. Check Apache logs."})

    finally:
        if conn:
            conn.close()


@app.route("/api/chat", methods=["POST"])
def api_chat():
    """Chatbot for Flutter app — delegates to the same logic as web chat."""
    return chat()


# ─── EXPORT ───────────────────────────────────────────────────────────────────
@app.route("/export", methods=["POST"])
def export_excel():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401

    data      = request.json or {}
    ss_ids    = data.get("ss_ids", [])
    from_date = data.get("from_date")
    to_date   = data.get("to_date")

    if is_field_user() and caller_ss_id():
        ss_ids = [caller_ss_id()]

    conn = get_conn()
    if ss_ids:
        placeholders = ",".join(["?" for _ in ss_ids])
        df = pd.read_sql(
            f"SELECT * FROM dbo.SubStationLoad WHERE ss_id IN ({placeholders}) "
            "AND loaddate BETWEEN ? AND ?",
            conn, params=list(ss_ids) + [from_date, to_date]
        )
    else:
        df = pd.read_sql(
            "SELECT * FROM dbo.SubStationLoad WHERE loaddate BETWEEN ? AND ?",
            conn, params=[from_date, to_date]
        )
    conn.close()

    output = io.BytesIO()
    df.to_excel(output, index=False)
    output.seek(0)
    return send_file(output, download_name="load_data.xlsx", as_attachment=True)


# ─── DAILY ENTRY ──────────────────────────────────────────────────────────────
@app.route("/daily-entry", methods=["GET", "POST"])
def daily_entry():
    if not logged_in():
        return redirect(url_for("login"))
    if not is_field_user():
        return redirect(url_for("dashboard"))

    ss_id = session.get("ss_id")

    def _render(conn, success=None, error=None, selected_date=None):
        target_date = selected_date or request.values.get("date") or datetime.today().strftime("%Y-%m-%d")

        df_ptrs = pd.read_sql(
            """
            SELECT
                c.sno, c.ss_id, c.ss_name, c.PTR_Capacity, c.Voltage_Rating,
                c.Manufacturer, c.ManufSerialNo, c.ptr_ref,
                l.maxload, l.loadtime, l.minload, l.min_loadtime
            FROM capacity_new c
            LEFT JOIN SubStationLoad l
                ON c.ss_id = l.ss_id AND c.sno = l.sno AND l.loaddate = ?
            WHERE c.ss_id = ?
            ORDER BY
                TRY_CAST(LEFT(c.Voltage_Rating, CHARINDEX('/', c.Voltage_Rating + '/') - 1) AS INT) DESC,
                c.ptr_ref
            """,
            conn, params=[target_date, ss_id]
        )

        for col in ("loadtime", "min_loadtime"):
            df_ptrs[col] = df_ptrs[col].apply(
                lambda v: str(v)[:5] if v not in (None, "") and not pd.isnull(v) else None
            )

        return render_template(
            "daily_entry.html",
            ptrs          = df_to_records(df_ptrs),
            ss_name       = session.get("ss_name", ""),
            success       = success,
            error         = error,
            selected_date = target_date
        )

    conn = get_conn()
    try:
        if request.method == "GET":
            return _render(conn)

        cursor   = conn.cursor()
        form     = request.form
        loaddate = form.get("loaddate")
        remarks  = _norm(form.get("remarks"))

        if not loaddate:
            return _render(conn, error="Load date is required")

        cursor.execute(
            "SELECT sno, ss_name, PTR_Capacity, Voltage_Rating FROM capacity_new WHERE ss_id = ?" + PTR_ORDER,
            ss_id
        )
        ptrs = cursor.fetchall()

        saved = 0
        for sno, ss_name, ptr_cap, volt in ptrs:
            maxload  = _norm(form.get(f"maxload_{sno}"))
            loadtime = _norm(form.get(f"loadtime_{sno}"))
            minload  = _norm(form.get(f"minload_{sno}"))
            min_time = _norm(form.get(f"min_loadtime_{sno}"))
            if not any([maxload, loadtime, minload, min_time]):
                continue
            next_id = _next_available_id(cursor)
            upsert_load_row(
                cursor, next_id, sno, ss_id, ss_name, ptr_cap, volt,
                maxload, minload, min_time, loaddate, loadtime,
                session.get("mobile_no"), remarks
            )
            saved += 1

        if saved == 0:
            conn.rollback()
            return _render(conn, error="Enter at least one value before saving", selected_date=loaddate)

        conn.commit()
        return _render(
            conn,
            success=f"Saved values for {saved} PTR(s). You can fill the rest later — they'll be added to the same rows.",
            selected_date=loaddate
        )

    except Exception as e:
        conn.rollback()
        print("DAILY ENTRY ERROR:", e)
        return _render(conn, error="Failed to save. Please try again.")
    finally:
        conn.close()


# ─── TABLE VIEWS ──────────────────────────────────────────────────────────────
@app.route("/table/substationload")
def table_substationload():
    if not logged_in():
        return redirect(url_for("login"))
    conn = get_conn()
    if is_field_user():
        df = pd.read_sql(
            "SELECT * FROM SubStationLoad WHERE ss_id = ? ORDER BY id DESC",
            conn, params=[session.get("ss_id")]
        )
    else:
        df = pd.read_sql("SELECT * FROM SubStationLoad ORDER BY id DESC", conn)
    conn.close()

    df["loaddate"]   = pd.to_datetime(df["loaddate"], errors="coerce").dt.strftime("%d-%m-%Y")
    df["created_on"] = pd.to_datetime(df["created_on"], errors="coerce").dt.strftime("%d-%m-%Y %H:%M:%S")
    df["created_by"] = df["created_by"].apply(_clean_id)

    return render_template(
        "table_substationload.html",
        rows=df_to_records(df),
        columns=list(df.columns),
        can_edit=can_edit_load_data(),
    )


@app.route("/table/capacity")
def table_capacity():
    if not logged_in():
        return redirect(url_for("login"))
    conn = get_conn()
    df   = pd.read_sql("SELECT * FROM capacity_new ORDER BY ss_id, sno", conn)
    conn.close()
    return render_template("table_capacity.html", rows=df_to_records(df), columns=list(df.columns))


@app.route("/table/substations")
def table_substations():
    if not logged_in():
        return redirect(url_for("login"))
    conn = get_conn()
    df   = pd.read_sql("SELECT * FROM slis_substationdata ORDER BY ss_id", conn)
    conn.close()
    # Never render the field-user password column into a page any officer can open.
    df = df.drop(columns=[c for c in ("password",) if c in df.columns])
    if "mobile_no" in df.columns:
        df["mobile_no"] = df["mobile_no"].apply(_clean_id)
    return render_template("table_substations.html", rows=df_to_records(df), columns=list(df.columns))


@app.route("/api/admin/update_load_entry/<int:entry_id>", methods=["POST"])
def update_load_entry(entry_id):
    """Edit an existing SubStationLoad row from the Load Data table page."""
    if not can_edit_load_data():
        return jsonify({"success": False, "error": "Unauthorized"}), 403

    data = request.get_json(force=True)
    conn = get_conn()
    try:
        cursor = conn.cursor()

        # A field user may only edit rows belonging to their own substation,
        # and may not move a row to another substation.
        if is_field_user():
            own = caller_ss_id()
            cursor.execute("SELECT ss_id FROM SubStationLoad WHERE id = ?", entry_id)
            row = cursor.fetchone()
            if not row or str(row[0]) != str(own) or str(data.get("ss_id")) != str(own):
                conn.close()
                return jsonify({"success": False, "error": "Unauthorized"}), 403

        cursor.execute("""
            UPDATE SubStationLoad
            SET sno = ?, ss_id = ?, ss_name = ?, PTR_Capacity = ?, Voltage_Rating = ?,
                maxload = ?, minload = ?, min_loadtime = ?, loaddate = ?, loadtime = ?,
                created_by = ?, created_on = ?, remarks = ?
            WHERE id = ?
        """,
            data.get("sno"), data.get("ss_id"), data.get("ss_name"),
            data.get("PTR_Capacity"), data.get("Voltage_Rating"),
            data.get("maxload"), data.get("minload"), data.get("min_loadtime"),
            data.get("loaddate"), data.get("loadtime"),
            data.get("created_by"), data.get("created_on"),
            data.get("remarks", ""),
            entry_id
        )
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
        cursor = conn.cursor()

        if is_field_user():
            own = caller_ss_id()
            cursor.execute("SELECT ss_id FROM SubStationLoad WHERE id = ?", entry_id)
            row = cursor.fetchone()
            if not row or str(row[0]) != str(own):
                conn.close()
                return jsonify({"success": False, "error": "Unauthorized"}), 403

        cursor.execute("DELETE FROM SubStationLoad WHERE id = ?", entry_id)
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

    conn = get_conn()
    df = pd.read_sql(
        "SELECT ss_id, dist_name, sub_station_name, voltage, mobile_no, zone, circle "
        "FROM slis_substationdata ORDER BY ss_id", conn
    )
    df_off     = pd.read_sql(
        "SELECT id, username, is_admin, is_first_login, password_expiry FROM users ORDER BY username", conn)
    df_zones   = pd.read_sql("SELECT DISTINCT zone FROM slis_substationdata ORDER BY zone", conn)
    df_circles = pd.read_sql("SELECT DISTINCT circle FROM slis_substationdata ORDER BY circle", conn)
    conn.close()

    df["mobile_no"] = df["mobile_no"].apply(_clean_id)

    return render_template(
        "admin_settings.html",
        substations = df_to_records(df),
        officers    = df_to_records(df_off),
        zones       = df_zones["zone"].dropna().tolist(),
        circles     = df_circles["circle"].dropna().tolist()
    )


@app.route("/admin/add_user", methods=["POST"])
def admin_add_user():
    if not is_admin():
        return redirect(url_for("login"))

    form      = request.form
    user_type = form.get("user_type", "field")
    conn      = get_conn()
    cursor    = conn.cursor()

    try:
        if user_type == "officer":
            username = form.get("username", "").strip()
            password = form.get("officer_password", "").strip() or "password@123"
            hashed   = generate_password_hash(password)
            cursor.execute(
                "INSERT INTO users (username, password_hash, is_admin, is_first_login) VALUES (?, ?, 0, 1)",
                username, hashed
            )
        else:
            cursor.execute("""
                INSERT INTO slis_substationdata
                    (ss_id, dist_code, dist_name, sub_station_name, voltage, mobile_no, password, zone, circle)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
                form.get("ss_id"), form.get("dist_code"), form.get("dist_name"),
                form.get("sub_station_name"), form.get("voltage"),
                form.get("mobile_no"), form.get("password"),
                form.get("zone"), form.get("circle")
            )
        conn.commit()
    except Exception as e:
        conn.rollback()
        print("ADD USER ERROR:", e)
    finally:
        conn.close()
    return redirect(url_for("admin_settings"))


@app.route("/admin/delete_user/<int:ss_id>", methods=["POST"])
def admin_delete_user(ss_id):
    if not is_admin():
        return redirect(url_for("login"))

    conn   = get_conn()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM slis_substationdata WHERE ss_id = ?", ss_id)
        conn.commit()
    except Exception as e:
        conn.rollback()
        print("DELETE USER ERROR:", e)
    finally:
        conn.close()
    return redirect(url_for("admin_settings"))


@app.route("/api/admin/update_ptr_ref/<int:sno>", methods=["POST"])
def update_ptr_ref(sno):
    if not is_admin():
        return jsonify({"success": False, "error": "Unauthorized"}), 403
    data    = request.get_json(force=True)
    ptr_ref = data.get("ptr_ref")
    if ptr_ref is None or str(ptr_ref).strip() == "":
        return jsonify({"success": False, "error": "ptr_ref is required"}), 400
    conn = get_conn()
    try:
        cursor = conn.cursor()
        cursor.execute("UPDATE capacity_new SET ptr_ref = ? WHERE sno = ?", ptr_ref, sno)
        if cursor.rowcount == 0:
            conn.rollback()
            conn.close()
            return jsonify({"success": False, "error": "Row not found"}), 404
        conn.commit()
        conn.close()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        conn.close()
        print("UPDATE PTR_REF ERROR:", e)
        return jsonify({"success": False, "error": str(e)}), 500


# ─── ADMIN API (Flutter) ──────────────────────────────────────────────────────
@app.route("/api/admin/users", methods=["GET"])
def api_admin_users():
    if not is_admin():
        return jsonify({"error": "Unauthorized"}), 403
    try:
        conn = get_conn()
        df = pd.read_sql(
            "SELECT ss_id, dist_name, sub_station_name, voltage, mobile_no, zone, circle "
            "FROM slis_substationdata ORDER BY ss_id", conn
        )
        conn.close()
        df["mobile_no"] = df["mobile_no"].apply(_clean_id)
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/admin/officers", methods=["GET"])
def api_admin_officers():
    if not is_admin():
        return jsonify({"error": "Unauthorized"}), 403
    conn = get_conn()
    df   = pd.read_sql("SELECT id, username, is_first_login FROM users ORDER BY username", conn)
    conn.close()
    return jsonify(df_to_records(df))


@app.route("/api/admin/add_user", methods=["POST"])
def api_admin_add_user():
    if not is_admin():
        return jsonify({"error": "Unauthorized"}), 403
    data      = request.json or {}
    user_type = data.get("user_type", "field")
    conn      = get_conn()
    cursor    = conn.cursor()
    try:
        if user_type == "officer":
            username = (data.get("username") or "").strip()
            password = (data.get("officer_password") or data.get("password") or "").strip() or "password@123"
            hashed   = generate_password_hash(password)
            cursor.execute(
                "INSERT INTO users (username, password_hash, is_admin, is_first_login) VALUES (?, ?, 0, 1)",
                username, hashed
            )
        else:
            cursor.execute("""
                INSERT INTO slis_substationdata
                    (ss_id, dist_code, dist_name, sub_station_name, voltage, mobile_no, password, zone, circle)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
                data.get("ss_id"), data.get("dist_code"), data.get("dist_name"),
                data.get("sub_station_name"), data.get("voltage"),
                data.get("mobile_no"), data.get("password"),
                data.get("zone"), data.get("circle")
            )
        conn.commit()
        conn.close()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        conn.close()
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/admin/delete_user/<int:ss_id>", methods=["DELETE"])
def api_admin_delete_user(ss_id):
    if not is_admin():
        return jsonify({"error": "Unauthorized"}), 403
    conn   = get_conn()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM slis_substationdata WHERE ss_id = ?", ss_id)
        conn.commit()
        conn.close()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        conn.close()
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/admin/change_password", methods=["POST"])
def api_admin_change_password():
    if not logged_in():
        return jsonify({"error": "Unauthorized"}), 403

    data     = request.json or {}
    ss_id    = data.get("ss_id", "")
    new_pass = data.get("new_password")

    if not ss_id or not new_pass:
        return jsonify({"error": "ss_id and new_password are required"}), 400

    # A field user may only change their OWN password. Everything else is admin.
    if is_field_user():
        own = caller_ss_id()
        if not own or ss_id != f"field_{own}":
            return jsonify({"error": "Unauthorized"}), 403
    elif not is_admin():
        return jsonify({"error": "Unauthorized"}), 403

    conn   = get_conn()
    cursor = conn.cursor()
    try:
        if ss_id.startswith("officer_"):
            officer_id = ss_id.replace("officer_", "")
            hashed = generate_password_hash(new_pass)
            cursor.execute(
                "UPDATE users SET password_hash=?, is_first_login=0 WHERE id=?",
                hashed, officer_id
            )
        else:
            field_id = ss_id.replace("field_", "")
            cursor.execute(
                "UPDATE slis_substationdata SET password=? WHERE ss_id=?",
                new_pass, field_id
            )
        conn.commit()
        conn.close()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        conn.close()
        return jsonify({"success": False, "error": str(e)}), 500


# ─── API ENDPOINTS (for Flutter app) ──────────────────────────────────────────
@app.route("/api/login", methods=["POST"])
def api_login():
    data     = request.get_json(force=True)
    username = data.get("username", "").strip()
    password = data.get("password", "").strip()

    if not username or not password:
        return jsonify({"success": False, "error": "Username and password required"}), 400

    if username == "admin" and password == os.environ.get("SLIS_BOOTSTRAP_ADMIN_PW", "admin@123"):
        return jsonify({"success": True, "role": "admin", "user": "admin",
                        "ss_id": None, "ss_name": None,
                        "token": app.config.get("API_TOKEN")})

    conn = None
    try:
        conn   = get_conn()
        cursor = conn.cursor()

        df = pd.read_sql("SELECT * FROM users WHERE username=?", conn, params=[username])

        if not df.empty:
            user = df.iloc[0].to_dict()
            if user.get("is_locked"):
                return jsonify({"success": False, "error": "Account locked. Contact admin"}), 403

            if check_password_hash(user["password_hash"], password):
                cursor.execute(
                    "UPDATE users SET failed_attempts=0, is_locked=0, lock_time=NULL WHERE username=?",
                    username
                )
                conn.commit()
                role = "admin" if user.get("is_admin") else "officer"
                return jsonify({
                    "success":     True,
                    "role":        role,
                    "user":        username,
                    "ss_id":       None,
                    "ss_name":     None,
                    "first_login": bool(user.get("is_first_login")),
                    "token":       app.config.get("API_TOKEN")
                })

            attempts = (user.get("failed_attempts") or 0) + 1
            if attempts >= MAX_ATTEMPTS:
                cursor.execute(
                    "UPDATE users SET failed_attempts=?, is_locked=1, lock_time=GETDATE() WHERE username=?",
                    attempts, username
                )
            else:
                cursor.execute("UPDATE users SET failed_attempts=? WHERE username=?", attempts, username)
            conn.commit()
            return jsonify({"success": False, "error": f"Invalid credentials ({attempts}/3)"}), 401

        # Field user
        df_field = pd.read_sql(
            "SELECT ss_id, sub_station_name, mobile_no, password, zone, circle "
            "FROM slis_substationdata WHERE mobile_no = ?",
            conn, params=[username]
        )

        if not df_field.empty:
            fu = df_field.iloc[0].to_dict()
            if str(fu["password"]) == password:
                return jsonify({
                    "success": True, "role": "field", "user": username,
                    "ss_id": fu["ss_id"], "ss_name": fu["sub_station_name"],
                    "zone": fu.get("zone"), "circle": fu.get("circle"),
                    "token": app.config.get("API_TOKEN")
                })
            return jsonify({"success": False, "error": "Invalid credentials"}), 401

        return jsonify({"success": False, "error": "User not found"}), 404

    except Exception as e:
        print("API LOGIN ERROR:", e)
        return jsonify({"success": False, "error": "Server error"}), 500
    finally:
        if conn:
            conn.close()


@app.route("/api/ptrs/<int:ss_id>")
def api_ptrs(ss_id):
    """PTRs for a substation, prefilled with today's (or ?date=) existing
    SubStationLoad values, same as the website's Daily Entry page."""
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    if is_field_user() and str(caller_ss_id()) != str(ss_id):
        return jsonify({"error": "Unauthorized"}), 403
    try:
        target_date = request.args.get("date") or datetime.today().strftime("%Y-%m-%d")
        conn = get_conn()
        df = pd.read_sql(
            """
            SELECT
                c.sno, c.ss_id, c.ss_name, c.PTR_Capacity, c.Voltage_Rating,
                c.Manufacturer, c.ManufSerialNo, c.ptr_ref,
                l.maxload, l.loadtime, l.minload, l.min_loadtime
            FROM capacity_new c
            LEFT JOIN SubStationLoad l
                ON c.ss_id = l.ss_id AND c.sno = l.sno AND l.loaddate = ?
            WHERE c.ss_id = ?
            ORDER BY
                TRY_CAST(LEFT(c.Voltage_Rating, CHARINDEX('/', c.Voltage_Rating + '/') - 1) AS INT) DESC,
                c.ptr_ref
            """,
            conn, params=[target_date, ss_id]
        )
        conn.close()

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
    if not can_edit_load_data():
        return jsonify({"success": False, "error": "Unauthorized"}), 403

    data    = request.get_json(force=True)
    entries = data.get("entries", [])

    entries = [
        e for e in entries
        if any([_norm(e.get("maxload")), _norm(e.get("loadtime")),
                _norm(e.get("minload")), _norm(e.get("min_loadtime"))])
    ]
    if not entries:
        return jsonify({"success": False, "error": "Enter at least one value before saving"}), 400

    # A field user can only write rows for their own substation.
    if is_field_user():
        own = caller_ss_id()
        if not own or any(str(e.get("ss_id")) != str(own) for e in entries):
            return jsonify({"success": False, "error": "Unauthorized"}), 403

    conn   = get_conn()
    cursor = conn.cursor()
    try:
        for e in entries:
            if not e.get("sno") or not e.get("loaddate"):
                conn.rollback()
                conn.close()
                return jsonify({"success": False, "error": "sno and loaddate are required"}), 400
            next_id = _next_available_id(cursor)
            upsert_load_row(
                cursor, next_id, e.get("sno"), e.get("ss_id"), e.get("ss_name"),
                e.get("PTR_Capacity"), e.get("Voltage_Rating"),
                _norm(e.get("maxload")), _norm(e.get("minload")),
                _norm(e.get("min_loadtime")), e.get("loaddate"),
                _norm(e.get("loadtime")),
                e.get("created_by"), _norm(e.get("remarks"))
            )

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
    """Load data for the Flutter dashboard."""
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        data      = request.get_json(force=True)
        ss_ids    = data.get("ss_ids", [])
        from_date = data.get("from_date")
        to_date   = data.get("to_date")

        if is_field_user() and caller_ss_id():
            ss_ids = [caller_ss_id()]

        if not ss_ids:
            return jsonify([])

        placeholders = ",".join(["?" for _ in ss_ids])
        conn = get_conn()
        df   = pd.read_sql(
            f"""
            SELECT l.*, c.Manufacturer, c.ManufSerialNo, c.YoM, c.Doc
            FROM SubStationLoad l
            LEFT JOIN capacity_new c ON l.ss_id = c.ss_id AND l.sno = c.sno
            WHERE l.ss_id IN ({placeholders}) AND l.loaddate BETWEEN ? AND ?
            ORDER BY l.loaddate DESC
            """,
            conn, params=list(ss_ids) + [from_date, to_date]
        )
        conn.close()
        df["loaddate"]   = df["loaddate"].astype(str)
        df["created_on"] = df["created_on"].astype(str)
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/load_data_all")
def api_load_data_all():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        # Scope comes from the authenticated caller, not from query params.
        if is_field_user() and caller_ss_id():
            df = pd.read_sql(
                "SELECT * FROM SubStationLoad WHERE ss_id = ? ORDER BY id DESC",
                conn, params=[caller_ss_id()]
            )
        else:
            df = pd.read_sql("SELECT * FROM SubStationLoad ORDER BY id DESC", conn)
        conn.close()
        df["loaddate"]   = df["loaddate"].astype(str)
        df["created_on"] = df["created_on"].astype(str)
        df["created_by"] = df["created_by"].apply(_clean_id)
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/capacity")
def api_capacity():
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df = pd.read_sql(
            "SELECT c.sno, c.ss_id, c.ss_name, c.PTR_Capacity, c.Voltage_Rating, "
            "c.Manufacturer, c.ManufSerialNo, c.YoM, c.Doc, c.ptr_ref "
            "FROM capacity_new c ORDER BY c.ss_id, c.ptr_ref",
            conn
        )
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/substations")
def api_substations():
    """All substations for Flutter filter dropdowns."""
    if not logged_in():
        return jsonify({"error": "Not logged in"}), 401
    try:
        conn = get_conn()
        df   = pd.read_sql(
            "SELECT ss_id, sub_station_name, zone, circle FROM slis_substationdata ORDER BY sub_station_name",
            conn
        )
        conn.close()
        return jsonify(df_to_records(df))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(debug=False)
