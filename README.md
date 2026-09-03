# Portainer GitOps stacks

This repository is the source of truth for Docker Swarm stacks synchronized by
Portainer. Each top-level directory is one independently deployed stack.

## Repository layout

| Stack | Compose path | Purpose | Dependencies |
| --- | --- | --- | --- |
| `portainer` | `portainer/docker-compose.yml` | Portainer CE Swarm management | Synology Docker volume path, NFS |
| `grafana` | `grafana/docker-compose.yml` | Grafana LGTM observability | NFS |
| `platform` | `platform/docker-compose.yml` | Config, Eureka, Admin, Gateway | `grafana_default` |
| `chzzk` | `chzzk/docker-compose.yml` | nyang-nyang-bot | `platform_default`, `grafana_default`, NFS |
| `evergreen` | `evergreen/docker-compose.yml` | Lotto and coin services | `platform_default`, `grafana_default` |
| `bitwarden` | `bitwarden/docker-compose.yml` | Vaultwarden | NFS |
| `flame` | `flame/docker-compose.yml` | Flame dashboard | NFS |
| `redis` | `redis/docker-compose.yml` | Redis data store | NFS |

## New stack template

Copy `_template` when adding a stack, then replace every `REPLACE_*`, `app`,
`APP_SECRET`, and `app_data` value with names appropriate for that service.
Remove the environment or volume section when the service does not need it;
do not retain placeholder or unused configuration.

The template intentionally follows the repository defaults: an explicit image
version, secret-only environment interpolation, a service-specific liveness
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
and currently contain no healthcheck process, so `platform`, `chzzk`, and
`evergreen` must not receive a shell-based check. Add the Paketo health-checker
at image build time before enabling their Actuator liveness probes in Swarm.

## Portainer GitOps

1. Create Git-backed stacks for `grafana`, `platform`, `chzzk`, `evergreen`,
   `bitwarden`, `flame`, and `redis`. Keep the `portainer` stack manually
   managed so a failed self-update cannot disable its own control plane.
2. Use branch `main`, the directory name as the stack name, and the listed
   Compose path.
3. Enter values from each `.env.example` in the Portainer stack environment.
   Do not commit the real `.env` file.
4. Complete and verify the first manual deployment.
5. Enable GitOps automatic updates with five-minute polling. Keep **Re-pull
   image and redeploy** and **Force redeployment** disabled because application
   deployments use a changed immutable image tag.

### Compose path migration

This repository uses `docker-compose.yml` for every stack and the template.
Portainer stores the Compose path configured when a Git-backed stack is created,
so renaming the repository file does not update an existing stack automatically.
Before merging this rename, pause polling for every existing Git-backed stack.
After the merge, change each stack's Compose path from `STACK/compose.yaml` to
`STACK/docker-compose.yml`. If the installed Portainer version does not allow
the path to be edited, retain its environment values and recreate the stack
with the new path. Pull and redeploy each stack manually, verify it is stable,
and only then re-enable polling.

The `portainer` Compose file remains the reviewed desired state for manual
updates. Dependabot may propose its version changes, but those changes are not
automatically deployed.

When applying the initial conversion from mutable tags (`latest` or `lts`) to
explicit versions, pause automatic updates for the affected Portainer stacks.
Changing the image string replaces Swarm tasks even when both tags currently
resolve to the same image digest. Merge the baseline, redeploy and verify one
stack at a time in the dependency order below, then re-enable polling.

Deploy in this order because the application stacks use networks created by the
first two stacks:

1. `portainer` and `grafana`
2. `platform`
3. `chzzk` and `evergreen`
4. `bitwarden`, `flame`, and `redis`

### `spring` to `platform` migration

The Portainer stack name determines Swarm service and default network names, so
this rename is not an in-place update. Before merging the rename, disable GitOps
polling for `spring`, `chzzk`, and `evergreen` and retain their Portainer
environment values. After the merge:

1. Remove the `chzzk` and `evergreen` stacks so they release `spring_default`.
2. Remove the old `spring` stack.
3. Create and verify the `platform` stack from `platform/docker-compose.yml`.
4. Recreate `chzzk` and `evergreen`; they now attach to `platform_default`.
5. Re-enable polling after all three stacks are stable.

This migration interrupts the dependent applications. If it fails, revert the
rename commit and recreate the stacks in the old dependency order.

Treat Git as the only source of stack configuration. Local edits in Portainer
are overwritten by the next Git pull, so make structural and version changes
through pull requests in this repository.

## Image version ownership

