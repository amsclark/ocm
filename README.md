# Open Case Management (OCM)

A case management system for not-for-profit legal aid organizations. It runs in
a web browser, and it is free software under the GPL v2.

OCM tracks intakes, cases, clients and contacts, calendars and deadlines, time
entries, documents, and the reporting a legal aid program needs for its
funders — including LSC case service reporting.

## Try it

Two commands. You need Docker with the Compose plugin, and nothing else.

```
git clone https://github.com/amsclark/ocm.git
cd ocm
cp .env.example .env      # then set DB_PASSWORD
docker compose up -d
```

Watch the first start — it builds the image and loads the schema, and prints
the generated admin password when it finishes:

```
docker compose logs -f app
```

Then open **http://127.0.0.1:8080/cms/** and log in.

Check it worked:

```
tests/smoke.sh
```

That should end with `241 passed, 0 failed`.

## Documentation

The [wiki](https://github.com/amsclark/ocm/wiki) is the place to look.

* [Installation with Docker](https://github.com/amsclark/ocm/wiki/Installation-with-Docker)
  — the above, in full: configuration, backups, upgrades, and what to do before
  putting real client data in it
* [Installation without Docker](https://github.com/amsclark/ocm/wiki/Installation-without-Docker)
  — Apache, PHP and MariaDB on a server you manage
* [Admin manual](https://github.com/amsclark/ocm/wiki/OCM-Admin-Manual)
  — configuration, users and permissions, customization, upgrades
* [User manual](https://github.com/amsclark/ocm/wiki/OCM-User-Manual)
  — intakes, cases, the calendar, reports

## Requirements

Running it directly rather than in a container:

| Component | Version |
|---|---|
| PHP | 8.0 – 8.3, with `mysqli`, `mbstring` and `zip` |
| MariaDB | 10.6 or newer, or MySQL 8.0 |
| Apache | 2.4, with `mod_rewrite` and `mod_headers` |

Three command-line tools, each enabling one feature: `pdftotext`
(`poppler-utils`) to index the text of uploaded PDFs, `htmldoc` to render
reports to PDF, and `strings` (`binutils`) to index WordPerfect documents.
Leave one out and that feature fails quietly — the upload still succeeds, but
document search will not find its contents.

`httpd-config/ocm.conf` is a ready-made Apache configuration. Use it. Among
other things it makes `cms-custom` unreachable over HTTP, and that directory
holds your database password.

## Security

Read [SECURITY.md](SECURITY.md) before running this anywhere that holds real
client data. It sets out what is supported, what is in scope, and how to report
a vulnerability privately.

Two things are worth knowing up front:

* **Put TLS in front of it.** Nothing in this repository terminates HTTPS. The
  in-application setting named "Allow Only Secure (HTTPS) Logins" sends a
  redirect and does no more than that — the web server is what enforces HTTPS.
* **This is a 2019 feature set.** See below.

## What this repository is

OCM is a fork of Pika CMS, which Aaron Worley released under the GPL. This
repository holds the 2019 feature set, and it stays there on purpose.

Development since then has continued in a private fork, which is where new
features go. What comes back here is security work and bug fixes, backported
from that fork. So this repository gets more secure and more correct over time
without growing new features, which keeps it a stable base for anyone running
it or building on it.

Commercial hosting and support are available from Case Management
Corporation, the maintainer of this repository.

## Contributing

Bug reports and pull requests are welcome
[on GitHub](https://github.com/amsclark/ocm/issues).

Two things will get a pull request merged faster:

* `tests/smoke.sh` passes.
* `php -l` is clean on every file you touched. CI checks both, on PHP 8.2.

Please do not send new features. They will not be merged here — see above. A
feature idea is still worth an issue; it may land in the private fork and reach
you that way if you are a hosting customer.

For anything that looks like a vulnerability, do not open an issue. Follow
[SECURITY.md](SECURITY.md).

## License

GPL v2. The full text is in [LICENSE](LICENSE).

Copyright of the original Pika CMS work remains with its authors.
