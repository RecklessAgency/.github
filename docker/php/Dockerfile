ARG PHP_VERSION=8.4

FROM php:${PHP_VERSION}-cli-alpine

RUN apk add --no-cache \
        nodejs npm git \
        icu-dev libzip-dev oniguruma-dev \
        mysql mysql-client \
    && docker-php-ext-install -j$(nproc) \
        intl zip pdo_mysql mbstring bcmath pcntl \
    && apk del icu-dev libzip-dev oniguruma-dev

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
