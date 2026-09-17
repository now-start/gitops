#!/usr/bin/env bats
# reusable-java-docker.yaml 의 IMAGE_NAME 도출 로직 테스트

resolve_vars() {
  local MODULE="$1"
  local REGISTRY_ORG="$2"
  local REPO_NAME="test-repo"

  local SERVICE_NAME="${MODULE:-$REPO_NAME}"
  local IMAGE_NAME="$REGISTRY_ORG/$SERVICE_NAME"

  echo "$IMAGE_NAME"
}

# ── SERVICE_NAME / IMAGE_NAME ────────────────────────────────────────────────

@test "module=config → IMAGE_NAME ends with /config" {
  run resolve_vars "config" "ghcr.io/now-start"
  [ "$output" = "ghcr.io/now-start/config" ]
}

@test "module='' (single repo) → IMAGE_NAME uses repo name" {
  run resolve_vars "" "ghcr.io/now-start"
  [ "$output" = "ghcr.io/now-start/test-repo" ]
}

@test "custom registry-org is reflected in IMAGE_NAME" {
  run resolve_vars "svc" "registry.example.com/myorg"
  [ "$output" = "registry.example.com/myorg/svc" ]
}

# ── REGISTRY_HOST 추출 ────────────────────────────────────────────────────────

@test "REGISTRY_HOST extracted from IMAGE_NAME using %%/*" {
  export IMAGE_NAME="ghcr.io/now-start/config"
  run bash -c 'echo "${IMAGE_NAME%%/*}"'
  [ "$output" = "ghcr.io" ]
}
