# Security Policy

## Reporting a vulnerability

Please report security issues privately, not as a public GitHub issue.

Use GitHub's private vulnerability reporting on this repository:
**Security -> Advisories -> Report a vulnerability**
(<https://github.com/amsclark/ocm/security/advisories/new>)

Include the affected file and version, what an attacker can do, and the steps to
reproduce. A proof-of-concept request or SQL statement helps most.

We aim to acknowledge a report within 5 working days. Please give us 90 days
before public disclosure, or less by agreement if a fix ships sooner.

## Supported versions

Only the `master` branch of this repository receives security fixes. There are no
maintained release branches and no backports to older checkouts.

This repository is a **frozen 2019 feature set**. It receives security fixes and
bug fixes only. New features are not added here.

## Scope

In scope: the PHP application under `cms/`, the default configuration in
`cms-custom/`, the SQL installer in `cms/app/sql/install/`, and the sample Apache
configuration in `httpd-config/`.

Out of scope:

- Findings that need an already-authenticated administrator, where an
  administrator is expected to have that power (an admin editing a report
  template, for example).
- Missing hardening headers on a deployment you control. Those are the
  deployment's responsibility; see the Apache samples.
- Reports from an automated scanner with no demonstrated impact.
- Any hosted service. This policy covers the source in this repository only.

## Known limitations of this codebase

Be aware of these before deploying. They are not accepted as new reports.

- `cms/app/lib/DB.php` keeps a legacy `mysql_*` code path behind the
  `PIKACMS_MYSQLI_MODE` flag. Run with `mysqli` mode on. The legacy path is
  retained only for old deployments and is not maintained.
- The application expects to run behind a web server that terminates TLS and
  restricts access to `cms-custom/config/`. The sample Apache configuration in
  `httpd-config/` shows the required restrictions.

## Credit

We will credit reporters in the advisory unless you ask us not to.
