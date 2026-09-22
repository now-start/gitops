# Portainer GitOps stacks and shared CI

This repository is the source of truth for Docker Swarm stacks synchronized by
Portainer and the shared Java/Python application CI workflows. The stack
directories listed below are deployed independently.

## Shared application CI

Applications call `.github/workflows/reusable-java-app.yaml` or
`.github/workflows/reusable-python-app.yaml` from `now-start/gitops@main`.
See [the shared workflow guide](docs/shared-workflows.md) and `examples/` for
inputs, secrets, and caller configurations.

Pull requests run application tests. Main pushes publish immutable versioned
images and releases only when the application's version tag does not exist.
The application repository remains the checkout and image/release owner.

`Validate Workflows` runs actionlint and the existing Bats contract tests on
workflow, test, example, and Renovate configuration changes. Run the same checks
locally with `bash tests/run_tests.sh` (requires actionlint, Bats, Ruby, and jq).
The previous `now-start/workflow` repository is retained for migration
compatibility; new callers should use this repository.

## Repository layout

| Stack | Compose path | Purpose | Dependencies |
| --- | --- | --- | --- |
| `portainer` | `portainer/docker-compose.yml` | Portainer CE Swarm management | Synology Docker volume path, NFS |
| `grafana` | `grafana/docker-compose.yml` | Grafana LGTM observability | NFS |
| `platform` | `platform/docker-compose.yml` | Config, Eureka, Admin, Gateway | `grafana_default` |
| `chzzk` | `chzzk/docker-compose.yml` | nyang-nyang-bot | `platform_default`, `grafana_default`, NFS |
| `cockroachdb` | `cockroachdb/docker-compose.yml` | Distributed SQL cluster | local disk per node (not NFS), manager Docker socket |
| `evergreen` | `evergreen/docker-compose.yml` | Lotto and coin services | `platform_default`, `grafana_default` |
| `bitwarden` | `bitwarden/docker-compose.yml` | Vaultwarden | NFS |
| `flame` | `flame/docker-compose.yml` | Flame dashboard | NFS |
| `redis` | `redis/docker-compose.yml` | Redis data store | NFS |
| `renovate` | `renovate/docker-compose.yml` | Self-hosted Renovate that updates image tags and GitHub Actions dependencies | none |

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

Most services use one replicated task. In the `platform` stack, `config` and
`gateway` use global mode so Swarm runs one task on every eligible `x86_64`
node, which corresponds to their current `linux/amd64` images. `eureka` and
`admin` remain single-replica services. Remove the architecture constraint only
after both global images are published as multi-platform images.

The `evergreen` stack pins only `coin` to `node.hostname == NOW_START`; `lotto`
keeps the shared scheduling defaults. If that node is unavailable or drained,
`coin` cannot fail over to another node. Confirm the node's outbound public IP
is allowed by the Upbit API key; hostname placement does not guarantee a fixed IP.

## Health checks

Healthchecks are enabled only when the image contains a verified checker:
Vaultwarden and Grafana use their bundled scripts, Flame uses Node.js, and
Redis uses an authenticated `PING`. The Spring buildpack images are shell-less
and currently contain no healthcheck process, so `platform`, `chzzk`, and
`evergreen` must not receive a shell-based check. Add the Paketo health-checker
at image build time before enabling their Actuator liveness probes in Swarm.

## Portainer GitOps

1. Create Git-backed stacks for `grafana`, `platform`, `chzzk`, `cockroachdb`,
   `evergreen`, `bitwarden`, `flame`, and `redis`. Keep the `portainer` stack manually
   managed so a failed self-update cannot disable its own control plane.
2. Use branch `main`, the directory name as the stack name, and the listed
   Compose path.
3. Enter values from each `.env.example` in the Portainer stack environment.
   Do not commit the real `.env` file.
4. Complete and verify the first manual deployment.
5. Enable GitOps automatic updates with five-minute polling. Keep **Re-pull
   image and redeploy** and **Force redeployment** disabled because application
   deployments use a changed immutable image tag.

### CockroachDB cluster

The `cockroachdb` service uses `mode: global`, so Swarm runs one storage node
on every eligible Swarm node. Under `endpoint_mode: dnsrr`, `--join` uses the
short service DNS names `cockroachdb` and `tasks.cockroachdb`, because the
stack-prefixed service name does not resolve inside the stack network; adding
a Swarm node therefore adds a CockroachDB node without a repository change,
while removing one lets CockroachDB re-replicate its ranges automatically.
Neither direction needs operator action for the cluster to stay available,
assuming at least three nodes for the default replication factor of three.

The single-replica `init` service is a one-shot task that bootstraps the cluster
once and then stays in the `Complete` state, which Portainer displays as `0/1`;
that is expected and not a failure. It is idempotent: whenever Swarm recreates it
(a changed service spec, a forced redeploy, or a recreated stack), it detects the
already-initialized cluster and exits successfully without touching data.
`cockroachdb_data` is a node-local volume, deliberately not NFS. A returning node
uses its persisted store and rejoins with its original node ID.

