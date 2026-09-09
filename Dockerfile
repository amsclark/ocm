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
FROM php:8.2-apache

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

# Uploaded documents and generated files live under cms/uploads and cms/tmp.
RUN mkdir -p /var/www/html/cms/uploads /var/www/html/cms/tmp \
    && chown -R www-data:www-data /var/www/html/cms

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]
