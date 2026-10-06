import hmac
import os
import re
import secrets

from flask import Flask, abort, flash, redirect, render_template_string, request, session, url_for

from . import pipeline
from .db import connect
from .naming import schema, validate_client

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>TheReporter Admin</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f4f6f8;color:#222}
header{background:#1f3a5f;color:#fff;padding:14px 28px;font-size:20px}
main{max-width:960px;margin:24px auto;padding:0 16px}
.card{background:#fff;border-radius:6px;padding:20px;margin-bottom:24px;box-shadow:0 1px 3px #0002}
label{display:block;margin-top:12px;font-weight:600}
input{width:100%;padding:8px;margin-top:4px;box-sizing:border-box;border:1px solid #bbb;border-radius:4px}
small{color:#666}button{margin-top:16px;background:#1f3a5f;color:#fff;border:0;padding:10px 20px;border-radius:4px;cursor:pointer}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px;border-bottom:1px solid #e3e3e3;font-size:14px}
.msg{padding:10px 14px;border-radius:4px;margin-bottom:12px}.ok{background:#dff3e3}.err{background:#fbe0e0}
code{background:#eef;padding:1px 4px;border-radius:3px}
</style></head><body><header>TheReporter &mdash; Client Administration</header><main>
{% for cat, m in get_flashed_messages(with_categories=true) %}<div class="msg {{cat}}">{{m}}</div>{% endfor %}
<div class="card"><h2>Onboard a new client</h2>
<form method="post" action="{{ url_for('onboard') }}">
<input type="hidden" name="csrf" value="{{ csrf }}">
<label>Client ID <input name="client" required maxlength="30" pattern="[A-Za-z][A-Za-z0-9_]{0,29}" value="{{ form.client }}">
<small>Letters, digits and underscore; starts with a letter. Used as the schema prefix, e.g. <code>acme_stg</code>, <code>acme_ods</code>, <code>acme_dw</code>.</small></label>
<label>Display name <input name="display_name" maxlength="100" value="{{ form.display_name }}"></label>
<label>Contact email <input name="contact_email" type="email" maxlength="255" value="{{ form.contact_email }}"></label>
<button type="submit">Onboard client</button></form></div>
<div class="card"><h2>Clients</h2>
{% if clients %}<table><tr><th>Client ID</th><th>Name</th><th>Contact</th><th>Schemas</th><th>Loads</th><th>Rows</th><th>Created</th></tr>
{% for c in clients %}<tr><td>{{c[0]}}</td><td>{{c[1] or ''}}</td><td>{{c[2] or ''}}</td>
<td><code>{{c[0]}}_stg</code> <code>{{c[0]}}_ods</code> <code>{{c[0]}}_dw</code></td><td>{{c[4]}}</td><td>{{c[5]}}</td><td>{{c[3]}}</td></tr>{% endfor %}</table>
{% else %}<p>No clients yet.</p>{% endif %}</div></main></body></html>"""


def create_app():
    app = Flask(__name__)
    app.secret_key = os.environ.get("REPORTER_SECRET") or secrets.token_hex(32)

    def csrf_token():
        if "csrf" not in session:
            session["csrf"] = secrets.token_hex(16)
        return session["csrf"]

    def render(form=None):
        conn = connect()
        try:
            clients = pipeline.client_overview(conn)
        finally:
            conn.close()
        form = form or {"client": "", "display_name": "", "contact_email": ""}
        return render_template_string(PAGE, clients=clients, form=form, csrf=csrf_token())

    @app.get("/")
    def index():
        try:
            return render()
        except Exception as e:
            return f"Cannot reach MySQL: {e}", 500

    @app.post("/onboard")
    def onboard():
        if not hmac.compare_digest(request.form.get("csrf", ""), session.get("csrf", "")):
            abort(400)
        form = {k: request.form.get(k, "").strip() for k in ("client", "display_name", "contact_email")}
        try:
            client = validate_client(form["client"])
            if form["contact_email"] and not EMAIL_RE.match(form["contact_email"]):
                raise ValueError("Invalid contact email")
            conn = connect()
            try:
                if pipeline.client_exists(conn, client):
                    raise ValueError(f"Client '{client}' already exists")
                pipeline.add_client(conn, client, form["display_name"][:100], form["contact_email"])
            finally:
                conn.close()
        except ValueError as e:
            flash(str(e), "err")
            return render(form)
        except Exception as e:
            flash(f"Onboarding failed: {e}", "err")
            return render(form)
        flash(
            f"Client '{client}' onboarded. Created schemas: "
            + ", ".join(schema(client, t) for t in ("stg", "ods", "dw")),
            "ok",
        )
        return redirect(url_for("index"))

    return app


def main():
    # Bound to localhost only: there is no authentication.
    create_app().run(host="127.0.0.1", port=int(os.environ.get("REPORTER_PORT", "5000")))


if __name__ == "__main__":
    main()
