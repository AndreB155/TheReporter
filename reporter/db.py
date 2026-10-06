import os
from pathlib import Path

import pymysql

from .naming import ADMIN_SCHEMA, q


def _load_dotenv():
    p = Path(".env")
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def connect():
    _load_dotenv()
    return pymysql.connect(
        host=os.environ.get("MYSQL_HOST", "127.0.0.1"),
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ.get("MYSQL_USER", "root"),
        password=os.environ.get("MYSQL_PASSWORD", ""),
        charset="utf8mb4",
        autocommit=False,
        local_infile=False,
    )


ADMIN_DDL = [
    f"CREATE DATABASE IF NOT EXISTS {q(ADMIN_SCHEMA)} CHARACTER SET utf8mb4",
    f"""CREATE TABLE IF NOT EXISTS {q(ADMIN_SCHEMA)}.clients (
        client VARCHAR(30) PRIMARY KEY,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)""",
    f"""CREATE TABLE IF NOT EXISTS {q(ADMIN_SCHEMA)}.table_config (
        client VARCHAR(30) NOT NULL,
        table_name VARCHAR(60) NOT NULL,
        key_columns VARCHAR(500) NULL,
        PRIMARY KEY (client, table_name))""",
    f"""CREATE TABLE IF NOT EXISTS {q(ADMIN_SCHEMA)}.load_log (
        load_id BIGINT AUTO_INCREMENT PRIMARY KEY,
        client VARCHAR(30) NOT NULL,
        table_name VARCHAR(60) NOT NULL,
        source_file VARCHAR(500) NOT NULL,
        rows_loaded INT NOT NULL DEFAULT 0,
        rows_rejected INT NOT NULL DEFAULT 0,
        status ENUM('STAGED','PROMOTED') NOT NULL DEFAULT 'STAGED',
        loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        promoted_at DATETIME NULL,
        KEY ix_client_table (client, table_name, status))""",
    f"""CREATE TABLE IF NOT EXISTS {q(ADMIN_SCHEMA)}.reject_log (
        id BIGINT AUTO_INCREMENT PRIMARY KEY,
        load_id BIGINT NOT NULL,
        row_num INT NOT NULL,
        reason VARCHAR(500) NOT NULL)""",
]


def ensure_admin(conn):
    with conn.cursor() as cur:
        for ddl in ADMIN_DDL:
            cur.execute(ddl)
        for col, ddl in (
            ("display_name", "VARCHAR(100) NULL"),
            ("contact_email", "VARCHAR(255) NULL"),
        ):
            cur.execute(
                "SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=%s "
                "AND TABLE_NAME='clients' AND COLUMN_NAME=%s",
                (ADMIN_SCHEMA, col),
            )
            if not cur.fetchone():
                cur.execute(f"ALTER TABLE {q(ADMIN_SCHEMA)}.clients ADD COLUMN {col} {ddl}")
    conn.commit()


def install_procedures(conn):
    """(Re)create the stored routines that external loaders such as SSIS call."""
    ensure_admin(conn)
    text = (Path(__file__).parent / "procs.sql").read_text(encoding="utf-8")
    statements = [s.strip() for s in text.split("-- ;;")]
    with conn.cursor() as cur:
        for stmt in statements:
            body = "\n".join(l for l in stmt.splitlines() if not l.startswith("--")).strip()
            if body:
                cur.execute(body)
    conn.commit()
    return len([s for s in statements if "CREATE" in s])
