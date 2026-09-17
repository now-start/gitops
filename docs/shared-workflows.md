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
                    -> existing version: skip

gitops repository
  Renovate PR   -> compose image version update -> merge

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
- 이미 Git 태그가 있는 버전은 main에 새 커밋이 push되어도 검사, 이미지 확인·빌드,
  Release 단계를 모두 건너뜁니다. 새 이미지를 발행하려면 프로젝트 버전을 올려야 합니다.
- 이미지 발행 후 Git 태그 생성 전에 실패하면 같은 이미지를 재사용하여 재시도합니다.
  Git 태그가 생성된 뒤 Release 생성이 실패한 경우에는 수동 복구가 필요합니다.

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
    -> 기존 버전이면 종료
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
Git 태그 생성 뒤 Release만 누락된 경우에는 수동으로 복구해야 합니다.
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

이미 Git 태그가 존재하는 모듈은 검사와 Docker 단계를 건너뛰므로, 한 모듈의
버전만 올라간 main push에서는 해당 모듈만 검사하고 이미지를 발행합니다.
이미지 발행 후 tag 생성 전에 실패한 경우에는 OCI revision이 같은 기존 이미지를
재사용합니다. tag 생성 뒤 release만 누락된 경우에는 수동으로 복구해야 합니다.

## 입력과 Secret

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `registry-org` | `ghcr.io/now-start` | 이미지 registry와 namespace |
| `module` | 빈 값 | Gradle 모듈 및 이미지 이름 |
| `registry-password` | 필수 | 이미지 push에 사용할 token |

## 실행 과정

```text
pull_request / non-main push / workflow_dispatch
  -> reusable-java-test.yaml

main push
  -> reusable-java-prepare.yaml
       Gradle/Java metadata 추출 -> 공통 버전·Git 태그·Release 확인
  -> 기존 버전이면 종료
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

새 이미지가 발행되면 `gitops` 저장소의 Renovate이 Compose 이미지
버전을 올리는 PR을 만듭니다. PR이 병합되면 Portainer polling이 변경을
배포합니다.

```diff
- image: ghcr.io/now-start/gateway:6.1.0
+ image: ghcr.io/now-start/gateway:6.1.1
```

배포 실패 시에는 `gitops`의 버전 변경 커밋을 revert합니다. 실패한 버전을
Renovate이 다시 제안하지 않게 하려면 해당 이미지와 버전을
`renovate.json`의 해당 이미지 `packageRules.allowedVersions`에서 제외합니다.

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
