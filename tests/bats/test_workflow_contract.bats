#!/usr/bin/env bats

setup() {
  WORKFLOWS_DIR="$BATS_TEST_DIRNAME/../../.github/workflows"
}

@test "Java prepare delegates version validation to common policy" {
  run grep -F 'uses: ./.github/workflows/reusable-release-prepare.yaml' \
    "$WORKFLOWS_DIR/reusable-java-prepare.yaml"
  [ "$status" -eq 0 ]
}

@test "docker workflow pushes only the immutable version tag" {
  run grep -F 'docker push "$IMAGE_NAME:$VERSION"' \
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

  run grep -F 'BP_OCI_REVISION=$SOURCE_SHA' \
    "$WORKFLOWS_DIR/reusable-java-docker.yaml"
  [ "$status" -eq 0 ]
}

@test "orchestrator has no promotion or rollback workflow dependency" {
  run grep -E 'reusable-(promote|rollback)' \
    "$WORKFLOWS_DIR/reusable-java-app.yaml"
  [ "$status" -ne 0 ]
}

@test "Java publication runs only for a new version tag" {
  run ruby -ryaml -e '
    jobs = YAML.load_file(ARGV[0]).fetch("jobs")
    %w[build docker release].each do |name|
      abort unless jobs.fetch(name).fetch("if") == "needs.prepare.outputs.tag-exists == '\''false'\''"
    end
  ' "$WORKFLOWS_DIR/reusable-java-app.yaml"
  [ "$status" -eq 0 ]
}
