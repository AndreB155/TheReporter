# TheReporter

Imports client CSV files into MySQL using a three-tier layout, with each client isolated in its own schemas:

| Tier | Schema | Contents |
|------|--------|----------|
| STG | `<client>_stg` | Raw CSV rows as text (`stg_<table>`), every load kept and tagged with `_load_id`/`_row_num` |
| ODS | `<client>_ods` | Typed (auto-inferred) current-state table, upserted on the business key |
| DW  | `<client>_dw`  | Type-2 history table (`_valid_from`, `_valid_to`, `_is_current`) plus a `<table>_current` view |

Control tables (clients, key config, load log, rejected rows) live in `reporter_admin`.

## Setup
```
pip install -e .
copy .env.example .env   # set MYSQL_HOST / PORT / USER / PASSWORD
```
The MySQL user needs CREATE/ALTER/INSERT/UPDATE on all schemas (MySQL 5.7+/8).

## Usage
```
reporter add-client acme
reporter run --client acme --key customer_id samples\customers.csv
reporter run --client acme --key customer_id samples\customers_update.csv
reporter status --client acme
```
Steps can also be run individually: `import`, `promote --client acme --table customers`, `build-dw --client acme --table customers`.

Notes:
- Column/table names are lower-cased and sanitised. Rows with a wrong field count, an empty key, or values that don't convert to the ODS type are rejected and recorded in `reporter_admin.reject_log`.
- Dates default to ISO (`YYYY-MM-DD`); use `--date-format "%d/%m/%Y"` on `promote`/`run` otherwise.
- DW history requires `--key`. ODS column types are fixed when the table is first created; new CSV columns are added automatically.

## Tests
`pip install -e ".[dev]"; pytest` (unit tests only; no MySQL needed).

## Admin frontend
`python -m reporter.web` then open http://127.0.0.1:5000 to onboard clients (ID, display name, contact email) and view existing ones. It creates the client's STG/ODS/DW schemas. It listens on localhost only and has no login, so don't expose it on a network. Set `REPORTER_PORT` to change the port.

## Installing on a consultant's laptop
1. (Online, once) build the package: `powershell -ExecutionPolicy Bypass -File installer\Build-Package.ps1` creates `dist\TheReporter-Setup.zip`. Add `-Offline` to also bundle MySQL, Python, the VC++ runtime and the Python wheels for sites without internet.
2. Copy the zip to the laptop, unzip, double-click `Install.cmd`.
3. The installer needs no admin rights (except the VC++ runtime if missing). It installs Python 3.10+ if absent, a private virtual environment, and a private portable MySQL 8.4 on `127.0.0.1:3316` with a generated root password, under `%LOCALAPPDATA%\TheReporter`. It then writes the `.env`, creates the control schema, and adds a **TheReporter Admin** desktop shortcut.
4. Use the shortcut to start MySQL and the admin page; run `Stop-MySQL.cmd` in the install folder to shut MySQL down.

Options: `Install.cmd -InstallDir D:\TheReporter -MySqlPort 3320 -WebPort 5001`, or use an existing server with `-UseExistingMySql -DbHost ... -DbPort ... -DbUser ... -DbPassword ...`. Re-running the installer upgrades the app and keeps data. `Uninstall-TheReporter.ps1` (in the install folder) removes everything; `-KeepData` keeps the MySQL data.

## SSIS
CSV loading can be driven from SSIS instead of the Python importer: SSIS fills STG, and MySQL stored procedures (`sp_begin_load`, `sp_end_load`, `sp_promote`, `sp_build_dw`, `sp_add_client`) do STG -> ODS -> DW. Install them with `python -m reporter.cli install-procs` (the installer does this). See [docs/SSIS.md](docs/SSIS.md).
