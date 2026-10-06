import csv
from datetime import datetime

from .db import ensure_admin
from .inference import ColumnProfile, converter
from .naming import (ADMIN_SCHEMA, q, sanitize, sanitize_headers, schema,
                     validate_client)

BATCH = 2000
ADM = q(ADMIN_SCHEMA)


def _columns(cur, sch, table):
    cur.execute(
        "SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE FROM information_schema.COLUMNS "
        "WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s ORDER BY ORDINAL_POSITION",
        (sch, table),
    )
    return [(r[0], r[1], r[2]) for r in cur.fetchall()]


def _data_cols(cols):
    return [c for c in cols if not c[0].startswith("_")]


def _key_cols(cur, client, table):
    cur.execute(
        f"SELECT key_columns FROM {ADM}.table_config WHERE client=%s AND table_name=%s",
        (client, table),
    )
    row = cur.fetchone()
    return [k for k in row[0].split(",") if k] if row and row[0] else []


def add_client(conn, client, display_name=None, contact_email=None):
    client = validate_client(client)
    ensure_admin(conn)
    with conn.cursor() as cur:
        for tier in ("stg", "ods", "dw"):
            cur.execute(
                f"CREATE DATABASE IF NOT EXISTS {q(schema(client, tier))} CHARACTER SET utf8mb4"
            )
        cur.execute(
            f"INSERT IGNORE INTO {ADM}.clients (client, display_name, contact_email) VALUES (%s,%s,%s)",
            (client, display_name or None, contact_email or None),
        )
    conn.commit()
    return client


def list_clients(conn):
    ensure_admin(conn)
    with conn.cursor() as cur:
        cur.execute(f"SELECT client, created_at FROM {ADM}.clients ORDER BY client")
        return cur.fetchall()


def client_exists(conn, client):
    ensure_admin(conn)
    with conn.cursor() as cur:
        cur.execute(f"SELECT 1 FROM {ADM}.clients WHERE client=%s", (validate_client(client),))
        return cur.fetchone() is not None


def client_overview(conn):
    ensure_admin(conn)
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT c.client, c.display_name, c.contact_email, c.created_at, "
            f"(SELECT COUNT(*) FROM {ADM}.load_log l WHERE l.client=c.client), "
            f"(SELECT COALESCE(SUM(rows_loaded),0) FROM {ADM}.load_log l WHERE l.client=c.client) "
            f"FROM {ADM}.clients c ORDER BY c.client"
        )
        return cur.fetchall()


def _require_client(cur, client):
    client = validate_client(client)
    cur.execute(f"SELECT 1 FROM {ADM}.clients WHERE client=%s", (client,))
    if not cur.fetchone():
        raise ValueError(f"Unknown client '{client}'. Run: reporter add-client {client}")
    return client


# ---------------------------------------------------------------- STG
def import_csv(conn, client, path, table=None, key=None, delimiter=","):
    ensure_admin(conn)
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh, delimiter=delimiter)
        try:
            raw_headers = next(reader)
        except StopIteration:
            raise ValueError("CSV file is empty")
        headers = sanitize_headers(raw_headers)
        table = sanitize(table or path.rsplit("\\", 1)[-1].rsplit("/", 1)[-1].rsplit(".", 1)[0], "data")
        key_cols = [sanitize(k) for k in key.split(",")] if key else None
        if key_cols:
            missing = [k for k in key_cols if k not in headers]
            if missing:
                raise ValueError(f"Key columns not in CSV: {missing}")

        with conn.cursor() as cur:
            client = _require_client(cur, client)
            stg = schema(client, "stg")
            stg_table = f"stg_{table}"
            existing = [c[0] for c in _columns(cur, stg, stg_table)]
            if not existing:
                coldefs = ", ".join(f"{q(h)} TEXT NULL" for h in headers)
                cur.execute(
                    f"CREATE TABLE {q(stg)}.{q(stg_table)} ("
                    "_stg_id BIGINT AUTO_INCREMENT PRIMARY KEY, _load_id BIGINT NOT NULL, "
                    f"_row_num INT NOT NULL, {coldefs}, KEY ix_load (_load_id))"
                )
            else:
                for h in headers:
                    if h not in existing:
                        cur.execute(f"ALTER TABLE {q(stg)}.{q(stg_table)} ADD COLUMN {q(h)} TEXT NULL")
            if key_cols is not None:
                cur.execute(
                    f"INSERT INTO {ADM}.table_config (client, table_name, key_columns) VALUES (%s,%s,%s) "
                    "ON DUPLICATE KEY UPDATE key_columns=VALUES(key_columns)",
                    (client, table, ",".join(key_cols)),
                )
            else:
                cur.execute(
                    f"INSERT IGNORE INTO {ADM}.table_config (client, table_name) VALUES (%s,%s)",
                    (client, table),
                )
            cur.execute(
                f"INSERT INTO {ADM}.load_log (client, table_name, source_file) VALUES (%s,%s,%s)",
                (client, table, path[-500:]),
            )
            load_id = cur.lastrowid

            sql = (
                f"INSERT INTO {q(stg)}.{q(stg_table)} (_load_id, _row_num, "
                + ", ".join(q(h) for h in headers)
                + ") VALUES (%s, %s, " + ", ".join(["%s"] * len(headers)) + ")"
            )
            batch, loaded, rejected = [], 0, 0

            def flush():
                nonlocal batch
                if batch:
                    cur.executemany(sql, batch)
                    batch = []

            for n, row in enumerate(reader, 2):
                if not row or all(c.strip() == "" for c in row):
                    continue
                if len(row) != len(headers):
                    rejected += 1
                    cur.execute(
                        f"INSERT INTO {ADM}.reject_log (load_id,row_num,reason) VALUES (%s,%s,%s)",
                        (load_id, n, f"Expected {len(headers)} fields, got {len(row)}"),
                    )
                    continue
                batch.append((load_id, n, *[c.strip() for c in row]))
                loaded += 1
                if len(batch) >= BATCH:
                    flush()
            flush()
            cur.execute(
                f"UPDATE {ADM}.load_log SET rows_loaded=%s, rows_rejected=%s WHERE load_id=%s",
                (loaded, rejected, load_id),
            )
        conn.commit()
    return load_id, table, loaded, rejected