A permanently removed Swarm node is automatically reaped by the manager-pinned
`decommissioner` service. It only acts after the CockroachDB node is not live, is
still `active`, and its `swarm_node` locality is no longer `Ready` in `docker node ls`
continuously for `GRACE_CHECKS` cycles (one hour by default); at least
`MIN_LIVE_NODES` CockroachDB nodes (three by default) must still be live. It runs on a
manager because it reads `docker node ls`, and mounts the Docker socket, which is
root-equivalent access to that host. Set `COCKROACHDB_AUTO_DECOMMISSION=false` to
turn it off, or raise `COCKROACHDB_DECOMMISSION_GRACE_CHECKS` when a node will be down
longer than the grace period. With automatic decommissioning off, use these fallback
commands against any surviving node's published SQL port 26257:

```sh
cockroach node status --insecure --host=<surviving-node>:26257
cockroach node decommission <dead-node-id> --insecure --host=<surviving-node>:26257
```

Once a node has been decommissioned, if that host later rejoins the Swarm with its old
`cockroachdb_data` volume still present, CockroachDB refuses to start it. Delete that
volume on that host so it joins as a fresh node. This is deliberately not automated:
automatically wiping a database store is not an acceptable default.

`cockroach init` is the exception: it uses the RPC port 26357, which is why the
`init` service targets that port and is not reachable from outside the overlay.

Every Swarm node publishes SQL 26257 and the DB Console 8080 on itself in host
mode, so there is no routing-mesh single endpoint; clients reach any node directly.
The cluster is insecure, so expose these ports only on the trusted network. The
healthcheck remains unhealthy until `init` completes; its `start_period` is therefore
300 seconds.

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
updates. Renovate may propose its version changes, but those changes are not
automatically deployed.

The agent is split by Swarm role: `agent` runs on managers and `agent-worker`
runs on workers. `agent` is the Portainer entry point, so the managers alone
decide the negotiated Docker API version and every node must support that
version. Managers are currently capped at API 1.43, which newer worker engines
still accept, so a worker may run a newer engine without breaking the
environment. Both agent services must always use the same image tag. Collapse
them back into one `agent` service once every node supports the same Docker
API version.

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
production version. Renovate detects newer SemVer image tags and applies the
matching `image:` change in this repository. A merge to `main` is detected by
Portainer polling and rolls out only the changed Swarm service.

## Renovate dependency updates

A self-hosted Renovate runs in the `renovate` stack and scans this repository
every 60 seconds. It replaces both the Mend-hosted Renovate app and Dependabot,
which previously overlapped on the same Docker Compose files.

For Docker Compose, one policy applies to every image, whether it comes
from our own registry or a third party. Minor and patch updates automerge once
`.github/workflows/validate-compose.yaml` has rendered every deployed Compose file
on the pull request. Major updates keep their pull request open for a maintainer,
because a major bump can require a matching configuration change.

The `github-actions` manager also updates action and reusable-workflow references
in `.github/workflows/`. Like Docker Compose, minor and patch updates automerge
after `Validate Workflows` and other applicable checks pass. Major and digest-only
updates open pull requests for manual review and merge.

Automerge happens on a later scan than the one that opened the pull request, since
`platformAutomerge` is off and Renovate merges it itself once the check is green.
At a 60 second interval that costs roughly one extra minute.

`_template` is excluded. Each image update stays an independent change so that
deployment and rollback remain scoped to one service. Minor and patch updates are
CI-gated rather than human-reviewed; if Portainer Agent and Server compatibility
must be checked by a person, add a rule that keeps those two images off automerge.

### Migrating from the Mend app

Only one Renovate may write to this repository, so the Mend-hosted app has to go
before the stack starts writing. Verify first with a throwaway container rather
than by deploying the stack in dry-run mode, so that no Compose change is needed:

```bash
docker run --rm \
  -e RENOVATE_TOKEN="$RENOVATE_TOKEN" \
  -e RENOVATE_PLATFORM=github \
  -e RENOVATE_REPOSITORIES=now-start/gitops \
  -e RENOVATE_AUTODISCOVER=false \
  -e RENOVATE_DRY_RUN=full \
  renovate/renovate:44.93.5
```

Expect `Dependency extraction complete` with a docker-compose file and dependency
count, and no config warnings. Then uninstall the Mend app for this repository and
only afterwards deploy the `renovate` stack. Any pull request left behind by the
app has a different bot author, so set `ignorePrAuthor: true` for one run if those
need to be adopted rather than recreated.

Never run the container without `RENOVATE_DRY_RUN` for a smoke test: with the token
present it will push branches and open pull requests for real.

```text
application main -> test -> image:{version} -> release
                                      |
                                      v
Renovate (60s) -> PR -> Compose validation -> automerge (minor/patch)
                                            -> maintainer  (major)
                                                   |
                                                   v
Portainer polling -> Docker Swarm rolling update
```

Typical end-to-end delay is under ten minutes: the loop sleeps 60 seconds after
each run finishes, so the effective interval is the run time plus 60 seconds; a
minor or patch update needs one scan to open the pull request and a later one to
merge it, and Portainer then polls within five minutes. This is a typical figure
and not an upper bound -- a slow run, a retry, a backlog, a failing check or a
failed run pushes it out.

If deployment fails, revert the GitOps version commit. Swarm's
`failure_action: rollback` can restore runtime tasks, but it does not change the
version recorded in Git. Add a temporary `packageRules` entry for a failed image
version before reverting so Renovate does not immediately propose it again:

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["ghcr.io/now-start/gateway"],
      "allowedVersions": "!/^6\\.1\\.1$/"
    }
  ]
}
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
| `renovate` | `RENOVATE_TOKEN` |

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
