#!/usr/bin/env bats

setup() {
  WORKFLOWS_DIR="$BATS_TEST_DIRNAME/../../.github/workflows"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  export GITHUB_SHA="1111111111111111111111111111111111111111"
  export GITHUB_REPOSITORY="Now-Start/Example"
  export GITHUB_API_URL="https://api.example.invalid"
  export GH_TOKEN="fake-test-token"
  export VERSION="2.0.0-alpha.1" PRERELEASE=true IMAGE=ghcr.io/now-start/example
  export TAG_NAME="$VERSION" TAG_PREFIX=''
  export TEST_TAG_SHA="" TEST_IMAGE_STATUS=1 TEST_RELEASE_STATUS=404
  export TEST_IMAGE_OUTPUT="manifest unknown"
  export TEST_RELEASE_JSON='{"draft":false,"prerelease":true}'
  cd "$BATS_TEST_TMPDIR"
}

step_script() {
  ruby -ryaml -e '
    steps = Dir[File.join(ARGV[0], "reusable-*.yaml")].flat_map do |path|
      YAML.load_file(path).fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }
    end
    puts steps.find { |step| step["name"] == ARGV[1] }.fetch("run")
  ' "$WORKFLOWS_DIR" "$1"
}

run_version() {
  printf '[project]\nversion = "%s"\n' "$1" > pyproject.toml
  local script
  script="$(step_script 'Read project metadata')" || return 1
  script+=$'\nVERSION=$(sed -n "s/^version=//p" "$GITHUB_OUTPUT" | tail -1)\n'
  script+="$(step_script 'Validate release version')" || return 1
  run bash -e -o pipefail -c "$script"
}

# Stubs exercise the actual workflow shell without contacting GitHub or GHCR.
install_stubs() {
  git() {
    if [ "$1" = ls-remote ]; then
      if [ -n "$TEST_TAG_SHA" ]; then
        printf '%s\trefs/tags/%s\n' "$TEST_TAG_SHA" "$TAG_NAME"
        if [ -n "${TEST_PEELED_SHA:-}" ]; then
          printf '%s\trefs/tags/%s^{}\n' "$TEST_PEELED_SHA" "$TAG_NAME"
        fi
      fi
    else
      printf 'git %s\n' "$*" >> "$RUNNER_TEMP/calls"
    fi
  }
  curl() {
    printf '%s' "$TEST_RELEASE_JSON" > "$RUNNER_TEMP/release-state.json"
    printf '%s' "$TEST_RELEASE_STATUS"
    [ "$TEST_RELEASE_STATUS" -lt 400 ] || return 22
  }
  docker() {
    printf '%s' "$TEST_IMAGE_OUTPUT"
    return "$TEST_IMAGE_STATUS"
  }
  gh() { printf 'gh %s\n' "$*" >> "$RUNNER_TEMP/calls"; }
  export -f git curl docker gh
}

run_state() {
  install_stubs
  local script
  script="$(step_script 'Check release state')"$'\n'
  script+='SOURCE_SHA=$(sed -n "s/^source-sha=//p" "$GITHUB_OUTPUT")'$'\n'
  script+='TAG_EXISTS=$(sed -n "s/^tag-exists=//p" "$GITHUB_OUTPUT")'$'\n'
  script+="$(step_script 'Check immutable image')"
  run bash -e -o pipefail -c "$script"
}

@test "Python app only orchestrates main publication and non-main checks" {
  run ruby -ryaml -e '
    jobs = YAML.load_file(ARGV[0]).fetch("jobs")
    abort unless jobs.keys == %w[test-only prepare build docker release]
    jobs.each_value do |job|
      abort if job.key?("steps") || job.key?("runs-on")
      abort unless File.file?(File.join(ARGV[1], job.fetch("uses")))
    end
    abort unless jobs["test-only"]["if"] == "github.event_name == '\''pull_request'\'' || github.event_name == '\''workflow_dispatch'\'' || (github.event_name == '\''push'\'' && github.ref != '\''refs/heads/main'\'')"
    abort unless jobs["prepare"]["if"] == "github.event_name == '\''push'\'' && github.ref == '\''refs/heads/main'\''"
    abort unless jobs["build"]["needs"] == "prepare"
    abort unless jobs["docker"]["needs"] == %w[prepare build]
    abort unless jobs["release"]["needs"] == %w[prepare docker]
    %w[build docker release].each do |name|
      abort unless jobs[name]["if"] == "needs.prepare.outputs.tag-exists == '\''false'\''"
    end
  ' "$WORKFLOWS_DIR/reusable-python-app.yaml" "$WORKFLOWS_DIR/../.."
  [ "$status" -eq 0 ]
}