# ---------------------------------------------------------------- ODS
def promote(conn, client, table, date_fmt=None, datetime_fmt=None):
    ensure_admin(conn)
    with conn.cursor() as cur:
        client = _require_client(cur, client)
        stg, ods = schema(client, "stg"), schema(client, "ods")
        stg_table = f"stg_{table}"
        cur.execute(
            f"SELECT load_id FROM {ADM}.load_log WHERE client=%s AND table_name=%s AND status='STAGED'",
            (client, table),
        )
        loads = [r[0] for r in cur.fetchall()]
        if not loads:
            return 0, 0
        in_clause = ",".join(str(int(i)) for i in loads)
        cols = [c[0] for c in _data_cols(_columns(cur, stg, stg_table))]
        if not cols:
            raise ValueError(f"No staging table for '{table}'")
        keys = _key_cols(cur, client, table)
        sel = ", ".join(q(c) for c in cols)
        where = f"_load_id IN ({in_clause})"

        def pages():
            last = 0
            while True:
                cur.execute(
                    f"SELECT _stg_id, _load_id, _row_num, {sel} FROM {q(stg)}.{q(stg_table)} "
                    f"WHERE {where} AND _stg_id > %s ORDER BY _stg_id LIMIT {BATCH}",
                    (last,),
                )
                rows = cur.fetchall()
                if not rows:
                    return
                last = rows[-1][0]
                yield rows

        ods_cols = {c[0]: c for c in _data_cols(_columns(cur, ods, table))}
        new_cols = [c for c in cols if c not in ods_cols]
        types = {}
        if new_cols:
            profiles = {c: ColumnProfile(date_fmt, datetime_fmt) for c in new_cols}
            idx = {c: cols.index(c) + 3 for c in new_cols}
            for rows in pages():
                for r in rows:
                    for c in new_cols:
                        profiles[c].add(r[idx[c]])
            for c in new_cols:
                t = profiles[c].mysql_type()
                types[c] = "VARCHAR(255)" if (c in keys and t == "TEXT") else t
        if not ods_cols:
            coldefs = ", ".join(f"{q(c)} {types[c]} NULL" for c in cols)
            uq = f", UNIQUE KEY uq_business_key ({', '.join(q(k) for k in keys)})" if keys else ""
            cur.execute(
                f"CREATE TABLE {q(ods)}.{q(table)} (_ods_id BIGINT AUTO_INCREMENT PRIMARY KEY, {coldefs}, "
                "_ods_loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "
                f"_ods_updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP{uq})"
            )
        else:
            for c in new_cols:
                cur.execute(f"ALTER TABLE {q(ods)}.{q(table)} ADD COLUMN {q(c)} {types[c]} NULL")
        data_types = {c: ods_cols[c][1] for c in ods_cols}
        data_types.update({c: types[c].split("(")[0] for c in types})
        conv = [converter(data_types[c], date_fmt, datetime_fmt) for c in cols]
        key_idx = [cols.index(k) for k in keys]

        insert = (
            f"INSERT INTO {q(ods)}.{q(table)} ({sel}) VALUES ({', '.join(['%s'] * len(cols))})"
        )
        if keys:
            upd = ", ".join(f"{q(c)}=VALUES({q(c)})" for c in cols if c not in keys) or \
                f"{q(keys[0])}=VALUES({q(keys[0])})"
            insert += " ON DUPLICATE KEY UPDATE " + upd

        promoted = rejected = 0
        reject_rows = []
        for rows in pages():
            good = []
            for r in rows:
                _, load_id, row_num, *vals = r
                try:
                    if any(vals[i] in (None, "") for i in key_idx):
                        raise ValueError("empty key value")
                    good.append([None if v in (None, "") else f(v) for f, v in zip(conv, vals)])
                except ValueError as e:
                    rejected += 1
                    reject_rows.append((load_id, row_num, f"Conversion failed: {e}"[:500]))
            if good:
                cur.executemany(insert, good)
                promoted += len(good)
        if reject_rows:
            cur.executemany(
                f"INSERT INTO {ADM}.reject_log (load_id,row_num,reason) VALUES (%s,%s,%s)", reject_rows
            )
        cur.execute(
            f"UPDATE {ADM}.load_log SET status='PROMOTED', promoted_at=NOW() WHERE load_id IN ({in_clause})"
        )
    conn.commit()
    return promoted, rejected


