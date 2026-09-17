# syntax=docker/dockerfile:1
#
# Open Case Management — application container
#
# Apache + PHP 8.2. The database runs in a separate MariaDB container; see
# docker-compose.yml.
#
# This image is deliberately small. OCM is a PHP application with a MySQL
# database and nothing else: no queue, no cache server, no search service.
#
# The base image is pinned by digest as well as by tag. A tag is mutable: the
# name php:8.2-apache can be repointed at different bytes at any time, and a
# build that trusts only the name cannot tell that it happened. The digest
# names the exact image.
#
# The digest does not hold security updates back, but bumping it is not how
# they arrive. That was the earlier assumption here and it was wrong. Debian
# publishes a package fix days or weeks before the php image is rebuilt on top
# of it, so for that whole window the tag, the pinned digest and the newest
# digest are all the same bytes and all still vulnerable. Bumping the pin is
# then a no-op that looks like a fix. The gzip advisory below was exactly this:
# Debian had 1.13-1+deb13u1 in stable while every php:8.2-apache digest,
# including the newest one, still shipped 1.13-1.
#
# So the build takes the package updates itself, with the apt-get upgrade in
# the next stanza. The pin keeps the base layers reproducible; the upgrade
# keeps the packages current. The weekly Trivy scan
# (.github/workflows/trivy.yml) reports any vulnerability that has a fix
# available, and a finding there now means Debian has no fix yet, not that this
# line is stale.
#
# Bump the pin when moving to a newer base on purpose — a PHP patch release, a
# new Debian point release:
#   docker pull php:8.2-apache
#   docker image inspect php:8.2-apache --format '{{index .RepoDigests 0}}'
#
FROM php:8.2-apache@sha256:f64f4ee8103510c4c1cb22c895235fb01018e4b5fd67b9f60a22f8f8dda68ccf

# Build dependencies for the PHP extensions, plus the command-line tools OCM
# shells out to. Each of those tools is a real call site, not a guess:
#
#   pdftotext (poppler-utils)  cms/app/lib/pikaDocument.php — indexes the text
#                              of an uploaded PDF so document search can find it
#   htmldoc                    cms/pl_report.php, app/extralib/lib/plWebDoc.php
#                              — renders a report to PDF
#   strings (binutils)         cms/app/scripts/forms2db.php — indexes the text
#                              of a WordPerfect document
#   mysql client               the entrypoint uses it to load the schema
#
# Ghostscript is deliberately absent. The older documentation lists it, but the
# only two ps2ascii calls in the tree are commented out; pdftotext replaced it.
#
# The upgrade is what takes Debian's security updates, for the reason given
# above the FROM line: a package fix reaches Debian stable well before the php
# image is rebuilt on top of it, and until that rebuild happens no digest of
# php:8.2-apache has the fix. Without this line the image carries whatever the
# pinned base shipped with, however old, and bumping the pin cannot help.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
        libxml2-dev \
        libonig-dev \
        libzip-dev \
        default-mysql-client \
        poppler-utils \
        htmldoc \
        binutils \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli \
        mbstring \
        opcache \
        zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Extensions not installed here, and why:
#   gd    Nothing uses it. The one <img> that would have needed it points at
#         cms/daily.php, which does not exist in this tree, and its only caller
#         is inside a commented-out block in cms/cal_day.php.
#   soap  No SoapClient or SoapServer anywhere in cms/.
# curl, dom, simplexml, json and openssl are all compiled into the base image
# already, so they need no line here.

# rewrite and headers are required by the shipped Apache configuration.
RUN a2enmod rewrite headers

COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/zz-ocm.ini
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

COPY cms        /var/www/html/cms
COPY cms-custom /opt/ocm/cms-custom-skel

# Branded 403/404/500 documents, served by Apache's ErrorDocument. They sit
# outside cms/ so that rendering one cannot re-trip the rules that produced
# the error; see the comment in docker/apache.conf.
COPY errors     /var/www/html/errors

# Uploaded documents and generated files live under cms/uploads and cms/tmp.
RUN mkdir -p /var/www/html/cms/uploads /var/www/html/cms/tmp \
    && chown -R www-data:www-data /var/www/html/cms

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]
