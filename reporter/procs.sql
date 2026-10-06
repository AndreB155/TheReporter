-- TheReporter stored routines (installed into reporter_admin).
-- Statements are split on the separator lines below (see reporter.db.install_procedures).
-- Flow for an external loader such as SSIS:
--   CALL sp_add_client(...)                     once per client
--   CALL sp_begin_load(...)                     returns load_id, creates/extends <client>_stg.stg_<table>
--   (loader inserts rows into <client>_stg.stg_<table> with _load_id = load_id)
--   CALL sp_end_load(load_id, rows, rejected)
--   CALL sp_promote(client, table, date_fmt, datetime_fmt)   STG -> ODS
--   CALL sp_build_dw(client, table)                           ODS -> DW (history)
-- ;;
DROP PROCEDURE IF EXISTS reporter_admin.sp_exec
-- ;;
CREATE PROCEDURE reporter_admin.sp_exec(IN p_sql LONGTEXT)
BEGIN
    SET @__sql = p_sql;
    PREPARE __st FROM @__sql;
    EXECUTE __st;
    SET @__rc = ROW_COUNT();
    DEALLOCATE PREPARE __st;
END
-- ;;
DROP PROCEDURE IF EXISTS reporter_admin.sp_check_ident
-- ;;
CREATE PROCEDURE reporter_admin.sp_check_ident(IN p_name VARCHAR(255), IN p_what VARCHAR(30))
BEGIN
    IF p_name IS NULL OR p_name NOT REGEXP '^[a-z][a-z0-9_]{0,59}$' THEN
        SET @__msg = CONCAT('Invalid ', p_what, ': ', IFNULL(p_name, 'NULL'));
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @__msg;
    END IF;
END
-- ;;
DROP FUNCTION IF EXISTS reporter_admin.fn_ok_expr
-- ;;
CREATE FUNCTION reporter_admin.fn_ok_expr(p_dtype VARCHAR(30), p_col VARCHAR(100), p_fmt VARCHAR(60))
RETURNS TEXT DETERMINISTIC
BEGIN
    IF p_dtype IN ('tinyint','smallint','mediumint','int','bigint') THEN
        RETURN CONCAT(p_col, ' REGEXP ''^[+-]?[0-9]{1,18}$''');
    ELSEIF p_dtype IN ('decimal','numeric','float','double') THEN
        RETURN CONCAT(p_col, ' REGEXP ''^[+-]?[0-9]+([.][0-9]+)?$''');
    ELSEIF p_dtype = 'date' THEN
        IF p_fmt IS NULL THEN
            RETURN CONCAT('(', p_col, ' REGEXP ''^[0-9]{4}-[0-9]{2}-[0-9]{2}$'' AND STR_TO_DATE(', p_col, ',''%Y-%m-%d'') IS NOT NULL)');
        END IF;
        RETURN CONCAT('STR_TO_DATE(', p_col, ',', QUOTE(p_fmt), ') IS NOT NULL');
    ELSEIF p_dtype IN ('datetime','timestamp') THEN
        IF p_fmt IS NULL THEN
            RETURN CONCAT('(', p_col, ' REGEXP ''^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}$'' AND STR_TO_DATE(REPLACE(',
                          p_col, ',''T'','' ''),''%Y-%m-%d %H:%i:%s'') IS NOT NULL)');
        END IF;
        RETURN CONCAT('STR_TO_DATE(', p_col, ',', QUOTE(p_fmt), ') IS NOT NULL');
    END IF;
    RETURN '1=1';
