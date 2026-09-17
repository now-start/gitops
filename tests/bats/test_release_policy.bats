#!/usr/bin/env bats

setup() {
  WORKFLOWS_DIR="$BATS_TEST_DIRNAME/../../.github/workflows"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  export VERSION=2.0.0-alpha.1 TAG_PREFIX=''
  cd "$BATS_TEST_TMPDIR"
}

policy_script() {
  ruby -ryaml -e '
    puts YAML.load_file(ARGV[0]).fetch("jobs").fetch("prepare").fetch("steps")
      .find { |step| step["name"] == "Validate release version" }.fetch("run")
  ' "$WORKFLOWS_DIR/reusable-release-prepare.yaml"
}

@test "shared policy accepts stable alpha beta RC and zero versions" {
  for version in 0.0.0 1.2.3 2.0.0-alpha.1 2.0.0-beta.2 2.0.0-rc.1; do
    : > "$GITHUB_OUTPUT"
    export VERSION="$version"
    run bash -e -o pipefail -c "$(policy_script)"
    [ "$status" -eq 0 ]
    grep -qx "version=$version" "$GITHUB_OUTPUT"
    grep -qx "tag-name=$version" "$GITHUB_OUTPUT"
    if [[ "$version" == *-* ]]; then
      grep -qx 'prerelease=true' "$GITHUB_OUTPUT"
    else
      grep -qx 'prerelease=false' "$GITHUB_OUTPUT"
    fi
  done
}

@test "Java metadata preserves prerelease spelling and module Gradle task" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$RUNNER_TEMP/gradle-task"\nprintf "version: %%s\\n" "$FIXTURE_VERSION"\n' > gradlew
  export RUNNER_TEMP="$BATS_TEST_TMPDIR" MODULE=config TAG_PREFIX=config
  local metadata script
  metadata="$(ruby -ryaml -e '
    puts YAML.load_file(ARGV[0]).fetch("jobs").fetch("metadata").fetch("steps")
      .find { |step| step["name"] == "Extract version from build.gradle" }.fetch("run")
  ' "$WORKFLOWS_DIR/reusable-java-prepare.yaml")"
  script="$metadata"$'\nVERSION=$(sed -n "s/^version=//p" "$GITHUB_OUTPUT" | tail -1)\n'
  script+="$(policy_script)"
  for version in 0.0.0 2.0.0 2.0.0-alpha.1 2.0.0-beta.1 2.0.0-rc.1; do
    export FIXTURE_VERSION="$version"
    run bash -e -o pipefail -c "$script"
    [ "$status" -eq 0 ]
    grep -qx "tag-name=config-$version" "$GITHUB_OUTPUT"
    grep -qx ':config:properties -q --no-daemon' "$RUNNER_TEMP/gradle-task"
  done
  export FIXTURE_VERSION=2.0.0-SNAPSHOT
  run bash -e -o pipefail -c "$script"
  [ "$status" -ne 0 ]
}

@test "shared policy rejects noncanonical versions and unsupported suffixes" {
  for version in 01.2.3 1.02.3 1.2.03 2.0.0-alpha.01 2.0.0a1 2.0.0-SNAPSHOT 2.0.0+build latest; do
    export VERSION="$version"
    run bash -e -o pipefail -c "$(policy_script)"
    [ "$status" -ne 0 ]
  done
}

@test "shared policy preserves module prefix without changing image version" {
  export TAG_PREFIX=config-service
  run bash -e -o pipefail -c "$(policy_script)"
  [ "$status" -eq 0 ]
  grep -qx 'tag-name=config-service-2.0.0-alpha.1' "$GITHUB_OUTPUT"
  grep -qx 'version=2.0.0-alpha.1' "$GITHUB_OUTPUT"
  grep -qx 'prerelease=true' "$GITHUB_OUTPUT"
}

@test "shared policy rejects unsafe tag prefixes" {
  for prefix in '../other' '-bad' 'foo bar' 'foo*'; do
    export TAG_PREFIX="$prefix"
    run bash -e -o pipefail -c "$(policy_script)"
    [ "$status" -ne 0 ]
  done
}

@test "Java and Python route version policy and release through shared workflows" {
  run ruby -ryaml -e '
    %w[java python].each do |language|
      prepare = YAML.load_file("#{ARGV[0]}/reusable-#{language}-prepare.yaml")
      abort unless prepare.fetch("jobs").fetch("policy")["uses"] == "./.github/workflows/reusable-release-prepare.yaml"
      release = YAML.load_file("#{ARGV[0]}/reusable-#{language}-release.yaml")
      abort unless release.fetch("jobs").fetch("release")["uses"] == "./.github/workflows/reusable-release.yaml"
    end
  ' "$WORKFLOWS_DIR"
  [ "$status" -eq 0 ]
}

@test "Java and Python orchestrators use the same event and dependency rules" {
  run ruby -ryaml -e '
    java = YAML.load_file("#{ARGV[0]}/reusable-java-app.yaml").fetch("jobs")
    python = YAML.load_file("#{ARGV[0]}/reusable-python-app.yaml").fetch("jobs")
    abort unless java.keys == python.keys
    java.each do |name, job|
      %w[if needs permissions].each { |field| abort unless job[field] == python[name][field] }
    end
  ' "$WORKFLOWS_DIR"
  [ "$status" -eq 0 ]
}
