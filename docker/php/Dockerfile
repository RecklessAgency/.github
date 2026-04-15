ARG PHP_VERSION=8.4

FROM serversideup/php:${PHP_VERSION}-cli

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client mariadb-client mariadb-server curl \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && install-php-extensions intl bcmath

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
