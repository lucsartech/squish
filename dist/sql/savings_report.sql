-- ============================================================
-- Squish — Storage savings report (cumulative, client-facing)
-- ============================================================
-- Reads SQUISH_PROCESSED and reports how much storage Squish has reclaimed
-- since activation. Read-only: a single SELECT, never writes.
--
-- Only STATUS='SUCCESS' rows carry real MEASURED sizes, so only they feed the
-- savings totals. SKIPPED/ERROR are shown as context. MIGRATED rows (assumed
-- already-compressed by migrate_tracking_composite.sql) have no measured bytes
-- and are deliberately excluded — including them would inflate the totals with
-- sizes nobody ever measured.
--
-- GRAIN: one tracking row per detail PART (OTT_ID, OTT_CTR), not per document.
-- "Documents" counts DISTINCT OTT_ID; "parts" counts rows. Byte sums are per
-- part and therefore correct as-is. (See create_tracking_table.sql.)
--
-- Optional date window via two substitution vars (empty = unbounded):
--   p_since = YYYY-MM-DD  inclusive lower bound
--   p_until = YYYY-MM-DD  inclusive upper bound (the whole day is included)
--
-- Usage:
--   Prefer  bin/squish-savings.sh  (fills the connection from config/squish.env
--   and DEFINEs the window, so nothing prompts and no password hits `ps`).
--   Standalone:
--     sqlplus user/pass@//host:1521/SERVICE @savings_report.sql
--       -> answer the two prompts with Enter for "whole history", or DEFINE first:
--     DEFINE p_since = 2026-01-01
--     DEFINE p_until =
--     @savings_report.sql
-- ============================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF
SET LINESIZE 200
WHENEVER SQLERROR EXIT FAILURE

-- Predictable grouping/decimal marks regardless of the account's territory.
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

DECLARE
    v_since   VARCHAR2(10) := '&p_since';   -- empty string -> NULL in Oracle
    v_until   VARCHAR2(10) := '&p_until';
    v_ts_from TIMESTAMP;
    v_ts_to   TIMESTAMP;

    v_parts   NUMBER := 0;
    v_docs    NUMBER := 0;
    v_orig    NUMBER := 0;
    v_comp    NUMBER := 0;
    v_saved   NUMBER := 0;
    v_pct     NUMBER := 0;
    v_avg_pct NUMBER := 0;
    v_first   TIMESTAMP;
    v_last    TIMESTAMP;
    v_skipped NUMBER := 0;
    v_errors  NUMBER := 0;

    -- Bytes -> human-readable (B/KB/MB/GB/TB), 2 decimals from MB up.
    FUNCTION human(p_bytes IN NUMBER) RETURN VARCHAR2 IS
        u   NUMBER := NVL(p_bytes, 0);
        i   PLS_INTEGER := 0;
        lbl VARCHAR2(3);
    BEGIN
        WHILE u >= 1024 AND i < 4 LOOP
            u := u / 1024;
            i := i + 1;
        END LOOP;
        lbl := CASE i WHEN 0 THEN 'B' WHEN 1 THEN 'KB' WHEN 2 THEN 'MB'
                      WHEN 3 THEN 'GB' ELSE 'TB' END;
        IF i >= 2 THEN
            RETURN TO_CHAR(ROUND(u, 2), 'FM999G999G990D00') || ' ' || lbl;
        END IF;
        RETURN TO_CHAR(ROUND(u), 'FM999G999G990') || ' ' || lbl;
    END;

    FUNCTION dt(p IN TIMESTAMP) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p IS NULL THEN 'n/a'
                    ELSE TO_CHAR(p, 'YYYY-MM-DD HH24:MI') END;
    END;
BEGIN
    IF v_since IS NOT NULL THEN v_ts_from := TO_TIMESTAMP(v_since, 'YYYY-MM-DD'); END IF;
    IF v_until IS NOT NULL THEN v_ts_to   := TO_TIMESTAMP(v_until, 'YYYY-MM-DD') + 1; END IF; -- include the whole day

    SELECT COUNT(*),
           COUNT(DISTINCT OTT_ID),
           NVL(SUM(ORIGINAL_SIZE), 0),
           NVL(SUM(COMPRESSED_SIZE), 0),
           ROUND(AVG(SAVINGS_PERCENT), 2),
           MIN(PROCESSED_DATE),
           MAX(PROCESSED_DATE)
      INTO v_parts, v_docs, v_orig, v_comp, v_avg_pct, v_first, v_last
      FROM SQUISH_PROCESSED
     WHERE STATUS = 'SUCCESS'
       AND (v_ts_from IS NULL OR PROCESSED_DATE >= v_ts_from)
       AND (v_ts_to   IS NULL OR PROCESSED_DATE <  v_ts_to);

    SELECT NVL(SUM(CASE WHEN STATUS = 'SKIPPED' THEN 1 ELSE 0 END), 0),
           NVL(SUM(CASE WHEN STATUS = 'ERROR'   THEN 1 ELSE 0 END), 0)
      INTO v_skipped, v_errors
      FROM SQUISH_PROCESSED
     WHERE (v_ts_from IS NULL OR PROCESSED_DATE >= v_ts_from)
       AND (v_ts_to   IS NULL OR PROCESSED_DATE <  v_ts_to);

    v_saved := v_orig - v_comp;
    v_pct   := CASE WHEN v_orig > 0 THEN ROUND(v_saved / v_orig * 100, 1) ELSE 0 END;

    DBMS_OUTPUT.PUT_LINE('====================================================');
    DBMS_OUTPUT.PUT_LINE('  Squish  -  Storage savings report');
    DBMS_OUTPUT.PUT_LINE('====================================================');
    DBMS_OUTPUT.PUT_LINE('  Period : ' || dt(v_first) || '   ->   ' || dt(v_last));
    IF v_since IS NOT NULL OR v_until IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('  Window : ' || NVL(v_since, 'start') || ' .. ' || NVL(v_until, 'now'));
    END IF;
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    IF v_parts = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  No compressed documents in this window yet.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('  Documents compressed : ' || v_docs || '  (' || v_parts || ' PDF parts)');
        DBMS_OUTPUT.PUT_LINE('  Original size        : ' || human(v_orig));
        DBMS_OUTPUT.PUT_LINE('  After Squish         : ' || human(v_comp));
        DBMS_OUTPUT.PUT_LINE('  ----------------------------------');
        DBMS_OUTPUT.PUT_LINE('  SPACE SAVED          : ' || human(v_saved)
                             || '   (-' || TO_CHAR(v_pct, 'FM990D0') || '%)');
        DBMS_OUTPUT.PUT_LINE('  Avg reduction / file : ' || TO_CHAR(NVL(v_avg_pct, 0), 'FM990D0') || '%');
    END IF;
    DBMS_OUTPUT.PUT_LINE('----------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('  Context : ' || v_skipped || ' skipped (already optimal / not PDF), '
                         || v_errors || ' errors');
    DBMS_OUTPUT.PUT_LINE('====================================================');
END;
/

EXIT SUCCESS
