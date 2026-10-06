import argparse
import sys

from . import pipeline
from .db import connect
from .naming import sanitize


def main(argv=None):
    p = argparse.ArgumentParser(prog="reporter", description="CSV -> MySQL STG/ODS/DW loader")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("add-client", help="Create the stg/ods/dw schemas for a client")
    s.add_argument("client")
    sub.add_parser("list-clients")
    sub.add_parser("install-procs", help="Install the MySQL stored procedures used by SSIS / external loaders")

    def common(s, with_file=False):
        s.add_argument("--client", required=True)
        s.add_argument("--table", help="Target table name (default: CSV file name)")
        s.add_argument("--date-format", help="strptime format for DATE columns, e.g. %%d/%%m/%%Y")
        s.add_argument("--datetime-format", help="strptime format for DATETIME columns")

    s = sub.add_parser("import", help="Load a CSV into STG")
    common(s)
    s.add_argument("file")
    s.add_argument("--key", help="Comma separated business key columns (enables upsert + DW history)")
    s.add_argument("--delimiter", default=",")

    s = sub.add_parser("promote", help="STG -> ODS (typed, upserted)")
    common(s)
    s = sub.add_parser("build-dw", help="ODS -> DW (history tracking)")
    common(s)
    s = sub.add_parser("run", help="import + promote + build-dw")
    common(s)
    s.add_argument("file")
    s.add_argument("--key")
    s.add_argument("--delimiter", default=",")
    s = sub.add_parser("status", help="Show recent loads")
    s.add_argument("--client", required=True)

    a = p.parse_args(argv)
    conn = connect()
    try:
        if a.cmd == "add-client":
            print("Created client:", pipeline.add_client(conn, a.client))
        elif a.cmd == "install-procs":
            from .db import install_procedures
            print("Installed", install_procedures(conn), "routines into reporter_admin")
        elif a.cmd == "list-clients":
            for c, t in pipeline.list_clients(conn):
                print(c, t)
        elif a.cmd == "status":
            for r in pipeline.status(conn, a.client):
                print(*r, sep=" | ")
        else:
            table = sanitize(a.table) if a.table else None
            if a.cmd in ("import", "run"):
                load_id, table, n, rej = pipeline.import_csv(
                    conn, a.client, a.file, table, a.key, a.delimiter)
                print(f"STG: load {load_id} into stg_{table}: {n} rows, {rej} rejected")
            if not table:
                p.error("--table is required")
            if a.cmd in ("promote", "run"):
                n, rej = pipeline.promote(conn, a.client, table, a.date_format, a.datetime_format)
                print(f"ODS: {n} rows upserted, {rej} rejected")
            if a.cmd in ("build-dw", "run"):
                ins, exp = pipeline.build_dw(conn, a.client, table)
                print(f"DW: {ins} versions inserted, {exp} versions expired")
    except Exception as e:
        conn.rollback()
        print("ERROR:", e, file=sys.stderr)
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
