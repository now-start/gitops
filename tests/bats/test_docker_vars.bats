#!/usr/bin/env bats
# reusable-java-docker.yaml 의 IMAGE_NAME 도출 로직 테스트

@test "build and publish use the selected registry and fall back from module to repository name" {
  run ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("env").fetch("IMAGE_NAME")' \
    "$BATS_TEST_DIRNAME/../../.github/workflows/reusable-java-docker.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ inputs.registry-org }}/${{ inputs.module || github.event.repository.name }}' ]
}

# ── REGISTRY_HOST 추출 ────────────────────────────────────────────────────────

@test "REGISTRY_HOST extracted from IMAGE_NAME using %%/*" {
  export IMAGE_NAME="ghcr.io/now-start/config"
  run bash -c 'echo "${IMAGE_NAME%%/*}"'
  [ "$output" = "ghcr.io" ]
}
