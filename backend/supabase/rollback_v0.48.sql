-- ============================================================
-- CLI Pulse — Rollback v0.48
-- Reverses: public.desk_snapshot RPC
-- Prerequisites: v0.48 migration was applied
--
-- v0.48 created no tables, columns, indexes or data — only one
-- function — so this is a clean, lossless rollback.
-- ============================================================

DROP FUNCTION IF EXISTS public.desk_snapshot(uuid, text, date);