Image names and deployment tags are declared directly in each tracked
`docker-compose.yml`. Do not move them into Portainer's local environment values;
doing so would make the running version invisible to GitOps review.

Application pipelines build and push immutable tags but do not select the
production version. Dependabot detects newer SemVer image tags and proposes the
matching `image:` change in this repository. A merge to `main` is detected by
Portainer polling and rolls out only the changed Swarm service.

## Dependabot image updates

`.github/dependabot.yml` uses one Docker Compose update configuration for all
eight deployed stack directories, scheduled with a five-minute cron. GitHub may
start a scheduled Dependabot run later than the nominal time. The normal
three-day version cooldown is disabled. Each image update remains an independent
pull request so that deployment and rollback stay scoped to one service. Review
Portainer Agent and Server compatibility before merging either image update.

Dependabot only opens a pull request. `.github/workflows/validate-compose.yaml`
renders every deployed Compose file, and a maintainer merges the PR after the
check succeeds. Portainer deploys the merged desired state on its next poll.

```text
application main -> test -> image:{version} -> release
                                      |
                                      v
Dependabot -> GitOps PR -> Compose validation -> merge
                                                   |
                                                   v
Portainer polling -> Docker Swarm rolling update
```

If deployment fails, revert the GitOps version commit. Swarm's
`failure_action: rollback` can restore runtime tasks, but it does not change the
version recorded in Git. Add a temporary `ignore` rule for a failed image
version before reverting so Dependabot does not immediately propose it again:

```yaml
ignore:
  - dependency-name: "now-start/gateway"
    versions:
      - "6.1.1"
```

## Required Portainer environment values

Do not commit real values for these variables:

| Stack | Required variables |
| --- | --- |
| `bitwarden` | `BITWARDEN_SSO_CLIENT_SECRET` |
| `grafana` | `GRAFANA_OAUTH_CLIENT_SECRET`, `GRAFANA_SMTP_PASSWORD` |
| `platform` | `SPRING_ENCRYPT_KEY` |
| `flame` | `FLAME_PASSWORD` |
| `redis` | `REDIS_PASSWORD` |

Only secret variable names are tracked in `.env.example` templates. Real `.env`
files contain secrets only and are ignored; keep their values in Portainer. Images,
ports, domains, network/storage paths, and other non-sensitive settings belong
in the tracked Compose files. If a credential was previously committed or
shared in plain text, rotate it before deployment.

## Swarm prerequisites

- The selected Portainer environment must be a Swarm manager.
- Every Swarm node must expose Docker volumes at `/volume1/@docker/volumes` for the Portainer Agent.
- The Portainer default overlay uses MTU `1200` to fit VXLAN traffic inside Tailscale.
- Every stack-owned overlay network uses MTU `1200`; recreate existing networks before redeploying changed stacks.
- Recreate the Swarm `ingress` network with MTU `1200` before deploying services that publish ports.
- `grafana_default` must exist before `platform`, `chzzk`, or `evergreen` deploys.
- `platform_default` must exist before `chzzk` or `evergreen` deploys.
- Every eligible node must be able to mount NFSv4 from the `NOW_START` Tailscale address `100.100.1.1`.
- DSM NFS permissions must allow the Tailscale client range `100.64.0.0/10`.
- The manager must be authenticated to `ghcr.io` for private images.
- Published ports `1080`, `3000`, `5005`, `6379`, `8000`, and `9443` must be available.

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
  docker stack config -c bitwarden/docker-compose.yml >/dev/null

FLAME_PASSWORD=test docker stack config -c flame/docker-compose.yml >/dev/null

GRAFANA_OAUTH_CLIENT_ID=test GRAFANA_OAUTH_CLIENT_SECRET=test \
GRAFANA_SMTP_USER=test GRAFANA_SMTP_PASSWORD=test \
  docker stack config -c grafana/docker-compose.yml >/dev/null

SPRING_ENCRYPT_KEY=test docker stack config -c platform/docker-compose.yml >/dev/null

docker stack config -c chzzk/docker-compose.yml >/dev/null
docker stack config -c evergreen/docker-compose.yml >/dev/null

REDIS_PASSWORD=test docker stack config -c redis/docker-compose.yml >/dev/null

docker stack config -c portainer/docker-compose.yml >/dev/null
```

After deployment, verify the actual scheduler and network state:

```sh
docker stack services STACK_NAME
docker stack ps --no-trunc STACK_NAME
docker network inspect grafana_default
docker network inspect platform_default
docker service ps --no-trunc portainer_agent
```

Syntax validation does not prove NFS availability, registry authentication,
service readiness, or cross-node overlay connectivity.
