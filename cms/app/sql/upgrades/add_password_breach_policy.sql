-- add_password_breach_policy.sql -- refuse, or warn about, a password that
-- is already public.
--
-- Length and character-class rules do not catch the passwords that actually
-- get accounts taken over. Those are the ones already in a credential-
-- stuffing list -- Passw0rd!, Summer2024!, the organisation's own name with
-- a digit after it -- and every one of them satisfies every strength rule
-- this application has.
--
-- With this on, a password being set is checked against Have I Been Pwned's
-- Pwned Passwords index. The password is not sent. It is hashed, the first
-- five hex characters of the hash go to the service, the service returns
-- every hash it holds that starts with those five, and the comparison
-- happens on this server. See cms/app/lib/plPasswordBreach.php.
--
--   password_breach_policy   'off'   never ask. The default.
--                            'warn'  tell the user, allow the change.
--                            'block' refuse the change.
--
--   password_breach_api_url  Overrides the service address. There is
--                            deliberately no field for this on any admin
--                            screen: it exists so an automated test can
--                            stand up a local service instead of calling a
--                            real one. Blank means the real one.
--
-- OFF by default, and that is deliberate. Turning it on makes this server
-- contact a third party every time somebody sets a password. Nothing secret
-- leaves -- five hex characters of a SHA-1 -- but the request itself is an
-- outbound connection some deployments are not allowed to make, and it is
-- not this file's place to decide that for them. An administrator turns it
-- on from System > Settings.
--
-- A password is never refused because the service could not be reached.

INSERT IGNORE INTO settings (label, value) VALUES
	('password_breach_policy',  'off'),
	('password_breach_api_url', '');
