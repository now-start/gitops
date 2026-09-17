#!/usr/bin/env bats

setup() {
  WORKFLOW="$BATS_TEST_DIRNAME/../../.github/workflows/reusable-java-docker.yaml"
  export PATH="$BATS_TEST_DIRNAME/../fixtures/multiarch:$PATH"
  export MOCK_LOG="$BATS_TEST_TMPDIR/docker.log" MOCK_CREATED="$BATS_TEST_TMPDIR/created"
  export REGISTRY_ORG=ghcr.io/example REPO_NAME=app MODULE='' VERSION=1.2.3
  export SOURCE_SHA=0123456789abcdef TAG_EXISTS=false REGISTRY_USER=bot REGISTRY_PASSWORD=test
  export IMAGE_NAME=ghcr.io/example/app ARCH=arm64 SOURCE_URL=https://github.com/example/app
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  cd "$BATS_TEST_TMPDIR"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > gradle-call\n' > gradlew
  chmod +x gradlew
}

run_step() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["steps"].find { |s| s["name"] == ARGV[2] }["run"]' \
    "$WORKFLOW" "$1" "$2" > "$BATS_TEST_TMPDIR/step.sh"
  run bash -e -o pipefail "$BATS_TEST_TMPDIR/step.sh"
}

publish() { run_step publish 'Publish and verify multi-platform image'; }
build() { run_step docker 'Build and push architecture image'; }

@test "publish combines verified digest-pinned architectures then verifies final index" {
  publish
  [ "$status" -eq 0 ]
  grep -F 'create --tag ghcr.io/example/app:1.2.3 ghcr.io/example/app@sha256:amd64 ghcr.io/example/app@sha256:arm64' "$MOCK_LOG"
  [ -f "$MOCK_CREATED" ]
}

@test "existing multiarch tag is reused without publishing" {
  export FINAL_EXISTS=true
  publish
  [ "$status" -eq 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "existing single-architecture tag is rejected without overwrite" {
  export FINAL_EXISTS=true SINGLE_ARCH=true
  publish
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "existing index without arm64 is rejected" {
  export FINAL_EXISTS=true INDEX_ARCH=amd64
  publish
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "existing final tag from another source commit is rejected" {
  export FINAL_EXISTS=true REMOTE_SHA=another-commit
  publish
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "architecture source with wrong revision cannot be published" {
  export REMOTE_SHA=another-commit
  publish
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "missing ARM image prevents partial final publication" {
  export MISSING_ARCH=arm64
  publish
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "registry authentication failure is not treated as missing image" {
  export API_ERROR=true
  publish
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "existing Git tag with missing final image blocks publication" {
  export TAG_EXISTS=true
  publish
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_CREATED" ]
}

@test "ARM build explicitly requests ARM and pushes only staging tag" {
  build
  [ "$status" -eq 0 ]
  grep -F -- '--imagePlatform=linux/arm64' gradle-call
  grep -F 'push ghcr.io/example/app:build-0123456789abcdef-arm64' "$MOCK_LOG"
  ! grep -F 'push ghcr.io/example/app:1.2.3' "$MOCK_LOG"
}

@test "wrong local architecture is rejected before push" {
  export LOCAL_ARCH=amd64
  build
  [ "$status" -ne 0 ]
  ! grep -q '^push ' "$MOCK_LOG"
}

@test "retry reuses matching architecture image without rebuilding" {
  export STAGE_EXISTS=true
  build
  [ "$status" -eq 0 ]
  [ ! -f gradle-call ]
}
