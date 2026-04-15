ARG PHP_VERSION=8.4

FROM php:${PHP_VERSION}-cli

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm git openssh-client default-mysql-client default-mysql-server \
    && rm -rf /var/lib/apt/lists/* \
    && install-php-extensions intl zip pdo_mysql mbstring bcmath pcntl

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