END
-- ;;
DROP FUNCTION IF EXISTS reporter_admin.fn_conv_expr
-- ;;
CREATE FUNCTION reporter_admin.fn_conv_expr(p_dtype VARCHAR(30), p_col VARCHAR(100), p_fmt VARCHAR(60))
RETURNS TEXT DETERMINISTIC
BEGIN
    DECLARE v TEXT;
    IF p_dtype IN ('tinyint','smallint','mediumint','int','bigint') THEN
        SET v = CONCAT('CAST(', p_col, ' AS SIGNED)');
    ELSEIF p_dtype IN ('decimal','numeric','float','double') THEN
        SET v = CONCAT('CAST(', p_col, ' AS DECIMAL(38,10))');
    ELSEIF p_dtype = 'date' THEN
        SET v = CONCAT('STR_TO_DATE(', p_col, ',', QUOTE(IFNULL(p_fmt, '%Y-%m-%d')), ')');
    ELSEIF p_dtype IN ('datetime','timestamp') THEN
        IF p_fmt IS NULL THEN
            SET v = CONCAT('STR_TO_DATE(REPLACE(', p_col, ',''T'','' ''),''%Y-%m-%d %H:%i:%s'')');
        ELSE
            SET v = CONCAT('STR_TO_DATE(', p_col, ',', QUOTE(p_fmt), ')');
        END IF;
    ELSE
        RETURN CONCAT('IF(', p_col, ' IS NULL OR ', p_col, '='''', NULL, ', p_col, ')');
    END IF;
    RETURN CONCAT('IF(', p_col, ' IS NULL OR ', p_col, '='''', NULL, ', v, ')');
END
-- ;;
DROP PROCEDURE IF EXISTS reporter_admin.sp_add_client
-- ;;
CREATE PROCEDURE reporter_admin.sp_add_client(IN p_client VARCHAR(64), IN p_display VARCHAR(100), IN p_email VARCHAR(255))
BEGIN
    SET p_client = LOWER(TRIM(p_client));
    IF p_client IS NULL OR p_client NOT REGEXP '^[a-z][a-z0-9_]{0,29}$' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Client name must start with a letter and contain only a-z, 0-9, _ (max 30 chars)';
    END IF;
    CALL reporter_admin.sp_exec(CONCAT('CREATE DATABASE IF NOT EXISTS `', p_client, '_stg` CHARACTER SET utf8mb4'));
    CALL reporter_admin.sp_exec(CONCAT('CREATE DATABASE IF NOT EXISTS `', p_client, '_ods` CHARACTER SET utf8mb4'));
    CALL reporter_admin.sp_exec(CONCAT('CREATE DATABASE IF NOT EXISTS `', p_client, '_dw` CHARACTER SET utf8mb4'));
    INSERT IGNORE INTO reporter_admin.clients (client, display_name, contact_email)
    VALUES (p_client, NULLIF(p_display, ''), NULLIF(p_email, ''));
END
-- ;;
DROP PROCEDURE IF EXISTS reporter_admin.sp_begin_load
-- ;;
CREATE PROCEDURE reporter_admin.sp_begin_load(
    IN p_client VARCHAR(64), IN p_table VARCHAR(64), IN p_columns TEXT, IN p_key VARCHAR(500), IN p_source VARCHAR(500))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_col VARCHAR(64);
    DECLARE v_stg VARCHAR(64);
    DECLARE v_load BIGINT;
    DECLARE cur CURSOR FOR
        SELECT k FROM JSON_TABLE(CONCAT('["', REPLACE(p_columns, ',', '","'), '"]'), '$[*]' COLUMNS (k VARCHAR(64) PATH '$')) jt;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    SET p_client = LOWER(TRIM(p_client));
    SET p_table = LOWER(TRIM(p_table));
    SET p_columns = LOWER(REPLACE(p_columns, ' ', ''));
    SET p_key = NULLIF(LOWER(REPLACE(IFNULL(p_key, ''), ' ', '')), '');
    CALL reporter_admin.sp_check_ident(p_table, 'table name');
    IF NOT EXISTS (SELECT 1 FROM reporter_admin.clients WHERE client = p_client) THEN
        SET @__msg = CONCAT('Unknown client ', IFNULL(p_client, 'NULL'), '. Run sp_add_client first');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @__msg;
    END IF;
    SET v_stg = CONCAT('stg_', p_table);

    IF NOT EXISTS (SELECT 1 FROM information_schema.TABLES
                   WHERE TABLE_SCHEMA = CONCAT(p_client, '_stg') AND TABLE_NAME = v_stg) THEN
        CALL reporter_admin.sp_exec(CONCAT('CREATE TABLE `', p_client, '_stg`.`', v_stg,
            '` (_stg_id BIGINT AUTO_INCREMENT PRIMARY KEY, _load_id BIGINT NOT NULL, _row_num INT NOT NULL DEFAULT 0, KEY ix_load (_load_id))'));
    END IF;

    OPEN cur;
    col_loop: LOOP
        FETCH cur INTO v_col;
        IF done = 1 THEN LEAVE col_loop; END IF;
        CALL reporter_admin.sp_check_ident(v_col, 'column name');
        IF NOT EXISTS (SELECT 1 FROM information_schema.COLUMNS
                       WHERE TABLE_SCHEMA = CONCAT(p_client, '_stg') AND TABLE_NAME = v_stg AND COLUMN_NAME = v_col) THEN
            CALL reporter_admin.sp_exec(CONCAT('ALTER TABLE `', p_client, '_stg`.`', v_stg, '` ADD COLUMN `', v_col, '` TEXT NULL'));
        END IF;
    END LOOP;
    CLOSE cur;

    IF p_key IS NOT NULL THEN
        INSERT INTO reporter_admin.table_config (client, table_name, key_columns) VALUES (p_client, p_table, p_key)
        ON DUPLICATE KEY UPDATE key_columns = VALUES(key_columns);
    ELSE
        INSERT IGNORE INTO reporter_admin.table_config (client, table_name) VALUES (p_client, p_table);
    END IF;

    INSERT INTO reporter_admin.load_log (client, table_name, source_file) VALUES (p_client, p_table, IFNULL(p_source, ''));
    SET v_load = LAST_INSERT_ID();
    SELECT v_load AS load_id;
