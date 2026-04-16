#!/bin/sh
set -e

# ── Clone repo ────────────────────────────────────────────────
echo "Cloning ${REPO_ORG}/${REPO_NAME} (branch: ${BRANCH})..."

# Set up SSH deploy key if provided (base64-encoded in DEPLOY_KEY env var)
if [ -n "$DEPLOY_KEY" ]; then
    mkdir -p /root/.ssh
    echo "$DEPLOY_KEY" | base64 -d > /root/.ssh/deploy-key
    chmod 600 /root/.ssh/deploy-key
    printf "Host github.com\n  IdentityFile /root/.ssh/deploy-key\n  StrictHostKeyChecking no\n" > /root/.ssh/config
    GIT_URL="git@github.com:${REPO_ORG}/${REPO_NAME}.git"
else
    GIT_URL="https://${GITHUB_TOKEN}@github.com/${REPO_ORG}/${REPO_NAME}.git"
fi

git clone --depth=1 --branch="${BRANCH}" "${GIT_URL}" /var/www/html
git config --global --add safe.directory /var/www/html
cd /var/www/html

# ── PHP dependencies ──────────────────────────────────────────
composer install --no-dev --optimize-autoloader --no-interaction --no-scripts --ignore-platform-reqs

php artisan package:discover --ansi 2>/dev/null || true

# ── Database (optional) ───────────────────────────────────────
# If docker/preview-db-init.sh exists, start a local MySQL and run it.
# Projects that don't need a local DB simply omit this file.
if [ -f docker/preview-db-init.sh ]; then
    mkdir -p /var/lib/mysql
    mkdir -p /var/run/mysqld
    ln -sf /var/run/mysqld /run/mysqld 2>/dev/null || true
    chown -R mysql:mysql /var/lib/mysql /var/run/mysqld

    if [ ! -d /var/lib/mysql/mysql ]; then
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql --skip-test-db > /dev/null
    fi

    mariadbd-safe --user=mysql --skip-networking=0 --log-error=/var/lib/mysql/mysqld.err &

    echo "Waiting for MySQL..."
    until mariadb-admin ping --silent 2>/dev/null; do
        sleep 1
    done

    # Source (not sh) so DB_* exports from the init script propagate here
    . docker/preview-db-init.sh
fi

# ── Preview defaults ──────────────────────────────────────────
export CACHE_DRIVER=${CACHE_DRIVER:-file}
export CACHE_QUERY_STORE=${CACHE_QUERY_STORE:-file}
export SESSION_DRIVER=${SESSION_DRIVER:-file}
export QUEUE_CONNECTION=${QUEUE_CONNECTION:-sync}
export LOG_CHANNEL=${LOG_CHANNEL:-stderr}
export APP_KEY=${APP_KEY:-$(php -r 'echo "base64:".base64_encode(random_bytes(32));')}

# ── Write resolved env to file for fast-path config:cache ─────
printenv | grep -E '^(APP_|DB_|CACHE_|SESSION_|QUEUE_|BROADCAST_|LOG_)' \
    | sed 's/^/export /' > /var/www/html/.preview-env

# ── Start ─────────────────────────────────────────────────────
if [ -f artisan ]; then
    # ── JS dependencies & assets ──────────────────────────────
    # Assets must be present before view:cache so mix() calls resolve correctly
    if [ -n "$ASSETS_URL" ]; then
        echo "Downloading pre-built assets..."
        curl -fsSL "$ASSETS_URL" | tar -xz -C /var/www/html
    elif [ -f package.json ]; then
        npm ci
        npm run production 2>/dev/null || npm run build 2>/dev/null || true
        rm -rf node_modules
    fi

    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan migrate --force
    php artisan db:seed --force 2>/dev/null || true

    # ── Project-specific post-provision hook ─────────────────────
    # Runs after DB setup but before PHP-FPM starts. Good place for CMS
    # bootstrap (folder skeletons, cache warming, search indexing).
    # Sourced so any exports propagate. Projects omit the file if unused.
    if [ -f docker/preview-post-provision.sh ]; then
        echo "Running post-provision hook..."
        . docker/preview-post-provision.sh
    fi

    # ── Fix ownership for PHP-FPM (serversideup image runs as webuser uid 9999) ──
    chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache

    exec /usr/local/bin/docker-php-serversideup-entrypoint /init
fi

if [ -f docker/preview-start.sh ]; then
    exec sh docker/preview-start.sh
fi

echo "ERROR: No known start command. Provide docker/preview-start.sh for non-Laravel projects."
exit 1
