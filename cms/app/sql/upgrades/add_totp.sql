-- TOTP (RFC 6238) two-factor authentication for staff accounts.
--
-- Three columns on `users` plus the per-user "is 2FA on" lookup menu:
--   totp_enabled    -- 1 = on, 0 = off, 2 = "Reset" (an admin-side action that
--                      clears the stored secret so the user enrols again)
--   totp_secret     -- the base32 shared secret, stored as ciphertext with an
--                      "enc:" prefix (see cms/app/lib/pikaCrypto.php). The
--                      encryption key lives in the FILE cms-custom/config/
--                      settings.php under totp_encryption_key, never in the
--                      `settings` table, so a database dump cannot decrypt
--                      itself. 128 chars holds the base64 of a 32-byte secret
--                      plus its nonce and MAC with room to spare.
--   totp_last_used  -- the last 30-second window index accepted for this user.
--                      A code is refused if its window is at or below this, so
--                      an observed code cannot be replayed inside its validity
--                      window.
--
-- One ALTER per column on purpose: MariaDB applies NONE of the clauses in a
-- multi-clause "ALTER ... ADD COLUMN IF NOT EXISTS" when any single clause is
-- already satisfied, so a combined statement silently skips the new columns on
-- a partly-upgraded database.
--
-- Idempotent: re-running this script on an existing deployment is a no-op.

ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `totp_enabled` TINYINT(4);
ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `totp_secret` VARCHAR(128);
ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `totp_last_used` BIGINT DEFAULT NULL;

-- The UNIQUE key on `value` is part of the CREATE, not bolted on later. The
-- seed below is INSERT IGNORE, which skips a row only when it collides with a
-- UNIQUE or PRIMARY KEY; without one, every re-run of this file would append
-- another full copy of the seed and the picker would repeat every option.
CREATE TABLE IF NOT EXISTS `menu_totp_enabled` (
  `value` tinyint(4) NOT NULL DEFAULT '0',
  `label` char(65) NOT NULL DEFAULT '',
  `menu_order` tinyint(4) NOT NULL DEFAULT '0',
  UNIQUE KEY `value_uniq` (`value`),
  KEY `label` (`label`),
  KEY `menu_order` (`menu_order`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

INSERT IGNORE INTO `menu_totp_enabled` VALUES (1,'Yes',0),(0,'No',1),(2,'Reset',2);
