# Arcane infrastructure stacks

This repository is the source of truth for Docker Swarm stacks synchronized by
Arcane. Each top-level directory is one independently deployed stack.

## Repository layout

| Stack | Compose path | Purpose | Dependencies |
| --- | --- | --- | --- |
| `grafana` | `grafana/compose.yaml` | Grafana LGTM observability | NFS |
| `spring` | `spring/compose.yaml` | Config, Eureka, Admin, Gateway | `grafana_default` |
| `chzzk` | `chzzk/compose.yaml` | nyang-nyang-bot | `spring_default`, `grafana_default`, NFS |
| `evergreen` | `evergreen/compose.yaml` | Lotto and coin services | `spring_default`, `grafana_default` |
| `bitwarden` | `bitwarden/compose.yaml` | Vaultwarden | NFS |
| `flame` | `flame/compose.yaml` | Flame dashboard | NFS |

## Arcane Git Sync

1. In **Customize -> Git Repositories**, add this repository and configure its
   SSH key. Keep host-key verification enabled.
2. Select the Docker Swarm manager environment.
3. Under **Swarm -> Stacks**, create one Git sync per row in the table above.
   Use branch `main`, the directory name as the stack name, and the listed
   Compose path.
4. Enable automatic synchronization only after the first manual deployment has
   succeeded.
5. Copy the selected stack's `.env.example` into Arcane's `.env` editor, then
   enter its required values before deploying. Empty required values
   intentionally make Compose validation fail.

Deploy in this order because the application stacks use networks created by the
first two stacks:

1. `grafana`
2. `spring`
3. `chzzk` and `evergreen`
4. `bitwarden` and `flame`

Arcane redeploys a synchronized stack only when that stack is already running.
The repository Compose files remain read-only in Arcane; make structural changes
through Git.

## Image version ownership

Image names and deployment tags are declared directly in each tracked
`compose.yaml`. Do not move them into Arcane's local `.env`; doing so would make
the running version invisible to Git Sync.

Application pipelines should build and push an immutable tag (a release version
or commit SHA), then update the matching `image:` line in this repository. A push
to `main` is detected by Arcane Auto Sync and rolls out the changed Swarm service.
Use `latest` only as the initial value; replace it with immutable tags before
enabling unattended production updates.

## Required Arcane environment values

Do not commit real values for these variables:

| Stack | Required variables |
| --- | --- |
| `bitwarden` | `BITWARDEN_SSO_CLIENT_SECRET` |
| `grafana` | `GRAFANA_OAUTH_CLIENT_SECRET`, `GRAFANA_SMTP_PASSWORD` |
| `spring` | `SPRING_ENCRYPT_KEY` |
| `flame` | `FLAME_PASSWORD` |

Only secret variable names are tracked in `.env.example` templates. Real `.env`
files contain secrets only and are ignored; keep their values in Arcane. Images,
ports, domains, network/storage paths, and other non-sensitive settings belong
in the tracked Compose files. If a credential was previously committed or
shared in plain text, rotate it before deployment.

## Swarm prerequisites

- The selected Arcane environment must be a Swarm manager.
- `grafana_default` must exist before `spring`, `chzzk`, or `evergreen` deploys.
- `spring_default` must exist before `chzzk` or `evergreen` deploys.
- Every eligible node must be able to mount NFSv4 from `10.8.0.1`.
- The manager must be authenticated to `ghcr.io` for private images.
- Published ports `1080`, `5005`, `3000`, and `8000` must be available.

## Local validation

Validate interpolation with temporary, non-production values:

```sh
BITWARDEN_SSO_CLIENT_ID=test BITWARDEN_SSO_CLIENT_SECRET=test \
  docker stack config -c bitwarden/compose.yaml >/dev/null

FLAME_PASSWORD=test docker stack config -c flame/compose.yaml >/dev/null

GRAFANA_OAUTH_CLIENT_ID=test GRAFANA_OAUTH_CLIENT_SECRET=test \
GRAFANA_SMTP_USER=test GRAFANA_SMTP_PASSWORD=test \
  docker stack config -c grafana/compose.yaml >/dev/null

SPRING_ENCRYPT_KEY=test docker stack config -c spring/compose.yaml >/dev/null

docker stack config -c chzzk/compose.yaml >/dev/null
docker stack config -c evergreen/compose.yaml >/dev/null
```

After deployment, verify the actual scheduler and network state:

```sh
docker stack services STACK_NAME
docker stack ps --no-trunc STACK_NAME
docker network inspect grafana_default
docker network inspect spring_default
```

Syntax validation does not prove NFS availability, registry authentication,
service readiness, or cross-node overlay connectivity.
