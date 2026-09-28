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
--                   a subject and what happened to it, as in 'login.success',
--                   'user.group_change' or 'setting.update'. This comment does not
--                   list them. It used to, and the list was wrong in both
--                   directions: two names in it are emitted nowhere and most of the
--                   names the app does emit were missing. The set is whatever the
--                   pl_audit() callers pass, so read it from them:
--                       grep -rn 'pl_audit(' cms
--                   Two callers in system-users.php pass a variable; the names are
--                   assigned on the line above each call. No application code reads
--                   this column by a hard-coded name, so a caller may add one
--                   without a migration (the smoke tests do query some names).
--                   Keep a new name to lowercase letters, digits, '.' and '_', at
--                   most 64 characters: the action filter in system-audit.php
--                   accepts only those.
--   object_type  -- optional lowercase label for what object_id names, such as
--                   'user', 'case', 'activity' or 'setting'. It may be set with a
--                   NULL object_id. NULL when the event has no target, as a failed
--                   login with an unknown username does. Same rule as above: the
--                   callers define the set, not this comment.
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
