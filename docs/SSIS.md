# Loading CSV files with SSIS

SSIS is responsible only for **CSV -> STG**. Everything after that happens in MySQL through stored procedures in the
`reporter_admin` schema, so type inference, business-key upserts, reject logging and DW history behave exactly as
they do with the Python tool.

```
SSIS package (per client + file layout)            MySQL (reporter_admin procedures)
------------------------------------------------   --------------------------------------------
1. Execute SQL  CALL sp_begin_load(...)        --> creates/extends <client>_stg.stg_<table>, returns load_id
2. Data Flow    Flat File -> Derived Column    --> inserts rows into <client>_stg.stg_<table>
3. Execute SQL  CALL sp_end_load(...)          --> records row counts
4. Execute SQL  CALL sp_promote(...)           --> STG -> ODS (typed, upsert on key, rejects logged)
5. Execute SQL  CALL sp_build_dw(...)          --> ODS -> DW (history) + `<table>_current` view
```

## One-time setup (per MySQL server)
```
python -m reporter.cli install-procs        (the installer already does this)
python -m reporter.cli add-client acme      (or the admin web page, or CALL sp_add_client('acme','Acme Ltd','x@acme.com'))
```

## Prerequisites on the SSIS machine
- Visual Studio with **SQL Server Integration Services Projects** (design) and the SSIS runtime / `dtexec` (execution).
- **MySQL Connector/ODBC 64-bit**. Use a DSN-less connection string, for example
  `DRIVER={MySQL ODBC 9.3 Unicode Driver};SERVER=127.0.0.1;PORT=3316;DATABASE=reporter_admin;UID=root;PWD=...;`
  The 32-bit driver is only needed by the Visual Studio designer if it cannot see the 64-bit one; run packages in 64-bit mode.

## Package design
**Parameters:** `Client` (e.g. `acme`), `FilePath`, `TableName` (e.g. `customers`), `KeyColumns` (e.g. `customer_id`),
optional `DateFormat` (MySQL format codes, e.g. `%d/%m/%Y`). **Variables:** `LoadId` (Int64), `RowCount` (Int32).

**Connection managers**
- `MySQL_Admin` - ODBC, database `reporter_admin`.
- `MySQL_Stg` - ODBC, same server, with a **ConnectionString expression** so the database follows the client:
  `"DRIVER={MySQL ODBC 9.3 Unicode Driver};SERVER=127.0.0.1;PORT=3316;DATABASE=" + @[$Package::Client] + "_stg;UID=root;PWD=...;"`
- `CsvFile` - Flat File connection; ConnectionString expression `@[$Package::FilePath]`; first row = column names;
  all columns string typed (STG is text by design).

**Step 1 - Execute SQL Task (`MySQL_Admin`)**
```sql
CALL reporter_admin.sp_begin_load(?, ?, ?, ?, ?)
```
Parameters: Client, TableName, **column list** (comma separated lower-case CSV header names, e.g.
`customer_id,name,email,balance,signup_date,last_seen`), KeyColumns, FilePath. Result set (single row, column `load_id`)
goes into variable `LoadId`. Table and column names must match `^[a-z][a-z0-9_]*$` (max 60 chars) or the call is refused.
New columns are added to STG automatically, so a layout change needs no DDL.

**Step 2 - Data Flow Task**
- Flat File Source (`CsvFile`) -> **Derived Column** adding `_load_id = (DT_I8) @[User::LoadId]`.
  Optionally add `_row_num` with a Script Component (running counter starting at 2) so rejects point at a CSV line.
- ODBC Destination (`MySQL_Stg`), table `stg_<TableName>` (e.g. `stg_customers`), map CSV columns by name plus `_load_id`/`_row_num`, Batch mode.
- Row Count transformation into `RowCount`.

**Step 3 - Execute SQL Task:** `CALL reporter_admin.sp_end_load(?, ?, 0)` with `LoadId`, `RowCount`.

**Step 4 - Execute SQL Task:** `CALL reporter_admin.sp_promote(?, ?, ?, NULL)` with Client, TableName, DateFormat (empty = ISO `YYYY-MM-DD`).
Returns `rows_promoted, rows_rejected`; rejected rows are listed in `reporter_admin.reject_log` (load_id, row_num, reason).

**Step 5 - Execute SQL Task:** `CALL reporter_admin.sp_build_dw(?, ?)` (requires `KeyColumns` to have been given in step 1).

## Running for a different client / file
Run the same package with other parameter values, e.g.
`dtexec /File LoadCsv.dtsx /Par "$Package::Client";globex /Par "$Package::FilePath";"C:\Data\orders.csv" /Par "$Package::TableName";orders /Par "$Package::KeyColumns";order_id`
Each distinct CSV layout needs its own Data Flow (SSIS fixes column metadata at design time); the five steps are identical.
Client data never mixes because the destination schema comes from the `Client` parameter.

## Notes
- STG keeps every load (`_load_id`); `sp_promote` processes all loads still `STAGED`, then marks them `PROMOTED`.
- Without `KeyColumns` the ODS table is append-only and no DW history can be built.
- ODS column types are inferred on the first promote and fixed afterwards; later values that do not fit are rejected, not coerced.
- The call sequence was verified against MySQL with a script that performs steps 1-5 directly (no SSIS). The `.dtsx` package itself
  has to be built in Visual Studio from this description; it is not generated here.
