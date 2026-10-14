#!/usr/bin/env bats

setup() {
  WORKFLOWS_DIR="$BATS_TEST_DIRNAME/../../.github/workflows"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" INPUT_JAVA_VERSION='' MODULE=''
  cd "$BATS_TEST_TMPDIR"
}

run_detector() {
  local script
  script=$(ruby -ryaml -e '
    jobs = YAML.load_file(ARGV[0])["jobs"]
    puts jobs.values.flat_map { |j| j.fetch("steps", []) }.find { |s| s["name"] == "Detect Java version" }["run"]
  ' "$WORKFLOWS_DIR/reusable-java-$1.yaml")
  run bash -e -o pipefail -c "$script"
}

@test "actual Java detectors support toolchain compatibility constants and legacy Java 8" {
  for workflow in prepare test; do
    for fixture in 'JavaLanguageVersion.of(21)|21' 'sourceCompatibility = "17"|17' 'targetCompatibility = "1.8"|8' 'sourceCompatibility = JavaVersion.VERSION_1_8|8' 'sourceCompatibility = JavaVersion.VERSION_21|21'; do
      printf '%s\n' "${fixture%|*}" > build.gradle
      : > "$GITHUB_OUTPUT"
      run_detector "$workflow"
      [ "$status" -eq 0 ]
      grep -qx "version=${fixture##*|}" "$GITHUB_OUTPUT"
    done
  done
}

@test "explicit Java version supports projects with no literal Gradle toolchain" {
  export INPUT_JAVA_VERSION=21
  for workflow in prepare test; do
    run_detector "$workflow"
    [ "$status" -eq 0 ]
    grep -qx 'version=21' "$GITHUB_OUTPUT"
  done
}

@test "module Java configuration wins and empty module falls back to root" {
  export MODULE=config
  mkdir config
  printf 'JavaLanguageVersion.of(17)\n' > build.gradle
  for workflow in prepare test; do
    printf 'JavaLanguageVersion.of(21)\n' > config/build.gradle.kts
    : > "$GITHUB_OUTPUT"
    run_detector "$workflow"
    [ "$status" -eq 0 ]
    grep -qx 'version=21' "$GITHUB_OUTPUT"
    printf 'version = "1.0.0"\n' > config/build.gradle.kts
    : > "$GITHUB_OUTPUT"
    run_detector "$workflow"
    [ "$status" -eq 0 ]
    grep -qx 'version=17' "$GITHUB_OUTPUT"
  done
}

@test "missing Java version fails with an actionable error" {
  for workflow in prepare test; do
    run_detector "$workflow"
    [ "$status" -eq 1 ]
    [[ "$output" == *'provide the java-version input'* ]]
    [ ! -s "$GITHUB_OUTPUT" ]
  done
}

@test "Gradle failure after printing a version stops metadata without pipefail" {
  printf '#!/usr/bin/env bash\necho "version: 1.2.3"\nexit 42\n' > gradlew
  local script
  script=$(ruby -ryaml -e '
    puts YAML.load_file(ARGV[0])["jobs"]["metadata"]["steps"].find { |s| s["name"] == "Extract version from build.gradle" }["run"]
  ' "$WORKFLOWS_DIR/reusable-java-prepare.yaml")
  run bash -e -c "$script"
  [ "$status" -eq 42 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}


@test "Java orchestrator forwards an explicit JDK to prepare and PR tests" {
  run ruby -ryaml -e '
    app = YAML.load_file(ARGV[0])["jobs"]
    %w[prepare test-only].each { |name| abort unless app[name]["with"]["java-version"] == "${{ inputs.java-version }}" }
  ' "$WORKFLOWS_DIR/reusable-java-app.yaml"
  [ "$status" -eq 0 ]
}

@test "toolchain takes priority over compatibility in actual YAML scripts" {
  printf "sourceCompatibility = 11\nJavaLanguageVersion.of(17)\n" > build.gradle
  for workflow in prepare test; do
    : > "$GITHUB_OUTPUT"
    run_detector "$workflow"
    [ "$status" -eq 0 ]
    grep -qx 'version=17' "$GITHUB_OUTPUT"
  done
}
