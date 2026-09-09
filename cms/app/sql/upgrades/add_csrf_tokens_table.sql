-- add_csrf_tokens_table.sql — per-session CSRF token storage.
--
-- Why this table exists:
-- OCM's session save-handler (cms/app/lib/pl.php::pl_session_*) is a
-- deliberate no-op — $_SESSION is NOT persisted across requests. Only
-- $_SESSION['SID'] survives, restored from the serialized stub that
-- pl_session_read returns. Every other piece of cross-request state
-- lives in a DB table (user_sessions, users, ...) and is reloaded on
-- each request.
--
-- The CSRF framework (pl_csrf_*) therefore cannot keep its token in
-- $_SESSION; a token there is regenerated on every request and can
-- never match across the render-then-submit boundary. This table is
-- that missing persistence: one row per PHP session id, carrying the
-- current 64-hex token plus created/last-used timestamps for GC.
--
-- The table is deliberately separate from user_sessions because
-- unauthenticated flows (the login form, a password-reset request) need
-- a token too, and user_sessions rows only exist once a session is
-- authenticated. A single-purpose table also keeps the auth invariants
-- in user_sessions clean.
--
-- Idempotent: re-running this on an existing deployment is a no-op.

CREATE TABLE IF NOT EXISTS `csrf_tokens` (
	`session_id` VARCHAR(128) NOT NULL,
	`token`      VARCHAR(64)  NOT NULL,
	`created`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
	`last_used`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
	                                   ON UPDATE CURRENT_TIMESTAMP,
	PRIMARY KEY (`session_id`),
	KEY `idx_csrf_last_used` (`last_used`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
