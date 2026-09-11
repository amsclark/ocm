-- add_reauth_grants.sql - short-lived re-authentication grants.
--
-- A row here says: "session_id <sid> has passed a fresh credential
-- challenge for action_scope <scope> and may proceed until <granted_until>".
--
-- Why a dedicated table:
-- This application's session save handler (pl_session_write in
-- cms/app/lib/pl.php) is a deliberate no-op; nothing in $_SESSION other
-- than 'SID' survives across requests, so a grant cannot live there.
-- csrf_tokens is per-session too, but its lifecycle is one long-lived row
-- rotated on login. Re-auth needs many short-lived rows keyed by
-- (session, scope), so the two coexist rather than share storage.
--
-- Scopes used by pl_reauth_required():
--   * 'password_change' - cms/password.php
--   * 'user_admin'      - cms/system-users.php
--   * 'settings'        - cms/system-settings.php
--
-- Idempotent: re-running this migration on an existing deployment is a
-- no-op.
CREATE TABLE IF NOT EXISTS `reauth_grants` (
	`session_id`    VARCHAR(128) NOT NULL,
	`action_scope`  VARCHAR(64)  NOT NULL,
	`granted_until` DATETIME     NOT NULL,
	`created`       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY (`session_id`, `action_scope`),
	KEY `idx_reauth_granted_until` (`granted_until`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