# ---------------------------------------------------------------- DW
def build_dw(conn, client, table):
    """Maintain a Type-2 slowly changing dimension in the DW from the ODS table."""
    ensure_admin(conn)
    with conn.cursor() as cur:
        client = _require_client(cur, client)
        ods, dw = schema(client, "ods"), schema(client, "dw")
        keys = _key_cols(cur, client, table)
        if not keys:
            raise ValueError(f"Table '{table}' has no key; import with --key to enable DW history")
        ocols = _data_cols(_columns(cur, ods, table))
        if not ocols:
            raise ValueError(f"No ODS table for '{table}'; run promote first")
        names = [c[0] for c in ocols]
        dcols = {c[0] for c in _columns(cur, dw, table)}
        if not dcols:
            coldefs = ", ".join(f"{q(c[0])} {c[2]} NULL" for c in ocols)
            cur.execute(
                f"CREATE TABLE {q(dw)}.{q(table)} (_sk BIGINT AUTO_INCREMENT PRIMARY KEY, {coldefs}, "
                "_row_hash CHAR(64) NOT NULL, _valid_from DATETIME NOT NULL, _valid_to DATETIME NULL, "
                f"_is_current TINYINT(1) NOT NULL, KEY ix_bk ({', '.join(q(k) for k in keys)}, _is_current))"
            )
        else:
            for c in ocols:
                if c[0] not in dcols:
                    cur.execute(f"ALTER TABLE {q(dw)}.{q(table)} ADD COLUMN {q(c[0])} {c[2]} NULL")

        hash_expr = "SHA2(CONCAT_WS('||', " + ", ".join(
            f"IFNULL(CAST(o.{q(n)} AS CHAR), '~NULL~')" for n in names) + "), 256)"
        join = " AND ".join(f"d.{q(k)} = o.{q(k)}" for k in keys)
        now = datetime.now().replace(microsecond=0)
        T_D, T_O = f"{q(dw)}.{q(table)}", f"{q(ods)}.{q(table)}"

        cur.execute(
            f"UPDATE {T_D} d JOIN {T_O} o ON {join} SET d._valid_to=%s, d._is_current=0 "
            f"WHERE d._is_current=1 AND d._row_hash <> {hash_expr}", (now,))
        expired = cur.rowcount
        cur.execute(
            f"INSERT INTO {T_D} ({', '.join(q(n) for n in names)}, _row_hash, _valid_from, _valid_to, _is_current) "
            f"SELECT {', '.join('o.' + q(n) for n in names)}, {hash_expr}, %s, NULL, 1 FROM {T_O} o "
            f"WHERE NOT EXISTS (SELECT 1 FROM {T_D} d WHERE d._is_current=1 AND {join} "
            f"AND d._row_hash = {hash_expr})", (now,))
        inserted = cur.rowcount
        cur.execute(
            f"CREATE OR REPLACE VIEW {q(dw)}.{q(table + '_current')} AS "
            f"SELECT {', '.join(q(n) for n in names)} FROM {T_D} WHERE _is_current=1"
        )
    conn.commit()
    return inserted, expired


def status(conn, client):
    ensure_admin(conn)
    with conn.cursor() as cur:
        client = _require_client(cur, client)
        cur.execute(
            f"SELECT load_id, table_name, source_file, rows_loaded, rows_rejected, status, loaded_at "
            f"FROM {ADM}.load_log WHERE client=%s ORDER BY load_id DESC LIMIT 50", (client,))
        return cur.fetchall()
