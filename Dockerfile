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
# Pinning does not hold security updates back here. Debian ships most of its
# fixes as a rebuilt base image rather than as something this Dockerfile could
# patch, so the way to take them is to bump the digest. The weekly Trivy scan
# (.github/workflows/trivy.yml) reports any vulnerability that has a fix
# available, so a fix landing upstream turns into an alert that says to bump
# this line.
#
# To bump it:
#   docker pull php:8.2-apache
#   docker inspect --format '{{index .RepoDigests 0}}' php:8.2-apache
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
RUN apt-get update && apt-get install -y --no-install-recommends \
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
