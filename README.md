# .github
Reusable GitHub Actions workflows for R3 projects.

## Workflows

### `preview-deploy.yml` / `preview-teardown.yml`

Spin up and tear down ephemeral preview environments for pull requests.

#### Architecture

```
Visitor (HTTPS) → Cloudflare Edge → Cloudflare Worker → Fargate task (HTTP, public IP)
```

- **Hosting**: AWS ECS Fargate `run-task` in a public subnet. No ALB — each task gets a public IP directly.
- **Routing**: A Cloudflare Worker acts as the reverse proxy. On deploy, the workflow writes `http://{public-ip}` to a Cloudflare KV namespace under the key `{branch-slug}--{project-slug}`. The Worker looks up the key on each request and proxies to it. On teardown, the KV entry is removed.
- **TLS**: Cloudflare terminates HTTPS for visitors. The Worker→container leg is plain HTTP over the public internet. Acceptable for preview environments (ephemeral, non-production data). For sensitive data, consider Cloudflare Tunnel with private subnets instead (requires a NAT gateway).
- **Container image**: The generic `reckless/php:{version}` ECR image is shared across all projects. At startup, the container clones the project repo using an SSH deploy key (passed base64-encoded as `DEPLOY_KEY`), runs `composer install` + `npm build`, migrates, and serves via `php artisan serve`.
- **Deploy key**: An ed25519 key committed to each project repo at `docker/preview-deploy-key`. GitHub Actions reads and base64-encodes it into the Fargate task environment. Read-only, no expiry.
- **DNS**: `*.rnmtest.co.uk` wildcard A record (proxied) → Cloudflare Worker route `*.rnmtest.co.uk/*`.

#### Triggering

Add the `preview` label to a PR → deploy. Remove the label or close the PR → teardown.

Preview URL format: `https://{branch-slug}--{project-slug}.rnmtest.co.uk`

#### Per-project setup

Run `/workflow-setup` in Claude Code to create `.claude/project.json`, `.github/workflows/preview.yml`, and the SSH deploy key for a new project.

#### Optional database

If the project includes `docker/preview-db-init.sh`, the container starts a local MySQL instance and runs the script before booting the app. The script receives a running MySQL server (root, no password, unix socket) and must export `DB_DATABASE`.

---

### `build-php-image.yml`

Builds and pushes the `reckless/php` base image to ECR.

- **Trigger**: Push to `main` when `docker/php/**` changes, or manually via `workflow_dispatch` (with optional `php_version` input, defaults to `8.4`).
- **Platform**: `linux/arm64` (matches Fargate task definition and Apple Silicon dev machines).
- **Tags**: `:8.4` (mutable, always latest) and `:8.4-{sha}` (immutable, for rollback).
- **Source**: `docker/php/` — `Dockerfile` + `entrypoint.sh`.

The entrypoint handles: SSH deploy key setup, `git clone`, `composer install`, optional `npm build`, optional local MySQL (if `docker/preview-db-init.sh` exists), Laravel caches, `php artisan migrate`, then `php artisan serve`.

To rebuild manually (e.g. after updating the entrypoint or Dockerfile): **Actions → Build PHP Base Image → Run workflow**.

---

#### Shared AWS infrastructure (one-time setup)

| Resource | Value |
|---|---|
| VPC subnets | `subnet-60a76a09`, `subnet-2c73a757`, `subnet-62ac422f` |
| Security group | `sg-0d773f640262948ac` (port 80 open) |
| GitHub Actions IAM role | `arn:aws:iam::115900265633:role/github-actions-preview` |
| ECS execution role | `arn:aws:iam::115900265633:role/ecs-preview-execution` |
| ECR image | `115900265633.dkr.ecr.eu-west-2.amazonaws.com/reckless/php:8.4` |
| Cloudflare KV namespace | `1bb0fc32aa594b6497860018ef198dbd` |
| Cloudflare Worker | `preview-router.dev-961.workers.dev` |
