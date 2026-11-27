#!/usr/bin/env bats

setup() {
  WORKFLOWS_DIR="$BATS_TEST_DIRNAME/../../.github/workflows"
}

@test "Java prepare delegates version validation to common policy" {
  run grep -F 'uses: ./.github/workflows/reusable-release-prepare.yaml' \
    "$WORKFLOWS_DIR/reusable-java-prepare.yaml"
  [ "$status" -eq 0 ]
}

@test "docker workflow publishes a versioned manifest without mutable aliases" {
  run grep -F 'docker buildx imagetools create --tag "$FINAL_IMAGE"' \
    "$WORKFLOWS_DIR/reusable-java-docker.yaml"
  [ "$status" -eq 0 ]

  run grep -E 'docker push .*:(latest|dev)' \
    "$WORKFLOWS_DIR/reusable-java-docker.yaml"
  [ "$status" -ne 0 ]
}

@test "docker workflow recognizes common missing-manifest responses" {
  run grep -F "manifest unknown|no such manifest|manifest.*not found" \
    "$WORKFLOWS_DIR/reusable-java-docker.yaml"
  [ "$status" -eq 0 ]
}

@test "docker workflow verifies source revision before reusing an image" {
  run grep -F 'org.opencontainers.image.revision' \
    "$WORKFLOWS_DIR/reusable-java-docker.yaml"
  [ "$status" -eq 0 ]

  run grep -F "'BP_OCI_REVISION': System.getenv('SOURCE_SHA')" \
    "$WORKFLOWS_DIR/reusable-java-docker.yaml"
  [ "$status" -eq 0 ]
}

@test "orchestrator has no promotion or rollback workflow dependency" {
  run grep -E 'reusable-(promote|rollback)' \
    "$WORKFLOWS_DIR/reusable-java-app.yaml"
  [ "$status" -ne 0 ]
}

@test "Java build runs only for a new version tag" {
  run ruby -ryaml -e '
    jobs = YAML.load_file(ARGV[0]).fetch("jobs")
    %w[build].each do |name|
      abort unless jobs.fetch(name).fetch("if") == "needs.prepare.outputs.tag-exists == '\''false'\''"
    end
  ' "$WORKFLOWS_DIR/reusable-java-app.yaml"
  [ "$status" -eq 0 ]
}

@test "tagged Java versions run a separate coverage build only for enabled callers" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV[0])
    coverage_input = workflow.fetch("on", workflow[true]).fetch("workflow_call").fetch("inputs").fetch("shared-coverage")
    abort unless coverage_input.fetch("type") == "boolean" && coverage_input.fetch("default") == false
    jobs = workflow.fetch("jobs")
    coverage = jobs.fetch("coverage-existing-version")
    tagged = jobs.fetch("build").fetch("if").sub("false", "true")
    abort unless coverage.fetch("if") == "inputs.shared-coverage && #{tagged}"
    abort unless coverage.fetch("needs") == "prepare"
    abort unless coverage.fetch("uses") == jobs.fetch("build").fetch("uses")
    abort unless coverage.fetch("with").fetch("shared-coverage") == true
    abort unless jobs.fetch("coverage-badge").fetch("needs") == %w[build coverage-existing-version]
  ' "$WORKFLOWS_DIR/reusable-java-app.yaml"
  [ "$status" -eq 0 ]
}
