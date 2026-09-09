-- Audit log of privileged/sensitive actions. Append-only from the app's
-- perspective (no UI path edits or deletes rows). Idempotent: re-running
-- this script on an existing deployment is a no-op.
--
-- Columns:
--   audit_id     -- surrogate PK
--   ts           -- event timestamp (UTC if the server is, which OCM expects)
--   user_id      -- actor's users.user_id, NULL when the actor is unknown
--                   (e.g. failed login with a non-existent username)
--   username     -- actor's username captured at event time so the record
--                   stays meaningful even if the user row is later deleted
--   ip_address   -- request IP as seen by PHP (may be proxy IP; see pl_audit)
--   user_agent   -- truncated User-Agent header
--   action       -- short stable identifier, dotted-lowercase convention:
--                   'login.success', 'login.failure', 'logout',
--                   'user.create', 'user.update', 'user.disable',
--                   'user.group_change', 'user.password_admin_reset',
--                   'password.self_change', 'password.reset_request',
--                   'setting.update', 'activity.delete', 'case.delete',
--                   'contact.delete', 'case.transfer'
--   object_type  -- 'user' | 'case' | 'activity' | 'setting' | 'contact' | NULL
--   object_id    -- stringified primary key of the target object
--   details      -- JSON: {"old": ..., "new": ..., "reason": ...}
--
-- Do NOT index on (username, ip_address) — they're diagnostic, not filter keys.

CREATE TABLE IF NOT EXISTS `audit_log` (
    `audit_id`    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `ts`          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `user_id`     INT UNSIGNED NULL,
    `username`    VARCHAR(64)  NULL,
    `ip_address`  VARCHAR(45)  NULL,
    `user_agent`  VARCHAR(255) NULL,
    `action`      VARCHAR(64)  NOT NULL,
    `object_type` VARCHAR(32)  NULL,
    `object_id`   VARCHAR(64)  NULL,
    `details`     TEXT         NULL,
    PRIMARY KEY (`audit_id`),
    KEY `idx_audit_ts`     (`ts`),
    KEY `idx_audit_user`   (`user_id`),
    KEY `idx_audit_action` (`action`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
