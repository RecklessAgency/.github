#!/bin/sh
set -e

# ── Clone repo ────────────────────────────────────────────────
echo "Cloning ${REPO_ORG}/${REPO_NAME} (branch: ${BRANCH})..."
git clone --depth=1 --branch="${BRANCH}" \
    "https://${GITHUB_TOKEN}@github.com/${REPO_ORG}/${REPO_NAME}.git" \
    /var/www/html
cd /var/www/html

# ── PHP dependencies ──────────────────────────────────────────
composer install --no-dev --optimize-autoloader --no-interaction --no-scripts --ignore-platform-reqs

# ── JS dependencies & assets ──────────────────────────────────
if [ -f package.json ]; then
    npm ci
    npm run production 2>/dev/null || npm run build 2>/dev/null || true
    rm -rf node_modules
fi

php artisan package:discover --ansi 2>/dev/null || true

# ── Database (optional) ───────────────────────────────────────
# If docker/preview-db-init.sh exists, start a local MySQL and run it.
# Projects that don't need a local DB simply omit this file.
if [ -f docker/preview-db-init.sh ]; then
    mkdir -p /var/lib/mysql /run/mysqld
    chown -R mysql:mysql /var/lib/mysql /run/mysqld

    if [ ! -d /var/lib/mysql/mysql ]; then
        mysql_install_db --user=mysql --datadir=/var/lib/mysql --skip-test-db > /dev/null
    fi

    mysqld_safe --user=mysql --skip-networking=0 &

    echo "Waiting for MySQL..."
    until mysqladmin ping --silent 2>/dev/null; do
        sleep 1
    done

    sh docker/preview-db-init.sh

    export DB_HOST=
    export DB_SOCKET=/var/run/mysqld/mysqld.sock
    export DB_USERNAME=root
    export DB_PASSWORD=
fi

# ── Preview defaults ──────────────────────────────────────────
export CACHE_DRIVER=${CACHE_DRIVER:-file}
export SESSION_DRIVER=${SESSION_DRIVER:-file}
export QUEUE_CONNECTION=${QUEUE_CONNECTION:-sync}

# ── Start ─────────────────────────────────────────────────────
if [ -f artisan ]; then
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan migrate --force
    exec php artisan serve --host=0.0.0.0 --port=80
fi

if [ -f docker/preview-start.sh ]; then
    exec sh docker/preview-start.sh
fi

echo "ERROR: No known start command. Provide docker/preview-start.sh for non-Laravel projects."
exit 1
