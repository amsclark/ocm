-- add_groups_intake.sql — the `intake` security-group permission.
--
-- Why this column exists:
-- pika_authorize() used to grant BOTH read_case and edit_case to every
-- authenticated user whenever the case row had a NULL user_id or a NULL
-- office. The comment beside those two branches said "this is handy for
-- intake staff who don't have a default office set" — which is a real
-- need, but the grant was unconditional, so it applied to every user in
-- every group. A user whose group had read_all=0, edit_all=0 and no
-- office in read_office/edit_office could still read AND fully edit any
-- case that had no handler assigned or no office assigned. That is
-- CWE-639, authorization bypass through a user-controlled key, and on a
-- legal-aid installation the unassigned cases are precisely the new
-- intakes: the most sensitive records in the system.
--
-- This column turns the intent into an actual permission. Grant `intake`
-- to whichever group does intake at your organisation (System > Security
-- Levels); every other group loses the automatic grant.
--
-- Default 0 is deliberate and it is a BEHAVIOUR CHANGE on upgrade: after
-- this runs, nobody has the grant until an administrator gives it out.
-- Defaulting to 1 would preserve the vulnerability for every existing
-- installation, which defeats the point. If your intake staff report
-- that unassigned cases have disappeared from their case list, that is
-- this change, and the fix is to set Intake Access to Yes on their
-- security level.
--
-- Idempotent: safe to replay. MariaDB has no portable "ADD COLUMN IF NOT
-- EXISTS" that also works on MySQL 5.x, so the column is added through a
-- prepared statement that becomes a no-op when it is already there.

SET @col_exists = (
	SELECT COUNT(*)
	FROM information_schema.COLUMNS
	WHERE TABLE_SCHEMA = DATABASE()
	  AND TABLE_NAME = 'groups'
	  AND COLUMN_NAME = 'intake'
);

SET @ddl = IF(@col_exists = 0,
	"ALTER TABLE `groups` ADD COLUMN `intake` tinyint(4) NOT NULL DEFAULT '0' AFTER `motd`",
	"DO 0"
);

PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
