-- add_sso.sql -- single sign-on over OpenID Connect.
--
-- Two things live here: the two columns on `users` that say how an account
-- is allowed to authenticate, and the transient table that carries one
-- OIDC handshake from the redirect out to the identity provider through to
-- the callback coming back.
--
-- Design, and the reasons for it:
--
--   * One identity provider per deployment. Each organisation running this
--     application configures its own IdP, so a per-user choice of provider
--     buys nothing and doubles the code that has to be right.
--
--   * Administrators pre-create every account. A successful sign-in at the
--     IdP for somebody with no user row is refused. There is no
--     auto-provisioning: an IdP that will issue a token for anyone in a
--     directory would otherwise mint case-management accounts for anyone in
--     that directory.
--
--   * Accounts are matched on the OIDC `sub` claim, not on an email
--     address. `sub` is stable and the IdP promises never to reissue it.
--     An email address is neither: a user whose address changes would lose
--     their account, and worse, an address reassigned to a new employee
--     would silently hand them the old one.
--
--   * An account with auth_method = 'sso' is refused by the password form,
--     even if a password hash is still on the row.
--
-- Each ALTER carries one clause on purpose. MariaDB applies NONE of the
-- clauses in a multi-clause "ALTER ... ADD COLUMN IF NOT EXISTS" once any
-- single clause is already satisfied, so a re-run after a partial upgrade
-- silently skips the rest. One statement per column cannot do that.

ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `auth_method` ENUM('password','sso') NOT NULL DEFAULT 'password';
ALTER TABLE `users` ADD COLUMN IF NOT EXISTS `sso_subject` VARCHAR(255) DEFAULT NULL;

-- The callback's only lookup is by sso_subject.
ALTER TABLE `users` ADD INDEX IF NOT EXISTS `idx_users_sso_subject` (`sso_subject`);

-- The handshake store.
--
-- pl_session_write() in cms/app/lib/pl.php is a no-op by design: this
-- application keeps cross-request state in its own tables and treats
-- $_SESSION as request-local scratch. An OIDC flow has to remember three
-- values across the round trip to the IdP -- the state, the nonce and the
-- PKCE code verifier -- and none of them can be handed to the browser,
-- because the whole point of each is that the browser cannot choose it.
-- So they go here, keyed on the session id from the cookie, which does
-- round-trip.
--
-- Rows are deleted as soon as the callback consumes them, and rows older
-- than the handshake timeout are pruned whenever a new flow starts. A real
-- sign-in completes in seconds.
CREATE TABLE IF NOT EXISTS `pika_sso_oidc_state` (
	`state_id`    int(10) unsigned NOT NULL AUTO_INCREMENT,
	`session_id`  varchar(128)     NOT NULL,
	`state_key`   varchar(64)      NOT NULL,
	`state_value` text             NOT NULL,
	`created_at`  timestamp        NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY (`state_id`),
	UNIQUE KEY `uniq_session_key` (`session_id`,`state_key`),
	KEY `idx_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

-- Configuration lives in the settings table because it is per-deployment
-- and an administrator sets it from System Settings.
--
--   sso_enabled                 0/1 master switch.
--   sso_provider                'google', 'entra' or 'generic'.
--   sso_tenant_id               Entra only: the directory (tenant) GUID.
--   sso_hosted_domain           Google only: the Workspace domain to pin
--                               sign-ins to, sent as the hd parameter.
--   sso_issuer_url              'generic' only: the issuer, e.g. a Keycloak
--                               realm URL. Must equal the iss claim exactly.
--   sso_discovery_url           Optional override for the discovery
--                               document. Blank means
--                               <issuer>/.well-known/openid-configuration.
--   sso_client_id               The application/client id at the IdP.
--   sso_client_secret           The client secret at the IdP.
--   sso_autobind_by_email       0/1. On first sign-in, bind an unknown sub
--                               to an existing account whose email matches
--                               the verified email claim. See §3 of
--                               docs/SSO.md.
--   sso_autobind_domains        Comma-separated allowlist of email domains
--                               auto-binding may match on. BLANK REFUSES
--                               EVERY BIND: an empty allowlist is a
--                               configuration mistake, not permission to
--                               bind anyone the IdP will issue a token for.
--   sso_allow_insecure_transport 0/1. Permits an http:// issuer. For a test
--                               harness only; there is deliberately no
--                               field for it on any admin screen.
INSERT IGNORE INTO settings (label, value) VALUES
	('sso_enabled',                 '0'),
	('sso_provider',                ''),
	('sso_tenant_id',               ''),
	('sso_hosted_domain',           ''),
	('sso_issuer_url',              ''),
	('sso_discovery_url',           ''),
	('sso_client_id',               ''),
	('sso_client_secret',           ''),
	('sso_autobind_by_email',       '0'),
	('sso_autobind_domains',        ''),
	('sso_allow_insecure_transport','0');
