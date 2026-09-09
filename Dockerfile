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

# System libraries needed to build the PHP extensions, plus ghostscript, which
# OCM shells out to when it indexes the text of an uploaded PDF.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpng-dev \
        libjpeg62-turbo-dev \
        libxml2-dev \
        libonig-dev \
        libzip-dev \
        default-mysql-client \
        ghostscript \
    && docker-php-ext-configure gd --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli \
        gd \
        mbstring \
        soap \
        opcache \
        zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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
