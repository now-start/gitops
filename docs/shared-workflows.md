# Shared application workflows

Java/Spring Boot 및 Python/uv 애플리케이션의 공통 CI workflow입니다. 애플리케이션
저장소는 테스트와 이미지 발행까지만 담당하고, 운영에 배포할 버전은
[`now-start/gitops`](https://github.com/now-start/gitops)에서 관리합니다.

## 책임 경계

```text
application repository
  PR / develop / manual -> test
  main push       -> version check
                    -> new version: test -> ghcr.io/...:{version} -> GitHub Release
                    -> existing tag + release: skip
                    -> existing tag only: verify image -> recover release

gitops repository
  Renovate PR     -> compose image version update -> merge

Portainer
  main polling    -> Docker Swarm stack reconciliation
```

- 이 저장소는 불변 SemVer 이미지와 GitHub Release를 생성합니다.
- `latest`와 `dev` 같은 가변 포인터 태그는 발행하지 않습니다.
- 운영 승격과 롤백은 이미지 재태깅이 아니라 GitOps Compose 버전 변경으로
  수행합니다.
- Swarm의 `failure_action: rollback`은 배포 도중의 런타임 안전장치이며,
  Git에 기록된 목표 버전은 별도로 되돌려야 합니다.

## 공통 릴리스 정책

Java와 Python은 동일한 버전 검증·태그 확인·릴리스 발행 workflow를 사용합니다.

| 프로젝트 버전 | GitHub Release | Docker 태그 |
| --- | --- | --- |
| `2.0.0-alpha.1` / `beta.1` / `rc.1` | Prerelease, Latest 제외 | 전체 버전 문자열 |
| `2.0.0` | 정식 Release, Latest는 GitHub 자동 판정 | `2.0.0` |

- `main` push에서 새 버전 태그가 없을 때만 검증 후 이미지를 발행합니다. PR, `main` 이외 브랜치 push,
  수동 실행은 언어별 검사만 수행합니다. 호출 저장소에 해당 이벤트 트리거가 있어야 합니다.
- `latest` Docker 태그와 GitHub의 Latest Release 표시는 별개입니다.
  정식 버전도 Docker `latest` 태그는 만들지 않습니다.
- 선행 0, `SNAPSHOT`, `+build`, PEP 440 축약형은 발행 버전으로 허용하지 않습니다.
  `0.0.0`은 유효한 정식 버전이며 Java에서도 더 이상 자동 건너뛰지 않습니다.
- 이미 Git 태그와 Release가 있는 버전은 main에 새 커밋이 push되어도 검사·발행을 건너뜁니다.
  태그만 있고 Release가 없으면 기존 이미지를 검증하여 Release만 복구합니다. 새 이미지를 발행하려면 프로젝트 버전을 올려야 합니다.
- 이미지 발행 후 Git 태그 생성 전에 실패하면 같은 이미지를 재사용하여 재시도합니다.
  Git 태그가 생성된 뒤 Release 생성이 실패하면 재실행에서 기존 이미지를 검증한 뒤 Release만 복구합니다.

```text
Java prepare   -> Gradle metadata ─┐
                                  ├-> reusable-release-prepare.yaml
Python prepare -> TOML metadata ───┘      (버전·Git 태그·Release 상태)

Java/Python test -> 언어별 Docker build/reuse -> reusable-release.yaml
                                                (Git 태그·Release 생성)
```

기존 `reusable-java-release.yaml`과 `reusable-python-release.yaml` 호출 인터페이스는
공통 발행 workflow로 전달하는 얇은 래퍼로 유지합니다.

## 단일 저장소

```yaml
name: App CI/CD

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]
  workflow_dispatch:

permissions:
  contents: write
  packages: write

jobs:
  app:
    uses: now-start/gitops/.github/workflows/reusable-java-app.yaml@main
    secrets:
      registry-password: ${{ secrets.GITHUB_TOKEN }}
```

Gradle version이 `5.9.8`이면 다음 산출물을 생성합니다.

```text
Git tag:       5.9.8
Docker image:  ghcr.io/now-start/{repository}:5.9.8
```

## Java 멀티 아키텍처 이미지

Java 이미지는 `ubuntu-24.04`(AMD64), `ubuntu-24.04-arm`(ARM64) 러너에서
각각 `bootBuildImage --imagePlatform`으로 빌드합니다. 프로젝트의 builder/run image는
두 아키텍처를 지원해야 합니다. Gradle에 지정한 run image는 유지합니다.

- 중간 이미지: `build-{source-sha}-amd64`, `build-{source-sha}-arm64`
- 배포 이미지: `{version}` (두 아키텍처를 포함한 manifest index)
- 두 빌드 성공 후 각 이미지의 실제 플랫폼과 OCI revision을 검증하고 digest로 묶습니다.
- 기존 버전 태그는 덮어쓰지 않습니다. 두 아키텍처와 소스 커밋이 모두 맞을 때만 재사용합니다.
- 기존 AMD64 전용 태그를 전환하려면 애플리케이션 버전을 올려 새 이미지를 발행합니다.
- ARM64 지원 태그가 레지스트리에 발행된 것을 확인한 뒤 Swarm의 x86_64 전용 배치 제약을 제거합니다.

## Python/uv

`examples/build-python.yaml`처럼 `reusable-python-app.yaml@main`을 호출합니다.
애플리케이션에는 `pyproject.toml`, `uv.lock`, `.python-version`, `Dockerfile`이
있어야 하며 dev 의존성에 Ruff, mypy, pytest, pip-audit를 포함합니다.

- PR, `develop` push, 수동 실행: locked uv 설치, 포맷/lint/타입/테스트/취약점 검사
- `main` push: 새 버전일 때만 같은 검사 후 amd64/arm64 버전 이미지와 GitHub Release 발행
- `uv-version` 입력 기본값: `0.11.3`
- `registry-password` Secret: 호출 저장소의 `GITHUB_TOKEN`

Java와 동일하게 `app`은 단계 연결만 담당하고, 실제 작업은 역할별 workflow로
분리합니다. 애플리케이션 저장소의 호출 방식은 바뀌지 않습니다.

```text
reusable-python-app.yaml
  PR / develop push / 수동 실행 -> reusable-python-test.yaml
  main push
    -> reusable-python-prepare.yaml  (메타데이터 추출·공통 정책 호출)
    -> 태그와 Release가 있으면 종료
    -> 태그만 있으면 기존 이미지 검증 후 Release 복구
    -> 새 버전이면 reusable-python-test.yaml     (uv 기반 검증)
                   -> reusable-python-docker.yaml   (불변 이미지 확인·빌드·발행)
                   -> reusable-python-release.yaml  (공통 발행 호출)
```

버전은 `pyproject.toml`의 `project.version`을 그대로 읽습니다.
`2.0.0` 또는 `2.0.0-alpha.1`/`2.0.0-beta.1`/`2.0.0-rc.1` 형태를 허용하며,
Python 내부의 PEP 440 정규화 값(`2.0.0a1`)으로 이미지 태그를 바꾸지 않습니다.
알파/베타/RC는 GitHub prerelease로 생성하고 latest release로 지정하지 않습니다.

```text
pyproject.toml: 2.0.0-alpha.1
Git tag:       2.0.0-alpha.1
Docker image:  ghcr.io/now-start/{repository}:2.0.0-alpha.1
```

기존 Git 태그와 이미지 revision을 확인하여 발행된 버전을 덮어쓰지 않습니다.
이미지가 발행된 후 Git 태그 생성 전에 실패했다면 같은 revision의 이미지를 재사용합니다.
Git 태그 생성 뒤 Release만 누락된 경우에는 재실행에서 기존 이미지를 검증한 뒤 Release만 복구합니다.
이미 Release가 있는 버전은 새 이미지를 발행하지 않으므로 다음 발행에는 버전을 올립니다.
Java도 같은 stable/alpha/beta/RC 정책을 사용합니다.

## Gradle 모노레포

모듈마다 같은 reusable workflow를 호출합니다.

```yaml
jobs:
  config:
    uses: now-start/gitops/.github/workflows/reusable-java-app.yaml@main
    with:
      module: config
    secrets:
      registry-password: ${{ secrets.GITHUB_TOKEN }}

  gateway:
    uses: now-start/gitops/.github/workflows/reusable-java-app.yaml@main
    with:
      module: gateway
    secrets:
      registry-password: ${{ secrets.GITHUB_TOKEN }}
```

`config` 모듈의 Gradle version이 `2.1.14`이면 다음 산출물을 생성합니다.

```text
Git tag:       config-2.1.14
Docker image:  ghcr.io/now-start/config:2.1.14
```

이미 Git 태그와 Release가 존재하는 모듈은 검사와 Docker 단계를 건너뛰므로, 한 모듈의
버전만 올라간 main push에서는 해당 모듈만 검사하고 이미지를 발행합니다.
이미지 발행 후 tag 생성 전에 실패한 경우에는 OCI revision이 같은 기존 이미지를
재사용합니다. tag 생성 뒤 release만 누락된 경우에는 재실행에서 기존 이미지를 검증한 뒤 Release만 복구합니다.

## 입력과 Secret

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `registry-org` | `ghcr.io/now-start` | 이미지 registry와 namespace |
| `module` | 빈 값 | Gradle 모듈 및 이미지 이름 |
| `java-version` | 빈 값 | 명시적 JDK 버전, 생략 시 Gradle 파일에서 감지 |
| `registry-password` | 필수 | 이미지 push에 사용할 token |

## 실행 과정

```text
pull_request / non-main push / workflow_dispatch
  -> reusable-java-test.yaml

main push
  -> reusable-java-prepare.yaml
       Gradle/Java metadata 추출 -> 공통 버전·Git 태그·Release 확인
  -> 태그와 Release가 있으면 종료
    -> 태그만 있으면 기존 이미지 검증 후 Release 복구
  -> 새 버전이면 reusable-java-test.yaml
               -> reusable-java-docker.yaml
                    ghcr.io/...:{version} build and push
               -> reusable-java-release.yaml
                    공통 발행: {version} 또는 {module}-{version} tag/release 생성
```

기존 애플리케이션 workflow에 남아 있는 `release` 트리거는 호환을 위해
당장 제거하지 않아도 되지만, 이 orchestrator에서는 아무 작업도 실행하지
않습니다. 각 애플리케이션을 수정할 기회가 있을 때 정리할 수 있습니다.

## GitOps 승격과 롤백

새 이미지가 발행되면 `gitops` 저장소의 Renovate가 Compose 이미지
버전을 올리는 PR을 만듭니다. PR이 병합되면 Portainer polling이 변경을
배포합니다.

```diff
- image: ghcr.io/now-start/gateway:6.1.0
+ image: ghcr.io/now-start/gateway:6.1.1
```

배포 실패 시에는 `gitops`의 버전 변경 커밋을 revert합니다. 실패한 버전을
Renovate가 다시 제안하지 않게 하려면 `renovate.json`에서 해당
이미지에 대한 `packageRules.allowedVersions`로 실패한 버전을 제외합니다.

## 버전 고정

외부 저장소에서 reusable workflow를 호출할 때 `@main`은 최신 변경을 즉시
따릅니다. 동작을 안정화한 뒤에는 release tag 또는 전체 commit SHA로
고정하는 것을 권장합니다.

## 검증

```sh
tests/run_tests.sh
```

이 명령은 reusable workflow를 actionlint로 검사하고 셸 로직을 Bats로
검증합니다.

## 재실행과 Java 버전 지정

- 정상 발행 완료(태그와 Release 존재): 기존처럼 검사·이미지 발행·Release 생성을 생략합니다.
- 이미지 발행 후 태그 생성 전 실패: 동일 source SHA의 이미지를 검증하여 재사용합니다.
- 태그 생성 후 Release 생성 실패: main 실행을 다시 실행하면 빌드는 생략하고 태그가 가리키는 이미지의 revision을 검증한 뒤 Release만 생성합니다. Java와 Python 모두 amd64/arm64 이미지도 각각 검증합니다.
- 복구 중 이미지 누락 또는 revision 불일치: 실패 처리하며 기존 버전 이미지를 새로 만들거나 덮어쓰지 않습니다.
- Python 기존 이미지 재사용은 index annotation뿐 아니라 amd64/arm64 실행 이미지 각각의 revision을 검증합니다. SBOM/provenance descriptor는 실행 아키텍처와 구분합니다.
- `reusable-java-app.yaml`의 선택 입력 `java-version`으로 JDK를 지정할 수 있습니다. convention plugin이나 변수로 버전을 관리하는 경우 사용하세요. 생략하면 기존 Gradle 파일 자동 감지를 사용합니다.
- Java prepare는 최대 15분, test는 최대 30분, 아키텍처별 Docker 빌드는 최대 45분, manifest 발행은 최대 10분 실행합니다.


## 사용자 시나리오

| 사용자 작업 또는 상태 | workflow 동작 | 사용자 후속 조치 |
| --- | --- | --- |
| PR 생성·갱신 / main 이외 push | 언어별 검사만 실행, 이미지·Release 발행 안 함 | 검사 실패를 수정 |
| workflow_dispatch 실행 | 검사만 실행 | 발행 복구는 해당 main push 실행을 재실행 |
| main에 새 stable 버전 push | 검사 → 이미지 발행 → 정식 Release | 성공 결과 확인 |
| main에 alpha/beta/rc 버전 push | 검사 → 해당 버전 이미지 → prerelease | 버전 표기 규칙 준수 |
| 동일 버전의 태그·Release가 이미 존재 | 후속 검사·발행 생략 | 새 코드를 발행하려면 버전 증가 |
| 이미지 push 후 태그 생성 전 실패 | 같은 커밋이면 기존 이미지 재사용 후 발행 재시도 | 같은 main push 실행 재실행 |
| 태그 생성 후 Release 생성 실패 | 빌드 생략 → 기존 이미지 검증 → Release만 복구 | 같은 main push 실행 재실행 |
| 복구 대상 이미지 누락 또는 다른 revision | 실패, 기존 버전 재빌드·덮어쓰기 안 함 | 원인 확인 후 복구 또는 새 버전 발행 |
| 기존 Python 이미지에 ARM64 누락 / 하위 이미지 SHA 불일치 | 재사용과 Release 발행 차단 | 올바른 멀티아키텍처 이미지로 문제 해결 |
| Java 버전이 convention plugin에만 있음 | java-version 입력으로 JDK 지정 가능 | 호출 with.java-version 설정 |
| Gradle properties가 버전 출력 후 실패 | prepare 실패, 발행 중단 | Gradle 오류 수정 |
| build 실패 또는 실행 취소 | Docker·Release 후속 발행 차단 | 실패 원인 해결 후 재실행 |

워크플로우 파일 수정이 호출 저장소에 적용되기 전 실행을 재실행하면 이전 workflow 정의가 사용될 수 있습니다.
변경된 공통 workflow가 적용된 main push 실행을 기준으로 복구를 수행하세요.
