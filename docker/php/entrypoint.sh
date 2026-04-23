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
# Previews are private, short-lived, dev-facing — default to local/debug
# so developers see actual stack traces instead of generic 500s. Projects
# can still override via preview.env / task definition env vars.
export APP_ENV=${APP_ENV:-development}
export APP_DEBUG=${APP_DEBUG:-true}
export CACHE_DRIVER=${CACHE_DRIVER:-file}
export CACHE_QUERY_STORE=${CACHE_QUERY_STORE:-file}
export SESSION_DRIVER=${SESSION_DRIVER:-file}
export QUEUE_CONNECTION=${QUEUE_CONNECTION:-sync}
export LOG_CHANNEL=${LOG_CHANNEL:-stderr}
export APP_KEY=${APP_KEY:-$(php -r 'echo "base64:".base64_encode(random_bytes(32));')}

# ── Write resolved env to file for fast-path config:cache ─────
printenv | grep -E '^(APP_|DB_|CACHE_|SESSION_|QUEUE_|BROADCAST_|LOG_)' \
    | sed 's/^/export /' > /var/www/html/.preview-env

# ── JS dependencies & assets ──────────────────────────────────
if [ -n "$ASSETS_URL" ]; then
    echo "Downloading pre-built assets..."
    curl -fsSL "$ASSETS_URL" | tar -xz -C /var/www/html
elif [ -f package.json ]; then
    npm ci
    npm run production 2>/dev/null || npm run build 2>/dev/null || true
    rm -rf node_modules
fi

# ── Post-provision hook (cold start only) ────────────────────
if [ -f docker/preview-post-provision.sh ]; then
    echo "Running post-provision hook..."
    . docker/preview-post-provision.sh
fi

# ── Restore DB from nightly snapshot (if configured) ─────────
# When a project sets database_setup=backup in .r3/project.json,
# the workflow generates presigned URLs for schema + data and passes
# them as DB_BACKUP_SCHEMA_URL / DB_BACKUP_DATA_URL. We import both
# before running migrations so migrate only applies new changes.
# DB_RESTORED_FROM_BACKUP is exported so the deploy block (and any
# custom preview-deploy.sh) can skip db:seed.
if [ -n "$DB_BACKUP_SCHEMA_URL" ] && [ -n "$DB_BACKUP_DATA_URL" ]; then
    echo "Restoring database from nightly snapshot..."
    if curl -fsSL "$DB_BACKUP_SCHEMA_URL" | gunzip | \
            mysql -u "$DB_USERNAME" -p"$DB_PASSWORD" -h "$DB_HOST" "$DB_DATABASE" && \
       curl -fsSL "$DB_BACKUP_DATA_URL" | gunzip | \
            mysql -u "$DB_USERNAME" -p"$DB_PASSWORD" -h "$DB_HOST" "$DB_DATABASE"; then
        echo "Database restored successfully."
        export DB_RESTORED_FROM_BACKUP=true
    else
        echo "WARNING: Snapshot restore failed — migrations + seed will run instead."
    fi
fi

# ── Deploy commands ──────────────────────────────────────────
# If the project provides docker/preview-deploy.sh, it owns all
# framework-specific commands (caching, migrations, stache warming,
# file ownership). Otherwise fall back to standard Laravel defaults.
if [ -f docker/preview-deploy.sh ]; then
    echo "Running project deploy script..."
    . docker/preview-deploy.sh
elif [ -f artisan ]; then
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache
    php artisan migrate --force
    if [ "${DB_RESTORED_FROM_BACKUP:-false}" != "true" ]; then
        php artisan db:seed --force 2>/dev/null || true
    fi
    chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
fi

# ── Start ─────────────────────────────────────────────────────
# The serversideup base image starts nginx + PHP-FPM and defaults
# NGINX_WEBROOT to /var/www/html/public (Laravel convention).
# Non-Laravel projects (e.g. Bedrock) override this via preview.env:
#   NGINX_WEBROOT=/var/www/html/web
# We start FPM for any project that has artisan OR provides a deploy
# script. Projects that need a completely custom start use preview-start.sh.
if [ -f artisan ] || [ -f docker/preview-deploy.sh ]; then
    exec /usr/local/bin/docker-php-serversideup-entrypoint /init
elif [ -f docker/preview-start.sh ]; then
    exec sh docker/preview-start.sh
else
    echo "ERROR: No known start command. Provide docker/preview-deploy.sh or docker/preview-start.sh."
    exit 1
fi