@test "Python prepare outputs connect to Docker and release inputs" {
  run ruby -ryaml -e '
    path = ARGV[0]
    app = YAML.load_file("#{path}/reusable-python-app.yaml")
    prepare = YAML.load_file("#{path}/reusable-python-prepare.yaml")
    outputs = prepare.fetch("on", prepare[true]).fetch("workflow_call").fetch("outputs")
    %w[docker release].each do |name|
      job = app.fetch("jobs").fetch(name)
      workflow = YAML.load_file("#{path}/reusable-python-#{name}.yaml")
      inputs = workflow.fetch("on", workflow[true]).fetch("workflow_call").fetch("inputs")
      abort unless job.fetch("with").keys.sort == inputs.keys.sort
      job.fetch("with").each do |key, value|
        abort unless value == "${{ needs.prepare.outputs.#{key} }}" && outputs.key?(key)
      end
    end
    abort unless app.fetch("concurrency")["cancel-in-progress"] == false
    abort unless app.fetch("jobs")["docker"]["permissions"] == {"contents" => "read", "packages" => "write"}
    abort unless app.fetch("jobs")["release"]["permissions"] == {"contents" => "write"}
  ' "$WORKFLOWS_DIR"
  [ "$status" -eq 0 ]
}

@test "Python release preserves SemVer alpha tag and lowercases image name" {
  run_version '2.0.0-alpha.1'
  [ "$status" -eq 0 ]
  grep -qx 'version=2.0.0-alpha.1' "$GITHUB_OUTPUT"
  grep -qx 'prerelease=true' "$GITHUB_OUTPUT"
  grep -qx 'image=ghcr.io/now-start/example' "$GITHUB_OUTPUT"
}

@test "Python release accepts stable beta and RC versions" {
  for version in 2.0.0 2.0.0-beta.1 2.0.0-rc.1; do
    run_version "$version"
    [ "$status" -eq 0 ]
  done
  grep -qx 'prerelease=false' "$GITHUB_OUTPUT"
}

@test "Python release rejects non-SemVer and unsafe image tags" {
  for version in 2.0.0a1 02.0.0 2.0.0-alpha.01 latest 2.0.0+build 2.0.0-bogus.1; do
    run_version "$version"
    [ "$status" -ne 0 ]
  done
}

@test "new version is ready to build without an existing tag or image" {
  run_state
  [ "$status" -eq 0 ]
  grep -qx 'image-exists=false' "$GITHUB_OUTPUT"
  grep -qx 'release-exists=false' "$GITHUB_OUTPUT"
  grep -qx "source-sha=$GITHUB_SHA" "$GITHUB_OUTPUT"
}

@test "same revision image can resume interrupted release creation" {
  export TEST_IMAGE_STATUS=0
  export TEST_IMAGE_OUTPUT="{\"annotations\":{\"org.opencontainers.image.revision\":\"$GITHUB_SHA\"}}"
  run_state
  [ "$status" -eq 0 ]
  grep -qx 'image-exists=true' "$GITHUB_OUTPUT"
  grep -qx 'release-exists=false' "$GITHUB_OUTPUT"
}

@test "Buildx exact image not-found response allows first publication" {
  export TEST_IMAGE_OUTPUT="ERROR: $IMAGE:$VERSION: not found"
  run_state
  [ "$status" -eq 0 ]
  grep -qx 'image-exists=false' "$GITHUB_OUTPUT"
}

@test "unrelated not-found errors still stop publication" {
  for message in 'docker: command not found' 'ERROR: credential helper not found' 'ERROR: ghcr.io/other/image:2.0.0: not found'; do
    export TEST_IMAGE_OUTPUT="$message"
    run_state
    [ "$status" -ne 0 ]
  done
}

@test "existing version cannot overwrite another revision image" {
  export TEST_IMAGE_STATUS=0
  export TEST_IMAGE_OUTPUT='{"annotations":{"org.opencontainers.image.revision":"other"}}'
  run_state
  [ "$status" -ne 0 ]
}

@test "registry authentication errors are not mistaken for missing images" {
  export TEST_IMAGE_OUTPUT='unauthorized: authentication required'
  run_state
  [ "$status" -ne 0 ]
}

@test "tagged image missing fails rather than rebuilding under an old tag" {
  export TEST_TAG_SHA="$GITHUB_SHA"
  run_state
  [ "$status" -ne 0 ]
}

