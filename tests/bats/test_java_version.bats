#!/usr/bin/env bats
# reusable-java-prepare.yaml 의 Java 버전 자동 감지 로직 테스트

setup() {
  FIXTURES_DIR="$BATS_TEST_TMPDIR/build-gradle"
  mkdir -p "$FIXTURES_DIR"
}

detect_java_version() {
  local BUILD_FILE="$1"
  local VERSION

  VERSION=$(grep -Eo "JavaLanguageVersion.of\([0-9]+\)" "$BUILD_FILE" | head -1 | sed -E 's/[^0-9]//g')
  VERSION=${VERSION:-$(grep -Eo "(source|target)Compatibility[[:space:]]*=[[:space:]]*['\"]?[0-9]+['\"]?" "$BUILD_FILE" | head -1 | sed -E 's/[^0-9]//g')}
  VERSION=${VERSION:-$(grep -Eo "JavaVersion\.VERSION_[0-9]+" "$BUILD_FILE" | head -1 | sed -E 's/[^0-9]//g')}

  echo "$VERSION"
}

@test "detects JavaLanguageVersion.of(17)" {
  echo 'java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }' \
    > "$FIXTURES_DIR/toolchain.gradle"
  run detect_java_version "$FIXTURES_DIR/toolchain.gradle"
  [ "$output" = "17" ]
}

@test "detects JavaLanguageVersion.of(21)" {
  echo 'java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }' \
    > "$FIXTURES_DIR/toolchain21.gradle"
  run detect_java_version "$FIXTURES_DIR/toolchain21.gradle"
  [ "$output" = "21" ]
}

@test "detects sourceCompatibility = '11'" {
  echo "sourceCompatibility = '11'" \
    > "$FIXTURES_DIR/compat_source.gradle"
  run detect_java_version "$FIXTURES_DIR/compat_source.gradle"
  [ "$output" = "11" ]
}

@test "detects targetCompatibility = \"17\"" {
  echo 'targetCompatibility = "17"' \
    > "$FIXTURES_DIR/compat_target.gradle"
  run detect_java_version "$FIXTURES_DIR/compat_target.gradle"
  [ "$output" = "17" ]
}

@test "detects JavaVersion.VERSION_21" {
  echo "sourceCompatibility = JavaVersion.VERSION_21" \
    > "$FIXTURES_DIR/javaversion.gradle"
  run detect_java_version "$FIXTURES_DIR/javaversion.gradle"
  [ "$output" = "21" ]
}

@test "JavaLanguageVersion takes precedence over sourceCompatibility" {
  printf 'sourceCompatibility = "11"\njava { toolchain { languageVersion = JavaLanguageVersion.of(17) } }\n' \
    > "$FIXTURES_DIR/precedence.gradle"
  run detect_java_version "$FIXTURES_DIR/precedence.gradle"
  [ "$output" = "17" ]
}

@test "returns empty when no Java version found" {
  echo 'version = "1.0.0"' > "$FIXTURES_DIR/no_java.gradle"
  run detect_java_version "$FIXTURES_DIR/no_java.gradle"
  [ "$output" = "" ]
}