END
-- ;;
DROP PROCEDURE IF EXISTS reporter_admin.sp_end_load
-- ;;
CREATE PROCEDURE reporter_admin.sp_end_load(IN p_load_id BIGINT, IN p_loaded INT, IN p_rejected INT)
BEGIN
    UPDATE reporter_admin.load_log SET rows_loaded = p_loaded, rows_rejected = p_rejected WHERE load_id = p_load_id;
END
-- ;;
DROP PROCEDURE IF EXISTS reporter_admin.sp_promote
-- ;;
CREATE PROCEDURE reporter_admin.sp_promote(
    IN p_client VARCHAR(64), IN p_table VARCHAR(64), IN p_date_fmt VARCHAR(60), IN p_dt_fmt VARCHAR(60))
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_name VARCHAR(64);
    DECLARE v_stg_s, v_ods_s, v_stg_t, v_keys VARCHAR(200);
    DECLARE v_where, v_ok, v_conv, v_cols, v_upd, v_keybad, v_defs, v_uq TEXT;
    DECLARE v_good, v_bad INT DEFAULT 0;
    DECLARE v_nonempty, v_f_int, v_f_dec, v_f_date, v_f_dt, v_maxlen, v_scale, v_intd INT;
    DECLARE v_type VARCHAR(60);
    DECLARE v_prec, v_sc INT;
    DECLARE cur CURSOR FOR SELECT name FROM tmp_promote_cols WHERE ctype IS NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    SET p_client = LOWER(TRIM(p_client));
    SET p_table = LOWER(TRIM(p_table));
    SET p_date_fmt = NULLIF(p_date_fmt, '');
    SET p_dt_fmt = NULLIF(p_dt_fmt, '');
    CALL reporter_admin.sp_check_ident(p_table, 'table name');
    IF NOT EXISTS (SELECT 1 FROM reporter_admin.clients WHERE client = p_client) THEN
        SET @__msg = CONCAT('Unknown client ', IFNULL(p_client, 'NULL'));
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @__msg;
    END IF;
    SET v_stg_s = CONCAT(p_client, '_stg'), v_ods_s = CONCAT(p_client, '_ods'), v_stg_t = CONCAT('stg_', p_table);
    SET SESSION group_concat_max_len = 1000000;

    IF NOT EXISTS (SELECT 1 FROM reporter_admin.load_log
                   WHERE client = p_client AND table_name = p_table AND status = 'STAGED') THEN
        SELECT 0 AS rows_promoted, 0 AS rows_rejected;
    ELSE
        SET v_where = CONCAT('_load_id IN (SELECT load_id FROM reporter_admin.load_log WHERE client=', QUOTE(p_client),
                             ' AND table_name=', QUOTE(p_table), ' AND status=''STAGED'')');
        SELECT IFNULL(key_columns, '') INTO v_keys FROM reporter_admin.table_config
         WHERE client = p_client AND table_name = p_table;

        DROP TEMPORARY TABLE IF EXISTS tmp_promote_cols;
        CREATE TEMPORARY TABLE tmp_promote_cols (
            pos INT, name VARCHAR(64), ctype VARCHAR(100) NULL, dtype VARCHAR(30) NULL, is_key TINYINT NOT NULL DEFAULT 0);
        INSERT INTO tmp_promote_cols (pos, name, ctype, dtype, is_key)
        SELECT s.ORDINAL_POSITION, s.COLUMN_NAME, o.COLUMN_TYPE, o.DATA_TYPE, FIND_IN_SET(s.COLUMN_NAME, v_keys) > 0
          FROM information_schema.COLUMNS s
          LEFT JOIN information_schema.COLUMNS o
            ON o.TABLE_SCHEMA = v_ods_s AND o.TABLE_NAME = p_table AND o.COLUMN_NAME = s.COLUMN_NAME
         WHERE s.TABLE_SCHEMA = v_stg_s AND s.TABLE_NAME = v_stg_t AND s.COLUMN_NAME NOT LIKE '\_%';
        IF NOT EXISTS (SELECT 1 FROM tmp_promote_cols) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No staging table or columns found for this table';
        END IF;

        -- Infer types for columns that are not in the ODS table yet
        OPEN cur;
        inf_loop: LOOP
            SET done = 0;
            FETCH cur INTO v_name;
            IF done = 1 THEN LEAVE inf_loop; END IF;
            SET @__q = CONCAT(
                'SELECT COALESCE(SUM(`', v_name, '`<>''''),0),',
                ' COALESCE(SUM(`', v_name, '`<>'''' AND NOT(', reporter_admin.fn_ok_expr('bigint', CONCAT('`', v_name, '`'), NULL), ')),0),',
                ' COALESCE(SUM(`', v_name, '`<>'''' AND NOT(', reporter_admin.fn_ok_expr('decimal', CONCAT('`', v_name, '`'), NULL), ')),0),',
                ' COALESCE(SUM(`', v_name, '`<>'''' AND NOT(', reporter_admin.fn_ok_expr('date', CONCAT('`', v_name, '`'), p_date_fmt), ')),0),',
                ' COALESCE(SUM(`', v_name, '`<>'''' AND NOT(', reporter_admin.fn_ok_expr('datetime', CONCAT('`', v_name, '`'), p_dt_fmt), ')),0),',
                ' COALESCE(MAX(LENGTH(`', v_name, '`)),0),',
                ' COALESCE(MAX(IF(`', v_name, '` LIKE ''%.%'', LENGTH(`', v_name, '`)-LOCATE(''.'',`', v_name, '`), 0)),0),',
                ' COALESCE(MAX(LENGTH(SUBSTRING_INDEX(REPLACE(REPLACE(`', v_name, '`,''-'',''''),''+'',''''),''.'',1))),1)',
                ' INTO @__a1,@__a2,@__a3,@__a4,@__a5,@__a6,@__a7,@__a8 FROM `', v_stg_s, '`.`', v_stg_t, '` WHERE ', v_where);
            CALL reporter_admin.sp_exec(@__q);
            SET v_nonempty = @__a1, v_f_int = @__a2, v_f_dec = @__a3, v_f_date = @__a4, v_f_dt = @__a5,
                v_maxlen = @__a6, v_scale = @__a7, v_intd = @__a8;
            IF v_nonempty = 0 THEN
                SET v_type = 'VARCHAR(255)';
            ELSEIF v_f_int = 0 THEN
                SET v_type = 'BIGINT';
            ELSEIF v_f_dec = 0 THEN
                SET v_sc = LEAST(v_scale, 10);
                SET v_prec = LEAST(v_intd + v_sc + 8, 38);
                SET v_type = CONCAT('DECIMAL(', v_prec, ',', v_sc, ')');
            ELSEIF v_f_date = 0 THEN
                SET v_type = 'DATE';
            ELSEIF v_f_dt = 0 THEN
                SET v_type = 'DATETIME';
            ELSEIF v_maxlen <= 255 THEN
                SET v_type = 'VARCHAR(255)';
            ELSE
                SET v_type = 'TEXT';
            END IF;
            UPDATE tmp_promote_cols SET ctype = IF(is_key = 1 AND v_type = 'TEXT', 'VARCHAR(255)', v_type) WHERE name = v_name;
            UPDATE tmp_promote_cols SET dtype = LOWER(SUBSTRING_INDEX(ctype, '(', 1)) WHERE name = v_name;
        END LOOP;
        CLOSE cur;

        -- Create or extend the ODS table
        IF NOT EXISTS (SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA = v_ods_s AND TABLE_NAME = p_table) THEN
            SELECT GROUP_CONCAT(CONCAT('`', name, '` ', ctype, ' NULL') ORDER BY pos SEPARATOR ', ') INTO v_defs FROM tmp_promote_cols;
            SELECT GROUP_CONCAT(CONCAT('`', name, '`') ORDER BY pos SEPARATOR ', ') INTO v_uq FROM tmp_promote_cols WHERE is_key = 1;
            CALL reporter_admin.sp_exec(CONCAT('CREATE TABLE `', v_ods_s, '`.`', p_table,
                '` (_ods_id BIGINT AUTO_INCREMENT PRIMARY KEY, ', v_defs,
                ', _ods_loaded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,',
                ' _ods_updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
                IF(v_uq IS NULL, '', CONCAT(', UNIQUE KEY uq_business_key (', v_uq, ')')), ')'));
        ELSE
            SET done = 0;
            SELECT GROUP_CONCAT(CONCAT('ADD COLUMN `', t.name, '` ', t.ctype, ' NULL') ORDER BY t.pos SEPARATOR ', ') INTO v_defs
              FROM tmp_promote_cols t
             WHERE NOT EXISTS (SELECT 1 FROM information_schema.COLUMNS c
                                WHERE c.TABLE_SCHEMA = v_ods_s AND c.TABLE_NAME = p_table AND c.COLUMN_NAME = t.name);
            IF v_defs IS NOT NULL THEN
                CALL reporter_admin.sp_exec(CONCAT('ALTER TABLE `', v_ods_s, '`.`', p_table, '` ', v_defs));
            END IF;
        END IF;

        -- Refresh types from the real ODS table
        UPDATE tmp_promote_cols t JOIN information_schema.COLUMNS c
            ON c.TABLE_SCHEMA = v_ods_s AND c.TABLE_NAME = p_table AND c.COLUMN_NAME = t.name
           SET t.ctype = c.COLUMN_TYPE, t.dtype = c.DATA_TYPE;

        SELECT GROUP_CONCAT(CONCAT('(', reporter_admin.fn_ok_expr(dtype, CONCAT('`', name, '`'),
                   IF(dtype = 'date', p_date_fmt, IF(dtype IN ('datetime','timestamp'), p_dt_fmt, NULL))),
                   ' OR `', name, '` IS NULL OR `', name, '`='''')') ORDER BY pos SEPARATOR ' AND '),
               GROUP_CONCAT(reporter_admin.fn_conv_expr(dtype, CONCAT('`', name, '`'),
                   IF(dtype = 'date', p_date_fmt, IF(dtype IN ('datetime','timestamp'), p_dt_fmt, NULL))) ORDER BY pos SEPARATOR ', '),
               GROUP_CONCAT(CONCAT('`', name, '`') ORDER BY pos SEPARATOR ', ')
          INTO v_ok, v_conv, v_cols FROM tmp_promote_cols;
        SELECT GROUP_CONCAT(CONCAT('`', name, '` IS NULL OR `', name, '`=''''') SEPARATOR ' OR ') INTO v_keybad
          FROM tmp_promote_cols WHERE is_key = 1;
        SET v_keybad = IFNULL(v_keybad, '1=0');

        SET @__bad = CONCAT('(NOT COALESCE((', v_ok, '), 0) OR ', v_keybad, ')');
        CALL reporter_admin.sp_exec(CONCAT('SELECT COUNT(*) INTO @__nbad FROM `', v_stg_s, '`.`', v_stg_t, '` WHERE ', v_where, ' AND ', @__bad));
        SET v_bad = @__nbad;
        CALL reporter_admin.sp_exec(CONCAT('SELECT COUNT(*) INTO @__ngood FROM `', v_stg_s, '`.`', v_stg_t, '` WHERE ', v_where, ' AND NOT ', @__bad));
        SET v_good = @__ngood;

        IF v_bad > 0 THEN
            CALL reporter_admin.sp_exec(CONCAT(
                'INSERT INTO reporter_admin.reject_log (load_id, row_num, reason) SELECT _load_id, _row_num, ''Conversion failed or empty key'' FROM `',
                v_stg_s, '`.`', v_stg_t, '` WHERE ', v_where, ' AND ', @__bad));
        END IF;

        IF v_good > 0 THEN
            SELECT GROUP_CONCAT(CONCAT('`', name, '`=VALUES(`', name, '`)') SEPARATOR ', ') INTO v_upd
              FROM tmp_promote_cols WHERE is_key = 0;
            IF v_keys = '' THEN
                SET v_upd = NULL;
            ELSEIF v_upd IS NULL THEN
                SELECT CONCAT('`', name, '`=VALUES(`', name, '`)') INTO v_upd FROM tmp_promote_cols WHERE is_key = 1 LIMIT 1;
            END IF;
            CALL reporter_admin.sp_exec(CONCAT('INSERT INTO `', v_ods_s, '`.`', p_table, '` (', v_cols, ') SELECT ', v_conv,
                ' FROM `', v_stg_s, '`.`', v_stg_t, '` WHERE ', v_where, ' AND NOT ', @__bad, ' ORDER BY _stg_id',
                IF(v_upd IS NULL, '', CONCAT(' ON DUPLICATE KEY UPDATE ', v_upd))));
        END IF;

        UPDATE reporter_admin.load_log SET status = 'PROMOTED', promoted_at = NOW()
         WHERE client = p_client AND table_name = p_table AND status = 'STAGED';
        DROP TEMPORARY TABLE IF EXISTS tmp_promote_cols;
        SELECT v_good AS rows_promoted, v_bad AS rows_rejected;
    END IF;
END
-- ;;
DROP PROCEDURE IF EXISTS reporter_admin.sp_build_dw
-- ;;
CREATE PROCEDURE reporter_admin.sp_build_dw(IN p_client VARCHAR(64), IN p_table VARCHAR(64))
BEGIN
    DECLARE v_ods, v_dw, v_keys VARCHAR(200);
    DECLARE v_defs, v_names, v_onames, v_hash, v_join TEXT;
    DECLARE v_ins, v_exp INT DEFAULT 0;

    SET p_client = LOWER(TRIM(p_client));
    SET p_table = LOWER(TRIM(p_table));
    CALL reporter_admin.sp_check_ident(p_table, 'table name');
    IF NOT EXISTS (SELECT 1 FROM reporter_admin.clients WHERE client = p_client) THEN
        SET @__msg = CONCAT('Unknown client ', IFNULL(p_client, 'NULL'));
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @__msg;
    END IF;
    SET v_ods = CONCAT(p_client, '_ods'), v_dw = CONCAT(p_client, '_dw');
    SET SESSION group_concat_max_len = 1000000;
    SELECT IFNULL(key_columns, '') INTO v_keys FROM reporter_admin.table_config WHERE client = p_client AND table_name = p_table;
    IF v_keys = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Table has no business key; supply the key when loading to enable DW history';
    END IF;

    DROP TEMPORARY TABLE IF EXISTS tmp_dw_cols;
    CREATE TEMPORARY TABLE tmp_dw_cols (pos INT, name VARCHAR(64), ctype VARCHAR(100));
    INSERT INTO tmp_dw_cols SELECT ORDINAL_POSITION, COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = v_ods AND TABLE_NAME = p_table AND COLUMN_NAME NOT LIKE '\_%';
    IF NOT EXISTS (SELECT 1 FROM tmp_dw_cols) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No ODS table found; run sp_promote first';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA = v_dw AND TABLE_NAME = p_table) THEN
        SELECT GROUP_CONCAT(CONCAT('`', name, '` ', ctype, ' NULL') ORDER BY pos SEPARATOR ', ') INTO v_defs FROM tmp_dw_cols;
        SELECT GROUP_CONCAT(CONCAT('`', k, '`') SEPARATOR ', ') INTO v_join
          FROM JSON_TABLE(CONCAT('["', REPLACE(v_keys, ',', '","'), '"]'), '$[*]' COLUMNS (k VARCHAR(64) PATH '$')) jt;
        CALL reporter_admin.sp_exec(CONCAT('CREATE TABLE `', v_dw, '`.`', p_table, '` (_sk BIGINT AUTO_INCREMENT PRIMARY KEY, ', v_defs,
            ', _row_hash CHAR(64) NOT NULL, _valid_from DATETIME NOT NULL, _valid_to DATETIME NULL, _is_current TINYINT(1) NOT NULL,',
            ' KEY ix_bk (', v_join, ', _is_current))'));
    ELSE
        SELECT GROUP_CONCAT(CONCAT('ADD COLUMN `', t.name, '` ', t.ctype, ' NULL') ORDER BY t.pos SEPARATOR ', ') INTO v_defs
          FROM tmp_dw_cols t
         WHERE NOT EXISTS (SELECT 1 FROM information_schema.COLUMNS c
                            WHERE c.TABLE_SCHEMA = v_dw AND c.TABLE_NAME = p_table AND c.COLUMN_NAME = t.name);
        IF v_defs IS NOT NULL THEN
            CALL reporter_admin.sp_exec(CONCAT('ALTER TABLE `', v_dw, '`.`', p_table, '` ', v_defs));
        END IF;
    END IF;

    SELECT GROUP_CONCAT(CONCAT('`', name, '`') ORDER BY pos SEPARATOR ', '),
           GROUP_CONCAT(CONCAT('o.`', name, '`') ORDER BY pos SEPARATOR ', '),
           CONCAT('SHA2(CONCAT_WS(''||'', ', GROUP_CONCAT(CONCAT('IFNULL(CAST(o.`', name, '` AS CHAR),''~NULL~'')') ORDER BY pos SEPARATOR ', '), '), 256)')
      INTO v_names, v_onames, v_hash FROM tmp_dw_cols;
    SELECT GROUP_CONCAT(CONCAT('d.`', k, '` = o.`', k, '`') SEPARATOR ' AND ') INTO v_join
      FROM JSON_TABLE(CONCAT('["', REPLACE(v_keys, ',', '","'), '"]'), '$[*]' COLUMNS (k VARCHAR(64) PATH '$')) jt;

    SET @__now = NOW();
    CALL reporter_admin.sp_exec(CONCAT('UPDATE `', v_dw, '`.`', p_table, '` d JOIN `', v_ods, '`.`', p_table, '` o ON ', v_join,
        ' SET d._valid_to = @__now, d._is_current = 0 WHERE d._is_current = 1 AND d._row_hash <> ', v_hash));
    SET v_exp = @__rc;
    CALL reporter_admin.sp_exec(CONCAT('INSERT INTO `', v_dw, '`.`', p_table, '` (', v_names, ', _row_hash, _valid_from, _valid_to, _is_current) ',
        'SELECT ', v_onames, ', ', v_hash, ', @__now, NULL, 1 FROM `', v_ods, '`.`', p_table, '` o ',
        'WHERE NOT EXISTS (SELECT 1 FROM `', v_dw, '`.`', p_table, '` d WHERE d._is_current = 1 AND ', v_join, ' AND d._row_hash = ', v_hash, ')'));
    SET v_ins = @__rc;
    CALL reporter_admin.sp_exec(CONCAT('CREATE OR REPLACE VIEW `', v_dw, '`.`', p_table, '_current` AS SELECT ', v_names,
        ' FROM `', v_dw, '`.`', p_table, '` WHERE _is_current = 1'));
    DROP TEMPORARY TABLE IF EXISTS tmp_dw_cols;
    SELECT v_ins AS versions_inserted, v_exp AS versions_expired;
END
