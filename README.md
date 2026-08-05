# Arcane infrastructure stacks

This repository is the source of truth for Docker Swarm stacks synchronized by
Arcane. Each top-level directory is one independently deployed stack.

## Repository layout

| Stack | Compose path | Purpose | Dependencies |
| --- | --- | --- | --- |
| `portainer` | `portainer/compose.yaml` | Portainer CE Swarm management | Synology Docker volume path, NFS |
| `grafana` | `grafana/compose.yaml` | Grafana LGTM observability | NFS |
| `spring` | `spring/compose.yaml` | Config, Eureka, Admin, Gateway | `grafana_default` |
| `chzzk` | `chzzk/compose.yaml` | nyang-nyang-bot | `spring_default`, `grafana_default`, NFS |
| `evergreen` | `evergreen/compose.yaml` | Lotto and coin services | `spring_default`, `grafana_default` |
| `bitwarden` | `bitwarden/compose.yaml` | Vaultwarden | NFS |
| `flame` | `flame/compose.yaml` | Flame dashboard | NFS |
| `redis` | `redis/compose.yaml` | Redis data store | NFS |

## New stack template

Copy `_template` when adding a stack, then replace every `REPLACE_*`, `app`,
`APP_SECRET`, and `app_data` value with names appropriate for that service.
Remove the environment or volume section when the service does not need it;
do not retain placeholder or unused configuration.

The template intentionally follows the repository defaults: the `latest` image
tag, secret-only environment interpolation, a service-specific liveness
healthcheck, NFS-backed storage, and the common single-replica Swarm update and
rollback policy. A healthcheck must test the service itself without depending
on an external database or API, to avoid cascading restarts.
Replace the template's `CMD-SHELL` with exec-form `CMD` when the image provides
a dedicated checker, and use `CMD-SHELL` only after confirming that the image
contains a shell and every command used by the check.

The common policy uses a 60-second healthcheck start period, a three-minute
update and rollback monitor, automatic rollback for failed updates, and restart
condition `any`. Only the healthcheck command varies by service. Stacks whose
images do not provide a usable checker still use the same deploy policy without
a healthcheck.

## Health checks

Healthchecks are enabled only when the image contains a verified checker:
Vaultwarden and Grafana use their bundled scripts, Flame uses Node.js, and
Redis uses an authenticated `PING`. The Spring buildpack images are shell-less
and currently contain no healthcheck process, so `spring`, `chzzk`, and
`evergreen` must not receive a shell-based check. Add the Paketo health-checker
at image build time before enabling their Actuator liveness probes in Swarm.

## Arcane Git Sync

1. In **Customize -> Git Repositories**, add this repository and configure its
   SSH key. Keep host-key verification enabled.
2. Select the Docker Swarm manager environment.
3. Under **Swarm -> Stacks**, create one Git sync per row in the table above.
   Use branch `main`, the directory name as the stack name, and the listed
   Compose path.
4. Enable automatic synchronization only after the first manual deployment has
   succeeded.
5. For a stack that has `.env.example`, create the Git sync first, then copy it
   into Arcane's `.env` editor and enter its secret values before deploying.
   Secret variables render as empty during the initial Git validation so the
   sync can be created; do not treat a successful sync as deployment readiness.

Deploy in this order because the application stacks use networks created by the
first two stacks:

1. `portainer` and `grafana`
2. `spring`
3. `chzzk` and `evergreen`
4. `bitwarden`, `flame`, and `redis`

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
| `redis` | `REDIS_PASSWORD` |

Only secret variable names are tracked in `.env.example` templates. Real `.env`
files contain secrets only and are ignored; keep their values in Arcane. Images,
ports, domains, network/storage paths, and other non-sensitive settings belong
in the tracked Compose files. If a credential was previously committed or
shared in plain text, rotate it before deployment.

## Swarm prerequisites

- The selected Arcane environment must be a Swarm manager.
- Every Swarm node must expose Docker volumes at `/volume1/@docker/volumes` for the Portainer Agent.
- The Portainer default overlay uses MTU `1200` to fit VXLAN traffic inside Tailscale.
- Every stack-owned overlay network uses MTU `1200`; recreate existing networks before redeploying changed stacks.
- Recreate the Swarm `ingress` network with MTU `1200` before deploying services that publish ports.
- `grafana_default` must exist before `spring`, `chzzk`, or `evergreen` deploys.
- `spring_default` must exist before `chzzk` or `evergreen` deploys.
- Every eligible node must be able to mount NFSv4 from the `NOW_START` Tailscale address `100.100.1.1`.
- DSM NFS permissions must allow the Tailscale client range `100.64.0.0/10`.
- The manager must be authenticated to `ghcr.io` for private images.
- Published ports `1080`, `5005`, `3000`, `8000`, and `9443` must be available.

After initializing a fresh Tailscale-backed Swarm and before deploying any
published service, recreate its routing-mesh network with the same MTU:

```sh
docker network rm ingress
docker network create --driver overlay --ingress \
  --opt com.docker.network.driver.mtu=1200 ingress
```

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

REDIS_PASSWORD=test docker stack config -c redis/compose.yaml >/dev/null

docker stack config -c portainer/compose.yaml >/dev/null
```

After deployment, verify the actual scheduler and network state:

```sh
docker stack services STACK_NAME
docker stack ps --no-trunc STACK_NAME
docker network inspect grafana_default
docker network inspect spring_default
docker service ps --no-trunc portainer_agent
```

Syntax validation does not prove NFS availability, registry authentication,
service readiness, or cross-node overlay connectivity.