@test "existing prerelease reuses its tagged image even after later commits" {
  export TEST_RELEASE_STATUS=200 TEST_IMAGE_STATUS=0
  export TEST_TAG_SHA=2222222222222222222222222222222222222222
  export TEST_IMAGE_OUTPUT="{\"annotations\":{\"org.opencontainers.image.revision\":\"$TEST_TAG_SHA\"}}"
  run_state
  [ "$status" -eq 0 ]
  grep -qx 'release-exists=true' "$GITHUB_OUTPUT"
  grep -qx "source-sha=$TEST_TAG_SHA" "$GITHUB_OUTPUT"
}

@test "draft and wrongly classified releases fail validation" {
  export TEST_RELEASE_STATUS=200 TEST_TAG_SHA="$GITHUB_SHA"
  for json in '{"draft":true,"prerelease":true}' '{"draft":false,"prerelease":false}'; do
    export TEST_RELEASE_JSON="$json"
    run_state
    [ "$status" -ne 0 ]
  done
}

@test "GitHub API errors stop publication" {
  export TEST_RELEASE_STATUS=403
  run_state
  [ "$status" -ne 0 ]
}

@test "alpha release is marked prerelease and never latest" {
  install_stubs
  export SOURCE_SHA="$GITHUB_SHA"
  run bash -e -o pipefail -c "$(step_script 'Create version tag and release')"
  [ "$status" -eq 0 ]
  grep -q 'git tag 2.0.0-alpha.1' "$RUNNER_TEMP/calls"
  grep -q -- '--prerelease --latest=false' "$RUNNER_TEMP/calls"
}

@test "changed tag is rejected before release creation" {
  install_stubs
  export SOURCE_SHA="$GITHUB_SHA" TEST_TAG_SHA=3333333333333333333333333333333333333333
  run bash -e -o pipefail -c "$(step_script 'Create version tag and release')"
  [ "$status" -ne 0 ]
  [ ! -e "$RUNNER_TEMP/calls" ]
}

@test "stable release uses normal release flags and preserves module tag" {
  install_stubs
  export SOURCE_SHA="$GITHUB_SHA" TAG_NAME=config-2.0.0 PRERELEASE=false
  run bash -e -o pipefail -c "$(step_script 'Create version tag and release')"
  [ "$status" -eq 0 ]
  grep -q 'gh release create config-2.0.0 --verify-tag' "$RUNNER_TEMP/calls"
  ! grep -q -- '--prerelease\|--latest=false' "$RUNNER_TEMP/calls"
}

@test "existing matching release is idempotent without writes" {
  install_stubs
  export SOURCE_SHA="$GITHUB_SHA" TEST_TAG_SHA="$GITHUB_SHA" TEST_RELEASE_STATUS=200
  run bash -e -o pipefail -c "$(step_script 'Create version tag and release')"
  [ "$status" -eq 0 ]
  [ ! -e "$RUNNER_TEMP/calls" ]
}

@test "release errors and incorrect classification fail before writes" {
  install_stubs
  export SOURCE_SHA="$GITHUB_SHA" TEST_TAG_SHA="$GITHUB_SHA" TEST_RELEASE_STATUS=403
  run bash -e -o pipefail -c "$(step_script 'Create version tag and release')"
  [ "$status" -ne 0 ]
  export TEST_RELEASE_STATUS=200
  for json in '{"draft":true,"prerelease":true}' '{"draft":false,"prerelease":false}' 'invalid json'; do
    export TEST_RELEASE_JSON="$json"
    run bash -e -o pipefail -c "$(step_script 'Create version tag and release')"
    [ "$status" -ne 0 ]
  done
  [ ! -e "$RUNNER_TEMP/calls" ]
}

@test "release without matching Git tag fails in prepare and publication" {
  install_stubs
  export SOURCE_SHA="$GITHUB_SHA" TEST_RELEASE_STATUS=200
  for step in 'Check release state' 'Create version tag and release'; do
    run bash -e -o pipefail -c "$(step_script "$step")"
    [ "$status" -ne 0 ]
  done
  [ ! -e "$RUNNER_TEMP/calls" ]
}

@test "annotated module tags resolve to commit in prepare and publication" {
  install_stubs
  export TAG_NAME=config-2.0.0-alpha.1 SOURCE_SHA="$GITHUB_SHA"
  export TEST_TAG_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa TEST_PEELED_SHA="$GITHUB_SHA"
  export TEST_RELEASE_STATUS=200
  for step in 'Check release state' 'Create version tag and release'; do
    run bash -e -o pipefail -c "$(step_script "$step")"
    [ "$status" -eq 0 ]
  done
  grep -qx "source-sha=$GITHUB_SHA" "$GITHUB_OUTPUT"
  [ ! -e "$RUNNER_TEMP/calls" ]
}
