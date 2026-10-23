# Portainer GitOps 스택과 공통 CI

이 저장소는 Portainer가 동기화하는 Docker Swarm 스택과 Java/Python 애플리케이션의
공통 CI 워크플로우를 관리하는 기준 저장소입니다. 아래에 나열된 스택 디렉터리는
각각 독립적으로 배포됩니다.

## 애플리케이션 공통 CI

애플리케이션은 `now-start/gitops@main`의
`.github/workflows/reusable-java-app.yaml` 또는
`.github/workflows/reusable-python-app.yaml`을 호출합니다.
입력값, 시크릿, 호출 설정은 [공통 워크플로우 안내](docs/shared-workflows.md)와
`examples/`를 참고하세요.

풀 리퀘스트(PR)에서는 애플리케이션 테스트를 실행합니다. `main`에 푸시하면
새 버전 태그에 대해 불변 버전 이미지와 릴리스를 발행합니다. 태그는 있지만
릴리스가 없다면 기존 이미지를 검증한 뒤 재빌드 없이 누락된 릴리스를 복구합니다.
체크아웃 대상과 이미지·릴리스의 소유 저장소는 호출한 애플리케이션 저장소입니다.

`Validate Workflows`는 워크플로우, 테스트, 예제, Renovate 설정이 변경되면
actionlint와 기존 Bats 계약 테스트를 실행합니다. 로컬에서도
`bash tests/run_tests.sh`로 같은 검사를 실행할 수 있습니다
(actionlint, Bats, Ruby, jq 필요).
기존 `now-start/workflow` 저장소는 이관 호환성을 위해 보존하며,
새로 연결하는 애플리케이션은 이 저장소를 사용해야 합니다.

## 저장소 구성

| 스택 | Compose 경로 | 용도 | 의존성 |
| --- | --- | --- | --- |
| `portainer` | `portainer/docker-compose.yml` | Portainer CE 기반 Swarm 관리 | Synology Docker 볼륨 경로, NFS |
| `grafana` | `grafana/docker-compose.yml` | Grafana LGTM 기반 관측·모니터링 | NFS |
| `platform` | `platform/docker-compose.yml` | Config, Eureka, Admin, Gateway | `grafana_default` |
| `chzzk` | `chzzk/docker-compose.yml` | nyang-nyang-bot | `platform_default`, `grafana_default`, NFS |
| `barosteel` | `barosteel/docker-compose.yml` | Barosteel 회원·견적·포인트 서비스; [배포 입력값](barosteel/README.md) | `platform_default`, `grafana_default`, 기존 DB 시크릿 |
| `cockroachdb` | `cockroachdb/docker-compose.yml` | 분산 SQL 클러스터 | 노드별 로컬 디스크(NFS 사용 안 함), 매니저 Docker 소켓 |
| `evergreen` | `evergreen/docker-compose.yml` | 로또·코인 서비스 | `platform_default`, `grafana_default` |
| `bitwarden` | `bitwarden/docker-compose.yml` | Vaultwarden | NFS |
| `flame` | `flame/docker-compose.yml` | Flame 대시보드 | NFS |
| `renovate` | `renovate/docker-compose.yml` | 이미지 태그와 GitHub Actions 의존성을 갱신하는 자체 호스팅 Renovate | 없음 |

## 새 스택 템플릿

`_template/docker-compose.yml`은 어느 서비스에도 복사해 사용할 수 있는 Docker Swarm용
공통 기본형입니다. 종료 유예와 배포 정책은 앵커로 공유하고, 이미지·포트·환경변수·볼륨·
복제 수는 서비스에 맞게 지정합니다. 상태 검사는 검증된 명령이 있을 때만 활성화합니다.
네트워크는 MTU 1200의 overlay, 볼륨은 NFS v4 hard 마운트를 기본으로 제공합니다.
NFS 기본값은 `100.100.1.1:/volume1/docker/app`이며, `app`은 서비스별로 바꿉니다.
시간대와 Spring 상태 검사는 주석 처리한 `TZ`·`THC_PORT`·`THC_PATH` 예제로 제공합니다.
외부 네트워크와 사용자 권한은 서비스에 맞게 지정합니다.
복사·수정·검증 방법과 선택 항목은 [템플릿 안내](_template/README.md)를 참고하세요.

공통 정책은 상태 검사 시작 유예 시간 5분, 업데이트·롤백 감시 시간 5분,
태스크 간 교체 대기 10초, 업데이트 실패 시 자동 롤백, 재시작 조건 `any`를 사용합니다.
상태 검사 명령만 서비스별로 다르게 지정합니다. 이미지에 사용할 수 있는
검사 도구가 없는 스택도 상태 검사 없이 동일한 배포 정책을 사용합니다.

YAML은 Prettier 3.6.2 기본 형식과 LF 줄바꿈을 사용합니다.
여러 서비스에서 반복되는 배포 정책은 파일 상단의 `x-deploy-defaults`에,
반복되는 환경 변수는 `environment-defaults` 앵커에 모읍니다.
서로 다른 스택은 독립 배포되므로 다른 파일의 앵커에 의존하지 않습니다.

```bash
npx --yes prettier@3.6.2 --check '**/*.{yaml,yml}' '.github/**/*.yaml'
```

모든 서비스와 새 스택 템플릿의 종료 유예시간은 `stop_grace_period: 5m`입니다.
이 값은 `deploy`가 아닌 서비스 수준에 선언하며, 모든 스택은
파일별 `x-service-defaults`에서 상속합니다. 정상 종료를 최대 5분
기다린 뒤 강제 종료하며, 프로세스가 먼저 종료되면 즉시 다음 단계로 진행합니다.

대부분의 서비스는 복제 태스크 하나를 실행합니다. `platform` 스택의
`config`, `eureka`, `admin`, `gateway`는 global 모드를 사용하므로,
Swarm이 멀티플랫폼 이미지를 이용해 배치 가능한 모든 노드에 태스크를 하나씩 실행합니다.
`admin`은 Hazelcast로 인스턴스 이벤트를 공유합니다.

Eureka 2.5.0은 공유 오버레이 네트워크의 `tasks.platform_eureka`를 통해 개별 피어를
발견하고 10초마다 복제 대상 피어를 갱신합니다. 배치 가능한 노드를 추가해도
피어 URL을 수정할 필요가 없습니다. 클라이언트는
`http://eureka:8761/eureka/`를 계속 사용하며, 호스트 포트나 노드별 DNS 항목은
필요하지 않습니다. 설정된 태스크 DNS 이름과 일치하도록 스택 이름은
`platform`이어야 합니다. 서비스 탐색 설정은 Compose 환경 변수가 아닌
플랫폼 Config Server의 `config/eureka/eureka.yaml`에서 관리합니다.
이 Compose 변경을 배포하기 전에 플랫폼의 Eureka 2.5.0 이미지와
Config Server 설정을 먼저 발행해야 합니다.

배포 후에는 노드 추가·제거, 태스크 재시작(IP 변경), 공통 클라이언트 URL을 통한
서비스 등록으로 피어 탐색과 레지스트리의 일치 여부를 확인합니다.
각 태스크의 `/eureka/apps`를 직접 조회해 복제를 확인하세요.
Compose 검증만으로는 노드 간 DNS나 복제를 확인할 수 없습니다.
현재 업데이트 정책에는 애플리케이션 준비 상태 검사가 없으므로
업데이트 중 레지스트리에 중단 없이 접근할 수 있다고 보장하지 않습니다.

`evergreen` 스택에서는 `coin`만 `node.hostname == NOW_START`에 고정하고,
`lotto`는 공통 스케줄링 기본값을 유지합니다. 해당 노드를 사용할 수 없거나
drain 상태로 전환하면 `coin`은 다른 노드로 장애 조치할 수 없습니다.
노드의 외부 통신용 공인 IP가 Upbit API 키의 허용 목록에 있는지 확인하세요.
호스트 이름에 따른 배치만으로 고정 IP가 보장되지는 않습니다.

## 상태 검사

상태 검사(healthcheck)는 이미지에 검증된 검사 도구가 있을 때만 활성화합니다.
Vaultwarden과 Grafana는 내장 스크립트, Flame은 Node.js를 사용합니다.
Spring 빌드팩 기본 Tiny 이미지에는 셸이 없으므로 셸 기반 검사를 사용하지 않습니다.
`barosteel`, `platform`의 config/eureka/admin/gateway, `chzzk`의 냥냥봇,
`evergreen`의 lotto는 Paketo health-checker를 포함한 새 이미지로 교체한 뒤 검사합니다.
Lotto는 브라우저 실행에 필요한 Playwright run image를 유지합니다.
Python으로 작성된 `evergreen`의 coin은 Spring 빌드팩 적용 대상이 아닙니다.

검사 포트 8081과 `/actuator/health/readiness` 경로는 각 Spring 서비스의 Compose 환경 변수 `THC_PORT`, `THC_PATH`로 지정합니다.
GitOps는 `/workspace/health-check`를 직접 실행해 검사 때마다 launcher의 JVM 메모리 계산·인증서 초기화가 반복되지 않도록 합니다. Gradle은 health-checker 빌드팩과 `BP_HEALTH_CHECKER_ENABLED=true`만 유지하며, `BPE_DEFAULT_THC_PORT`·`BPE_DEFAULT_THC_PATH` 기본값은 제거합니다.
검사 대상 변경은 배포 환경의 `THC_PORT`, `THC_PATH`에서 관리합니다.
Spring Boot Admin용 Actuator HTTP/JMX 전체 노출 및 접근 허용, probes와 info 항목은 Platform의 공통 설정에서 관리합니다.

프로젝트 패치 버전 변경을 main에 반영하면 CI가 이미지를 발행하고, Renovate가 이 저장소의 이미지 태그를 갱신합니다.
Config Server 공통 설정과 새 이미지가 먼저 반영되고 Renovate의 태그 갱신이 적용된 뒤 배포해야 합니다.
현재 선언된 기존 태그가 이 변경을 포함한다는 뜻이 아니며, 그 전에는 변경된 Compose를 배포하지 마세요.

Admin은 `ADMIN_CLUSTER_BIND_HOST=platform_config.platform_default`로 클러스터 통신용 로컬 주소를 선택하고, `ADMIN_CLUSTER_MEMBERS=tasks.platform_admin.platform_default`로 피어를 탐색합니다. 네트워크 이름을 명시해 두 오버레이 중 다른 주소를 선택하는 것을 방지합니다. 아직 healthy한 admin 태스크가 없어도 먼저 기동할 수 있도록 주소 선택과 피어 DNS를 분리했으며, admin 2.11.15 이상이 필요합니다.

Lotto도 공통 시작 유예 5분을 상속합니다. 직접 검사 방식과 검사 간격 30초·제한 30초·연속 실패 3회, 업데이트·롤백 감시 5분은 유지합니다. 시작 유예 중 계속 실패하면 unhealthy 판정이 업데이트 감시 종료 이후에 발생할 수 있습니다.

## 공통 업데이트·롤백·재시작 정책

상시 서비스와 `_template`은 아래 값을 동일하게 사용한다. 운영 기동 시간을 측정한 최적값이 아닌 공통 시작 기준이다.

| 항목 | 공통값 | 의미 |
| --- | --- | --- |
| healthcheck | 30초 간격 / 30초 제한 / 연속 3회 실패 / 시작 유예 5분 | 검증된 검사 도구가 있는 서비스에 적용 |
| update_config | parallelism 1 / stop-first / failure_action rollback / monitor 5m / delay 10s | 한 개씩 교체, 다음 태스크 교체 전 10초 대기, 실패 시 이전 서비스 설정으로 복귀 |
| rollback_config | parallelism 1 / stop-first / failure_action pause / monitor 5m / delay 10s | 복구도 한 개씩, 다음 태스크 복구 전 10초 대기, 복구 실패 시 진행 중단 |
| restart_policy | condition any / delay 5s | 상시 서비스는 정상 종료·실패 후 다시 실행, 횟수 제한 없음 |

- `stop-first`는 공유 데이터·호스트 포트·단일 실행 작업의 중첩을 방지하는 공통값이다. replica 1개에서는 배포와 롤백 중 중단이 발생한다. `start-first`는 구·신 버전의 동시 실행과 자원 여유, 트래픽 전환을 별도로 검증해야 하므로 공통값으로 쓰지 않는다.
- `delay 10s`는 새 태스크가 healthy가 된 뒤 다음 태스크를 멈추기 전까지 기다리는 시간이다. 태스크가 여러 개인 서비스에서 새 태스크의 Eureka 등록이 Gateway에 전파되기 전에 남은 태스크가 내려가 모든 요청이 실패하는 구간을 막는다. Platform의 Eureka·Gateway 캐시 설정으로 줄인 전파 지연 최대 5초에 Eureka 피어 복제 지연 여유를 더한 값이며, Gateway 재시도 없이 이 구간을 막는 것을 전제로 한다. replica 1개 서비스의 중단 시간에는 영향이 없고, 태스크 수만큼 배포 시간이 늘어난다.
- 시작 유예는 실패 횟수만 유예하며, 그 안에 첫 성공이 발생하면 이후 실패는 집계된다. 검사 완료 후 30초 뒤에 다음 검사를 실행한다. 정상 운영 중 연속 실패 감지는 검사 소요 시간과 장애 발생 시점에 따라 대략 60~180초 걸릴 수 있다. 업데이트·롤백 감시 시간은 5분이며, 시작 유예와 검사 지연이 겹치면 실패 판정이 감시 종료 이후에 발생할 수 있다. `monitor`는 readiness 확인이나 트래픽 전환을 보장하지 않는다.
- 새 버전 태스크가 업데이트 감시 중 실패하면 롤백한다. 감시가 끝난 뒤 발생한 장애는 재시작 정책의 대상이며 항상 자동 롤백되는 것은 아니다. 롤백도 실패하면 롤백 진행이 멈추고 운영자 확인이 필요하다.
- 서비스 설정 롤백은 DB 마이그레이션·볼륨·외부 시스템 변경을 되돌리지 않는다. 데이터 형식이 바뀌는 업그레이드는 이전 이미지와의 호환성을 확인해야 한다.
- 헬스체크가 없는 서비스는 실행 중 응답 불능을 이 설정만으로 감지할 수 없다. CockroachDB는 초기 클러스터 탐색 교착을 피하기 위해 readiness 검사를 Docker healthcheck에 연결하지 않는다.
- CockroachDB `init`은 일회성 작업이므로 성공 후 종료하는 `on-failure`와 재시도 지연 10초를 유지한다. 상시 서비스 공통값의 대상이 아니다.
- 상시 서비스 재시작에 횟수 제한이 없으므로 반복 실패는 별도 모니터링이 필요하다. 재시작만으로 설정 오류가 해결되지는 않는다.

기준: [Docker 배포 설정](https://docs.docker.com/reference/compose-file/deploy/), [Docker HEALTHCHECK](https://docs.docker.com/reference/dockerfile/#healthcheck).

## Portainer GitOps

`barosteel` 정의는 별도로 준비되어 있으며, 첫 배포 전에 검증된 이미지와
암호화된 Config Server 설정이 필요합니다.
[배포 안내](barosteel/README.md)를 참고하세요.

1. `grafana`, `platform`, `chzzk`, `cockroachdb`, `evergreen`,
   `bitwarden`, `flame`을 Git 연동 스택으로 생성합니다.
   `portainer` 스택은 자체 업데이트 실패로 관리 기능까지 중단되지 않도록
   수동으로 관리합니다.
2. 브랜치는 `main`, 스택 이름은 디렉터리 이름, Compose 경로는 위 표의 경로를 사용합니다.
3. 각 `.env.example`의 변수에 해당하는 값을 Portainer 스택 환경 변수에 입력합니다.
   실제 `.env` 파일은 커밋하지 않습니다.
4. 최초 수동 배포를 완료하고 정상 동작을 확인합니다.
5. GitOps 자동 업데이트를 활성화하고 폴링 간격을 5분으로 설정합니다.
   애플리케이션 배포는 불변 이미지 태그 변경으로 수행하므로
   **Re-pull image and redeploy**(이미지 다시 받기 및 재배포)와
   **Force redeployment**(강제 재배포)는 비활성화합니다.

### CockroachDB 클러스터

`cockroachdb` 서비스는 `mode: global`을 사용하므로 Swarm이 배치 가능한
모든 Swarm 노드에 저장 노드를 하나씩 실행합니다.
`endpoint_mode: dnsrr`에서 `--join`은 짧은 서비스 DNS 이름인
`cockroachdb`와 `tasks.cockroachdb`를 사용합니다.
스택 이름이 접두사로 붙은 서비스 이름은 스택 내부 네트워크에서 해석되지 않기 때문입니다.
따라서 저장소를 수정하지 않아도 Swarm 노드를 추가하면 CockroachDB 노드가 추가되고,
노드를 제거하면 CockroachDB가 데이터 범위(range)를 자동으로 다시 복제합니다.
기본 복제 계수 3에 맞춰 최소 3개의 노드가 있다는 전제하에,
두 경우 모두 클러스터 가용성을 유지하기 위한 운영자의 별도 조작이 필요하지 않습니다.

단일 복제본 `init` 서비스는 클러스터를 한 번 초기화한 뒤 `Complete` 상태로 남는
일회성 태스크입니다. Portainer에서는 `0/1`로 표시되지만 정상 상태이며 실패가 아닙니다.
이 작업은 멱등성을 갖습니다. 서비스 명세 변경, 강제 재배포, 스택 재생성으로 Swarm이
태스크를 다시 만들어도 이미 초기화된 클러스터를 감지하면 데이터를 건드리지 않고
성공으로 종료합니다. `cockroachdb_data`는 NFS가 아닌 노드 로컬 볼륨입니다.
다시 합류한 노드는 저장된 데이터를 사용해 기존 노드 ID로 클러스터에 참여합니다.

영구적으로 제거된 Swarm 노드는 매니저에 고정 배치된 `decommissioner` 서비스가
자동으로 퇴역 처리합니다. CockroachDB 노드가 비활성 상태이면서 여전히 `active`이고,
그 노드의 `swarm_node` locality에 해당하는 노드가 `docker node ls`에서
`Ready`가 아닌 상태로 `GRACE_CHECKS`회 연속 확인된 경우에만 작동합니다
(기본 유예 시간 1시간). 이때 최소 `MIN_LIVE_NODES`개의 CockroachDB 노드가
계속 활성 상태여야 합니다(기본값 3).
이 서비스는 `docker node ls`를 읽어야 하므로 매니저에서 실행하며,
호스트의 root 권한에 준하는 접근을 허용하는 Docker 소켓을 마운트합니다.
자동 퇴역 처리를 끄려면 `COCKROACHDB_AUTO_DECOMMISSION=false`로 설정합니다.
예상 중단 시간이 유예 시간보다 길다면 `COCKROACHDB_DECOMMISSION_GRACE_CHECKS`를 늘립니다.
자동 퇴역 처리를 끈 경우, 살아 있는 노드의 공개 SQL 포트 26257에 대해
다음 명령을 수동 대안으로 사용할 수 있습니다.

```sh
cockroach node status --insecure --host=<surviving-node>:26257
cockroach node decommission <dead-node-id> --insecure --host=<surviving-node>:26257
```

퇴역 처리된 노드의 호스트가 기존 `cockroachdb_data` 볼륨을 유지한 채 Swarm에
다시 합류하면 CockroachDB는 시작을 거부합니다. 새 노드로 합류하도록 해당 호스트의
볼륨을 삭제해야 합니다. DB 저장소를 자동으로 지우는 동작은 기본값으로 적절하지
않으므로 이 과정은 자동화하지 않습니다.

`cockroach init`은 예외적으로 RPC 포트 26357을 사용합니다.
따라서 `init` 서비스는 해당 포트로 접속하며 오버레이 외부에서는 접근할 수 없습니다.

각 Swarm 노드는 SQL 26257과 DB Console 8080을 host 모드로 직접 공개합니다.
라우팅 메시의 단일 진입점은 없으며 클라이언트는 각 노드에 직접 접속합니다.
클러스터가 비보안 모드로 동작하므로 이 포트는 신뢰할 수 있는 네트워크에만 공개하세요.
이 서비스는 의도적으로 상태 검사를 사용하지 않습니다. Swarm은 상태 검사를 통과하기
전까지 태스크를 서비스 DNS에 등록하지 않지만, CockroachDB의 준비 상태 검사는
초기화된 클러스터를 요구하므로 초기화 과정이 교착 상태에 빠질 수 있기 때문입니다.

### Compose 경로 이전

이 저장소의 모든 스택과 템플릿은 `docker-compose.yml`을 사용합니다.
Portainer는 Git 연동 스택을 만들 때 지정한 Compose 경로를 저장하므로,
저장소의 파일 이름만 바꿔도 기존 스택의 경로가 자동으로 갱신되지는 않습니다.
이름 변경을 병합하기 전에 기존 Git 연동 스택의 폴링을 모두 일시 중지합니다.
병합 후 각 스택의 Compose 경로를 `STACK/compose.yaml`에서
`STACK/docker-compose.yml`로 바꿉니다.
설치된 Portainer 버전에서 경로 수정을 지원하지 않으면 환경 변수 값을 보관한 뒤
새 경로로 스택을 다시 생성합니다. 각 스택을 수동으로 가져와 재배포하고
안정적으로 동작하는지 확인한 후 폴링을 다시 활성화합니다.

`portainer` Compose 파일은 수동 업데이트 시 적용할, 검토된 목표 상태를 정의합니다.
Renovate가 버전 변경을 제안할 수 있지만 해당 변경이 자동으로 배포되지는 않습니다.

에이전트는 Swarm 역할별로 나뉩니다. `agent`는 매니저에서,
`agent-worker`는 워커에서 실행됩니다.
Portainer의 진입점은 `agent`이므로 Docker API 협상 버전은 매니저만을 기준으로
결정되며, 모든 노드가 해당 버전을 지원해야 합니다.
현재 매니저의 최대 API 버전은 1.43이고 최신 워커 엔진도 이를 지원하므로,
워커가 더 최신 엔진을 사용해도 환경 연결이 깨지지 않습니다.
두 에이전트 서비스는 항상 같은 이미지 태그를 사용해야 합니다.
모든 노드가 같은 Docker API 버전을 지원하면 하나의 `agent` 서비스로 통합합니다.

가변 태그(`latest`, `lts`)를 명시적 버전으로 처음 전환할 때는
영향받는 Portainer 스택의 자동 업데이트를 일시 중지합니다.
두 태그가 현재 같은 이미지 다이제스트를 가리켜도 이미지 문자열이 바뀌면
Swarm 태스크가 교체됩니다. 기준 버전 변경을 병합한 뒤 아래 의존 순서에 따라
스택을 하나씩 재배포·검증하고 폴링을 다시 활성화합니다.

애플리케이션 스택은 앞선 두 스택이 만든 네트워크를 사용하므로 다음 순서로 배포합니다.

1. `portainer`, `grafana`
2. `platform`
3. `chzzk`, `evergreen`
4. `bitwarden`, `flame`

### `spring`에서 `platform`으로 이전

Portainer 스택 이름은 Swarm 서비스와 기본 네트워크 이름을 결정하므로,
이름 변경은 기존 스택을 그대로 갱신하는 작업이 아닙니다.
이름 변경을 병합하기 전에 `spring`, `chzzk`, `evergreen`의 GitOps 폴링을
비활성화하고 Portainer 환경 변수 값을 보관합니다. 병합 후에는 다음 순서로 진행합니다.

1. `chzzk`, `evergreen` 스택을 제거해 `spring_default` 사용을 해제합니다.
2. 기존 `spring` 스택을 제거합니다.
3. `platform/docker-compose.yml`로 `platform` 스택을 만들고 검증합니다.
4. `chzzk`, `evergreen`을 다시 만듭니다. 이제 `platform_default`에 연결됩니다.
5. 세 스택이 모두 안정적으로 동작하면 폴링을 다시 활성화합니다.

이전 중에는 의존 애플리케이션이 중단됩니다. 실패하면 이름 변경 커밋을 되돌리고
기존 의존 순서에 따라 스택을 다시 만듭니다.

스택 설정은 Git만을 기준으로 관리합니다. Portainer에서 직접 수정한 내용은
다음 Git 가져오기에서 덮어써지므로, 구조와 버전 변경은 이 저장소의 PR로 반영합니다.

## 이미지 버전 관리 책임

이미지 이름과 배포 태그는 Git으로 추적하는 각 `docker-compose.yml`에 직접 선언합니다.
이를 Portainer의 로컬 환경 변수로 옮기면 GitOps 검토에서 실행 버전을 확인할 수
없으므로 옮기지 않습니다.

애플리케이션 파이프라인은 불변 태그를 빌드·푸시하지만 운영 배포 버전을 선택하지는 않습니다.
Renovate가 더 최신 SemVer 이미지 태그를 감지하고 이 저장소의 해당 `image:`를 변경합니다.
변경이 `main`에 병합되면 Portainer가 폴링으로 감지해 변경된 Swarm 서비스만
순차적으로 업데이트합니다.

## Renovate 의존성 업데이트

`renovate` 스택에서 자체 호스팅 Renovate를 실행해 이 저장소를 주기적으로 검사합니다.
한 번의 실행이 끝나면 60초를 기다린 뒤 다음 검사를 시작합니다.
기존에 같은 Docker Compose 파일을 중복 관리하던 Mend 호스팅 Renovate 앱과
Dependabot을 대체합니다.

Docker Compose의 모든 이미지에는 자체 레지스트리 여부와 관계없이 같은 정책을 적용합니다.
마이너·패치 업데이트는 PR에서 `.github/workflows/validate-compose.yaml`이
모든 배포 대상 Compose 파일을 렌더링해 검증하면 자동으로 병합됩니다.
메이저 업데이트는 설정 변경이 함께 필요할 수 있으므로 담당자가 검토할 때까지 PR을 열어 둡니다.

`github-actions` 관리자는 `.github/workflows/`의 액션과 재사용 워크플로우 참조도
갱신합니다. Docker Compose와 마찬가지로 마이너·패치 업데이트는
`Validate Workflows`와 해당 변경에 필요한 검사를 통과하면 자동 병합됩니다.
메이저 업데이트와 다이제스트만 바뀌는 업데이트는 수동 검토·병합용 PR을 만듭니다.

`platformAutomerge`가 꺼져 있으므로 검사 통과 후 Renovate가 직접 병합합니다.
따라서 자동 병합은 PR을 만든 검사 회차가 아닌 다음 검사 회차에서 이루어지며,
60초 대기 간격으로 인해 대략 1분이 추가됩니다.

`_template`은 검사에서 제외합니다. 배포와 롤백 범위를 서비스 하나로 한정할 수 있도록
이미지 업데이트는 각각 독립적인 변경으로 유지합니다.
마이너·패치 업데이트의 병합 조건은 사람의 검토가 아닌 CI 통과입니다.
Portainer Agent와 Server의 호환성을 사람이 확인해야 한다면
해당 두 이미지를 자동 병합에서 제외하는 규칙을 추가하세요.

### Mend 앱에서 이전

이 저장소에 변경을 기록하는 Renovate는 하나만 있어야 하므로,
스택이 변경을 기록하기 전에 Mend 호스팅 앱을 제거해야 합니다.
Compose를 수정하지 않고 먼저 검증할 수 있도록 스택을 시험 실행 모드로 배포하는 대신
다음과 같이 일회성 컨테이너를 사용합니다.

```bash
docker run --rm \
  -e RENOVATE_TOKEN="$RENOVATE_TOKEN" \
  -e RENOVATE_PLATFORM=github \
  -e RENOVATE_REPOSITORIES=now-start/gitops \
  -e RENOVATE_AUTODISCOVER=false \
  -e RENOVATE_DRY_RUN=full \
  renovate/renovate:44.93.5
```

`Dependency extraction complete` 로그에 docker-compose 파일 수와 의존성 수가 표시되고,
설정 경고가 없는지 확인합니다. 그다음 이 저장소에 연결된 Mend 앱을 제거하고,
이후에 `renovate` 스택을 배포합니다.
앱이 남긴 PR은 작성 봇이 다르므로, 새로 만들지 않고 기존 PR을 이어서 관리하려면
한 번의 실행에 한해 `ignorePrAuthor: true`를 설정합니다.

간단한 동작 확인을 위해 실행할 때도 `RENOVATE_DRY_RUN`을 생략하지 마세요.
토큰이 있으면 실제로 브랜치를 푸시하고 PR을 생성합니다.

```text
애플리케이션 main → 테스트 → 이미지:{version} → 릴리스
                                  ↓
Renovate 검사 → PR → Compose 검증 → 자동 병합(마이너·패치)
                                → 담당자 검토·병합(메이저)
                                  ↓
Portainer 폴링 → Docker Swarm 순차 업데이트
```

전체 반영 시간은 일반적으로 10분 이내입니다. 반복 실행 루프는 매 실행이 끝난 뒤
60초를 기다리므로 실제 검사 간격은 실행 시간에 60초를 더한 값입니다.
마이너·패치 업데이트는 한 번의 검사로 PR을 만들고 이후 검사에서 병합하며,
그다음 Portainer가 5분 이내에 폴링합니다.
이는 일반적인 예상치일 뿐 최대 소요 시간을 보장하지 않습니다.
실행 지연, 재시도, 처리 대기, 검사 실패나 실행 실패가 있으면 더 오래 걸립니다.

배포에 실패하면 GitOps의 버전 변경 커밋을 되돌립니다.
Swarm의 `failure_action: rollback`은 실행 중인 태스크를 복구할 수 있지만,
Git에 기록된 버전까지 바꾸지는 않습니다.
Renovate가 같은 버전을 즉시 다시 제안하지 않도록 커밋을 되돌리기 전에
실패한 이미지 버전을 제외하는 임시 `packageRules` 항목을 추가합니다.

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["ghcr.io/now-start/gateway"],
      "allowedVersions": "!/^6\\.1\\.1$/"
    }
  ]
}
```

## Portainer 필수 환경 변수

다음 변수의 실제 값은 커밋하지 않습니다.

| 스택 | 필수 변수 |
| --- | --- |
| `bitwarden` | `BITWARDEN_SSO_CLIENT_SECRET` |
| `grafana` | `GRAFANA_OAUTH_CLIENT_SECRET`, `GRAFANA_SMTP_PASSWORD` |
| `platform` | `SPRING_ENCRYPT_KEY` |
| `flame` | `FLAME_PASSWORD` |
| `renovate` | `RENOVATE_TOKEN` |

`.env.example` 템플릿에는 시크릿 변수 이름만 기록합니다.
실제 `.env` 파일에는 시크릿만 담고 Git 추적에서 제외하며, 값은 Portainer에서 관리합니다.
이미지, 포트, 도메인, 네트워크·저장소 경로 등 민감하지 않은 설정은
Git으로 추적하는 Compose 파일에 둡니다.
자격 증명을 과거에 커밋했거나 평문으로 공유했다면 배포 전에 교체하세요.

## Swarm 사전 준비 사항

- 선택한 Portainer 환경은 Swarm 매니저여야 합니다.
- 모든 Swarm 노드는 Portainer Agent용 Docker 볼륨을 `/volume1/@docker/volumes`에 노출해야 합니다.
- Portainer 기본 오버레이는 VXLAN 트래픽을 Tailscale에 맞추기 위해 MTU `1200`을 사용합니다.
- 모든 스택 소유 오버레이 네트워크는 MTU `1200`을 사용합니다. 변경된 스택을 재배포하기 전에 기존 네트워크를 다시 생성하세요.
- 포트를 공개하는 서비스를 배포하기 전에 Swarm `ingress` 네트워크를 MTU `1200`으로 다시 생성합니다.
- `platform`, `chzzk`, `evergreen`을 배포하기 전에 `grafana_default`가 존재해야 합니다.
- `chzzk`, `evergreen`을 배포하기 전에 `platform_default`가 존재해야 합니다.
- 배치 가능한 모든 노드는 `NOW_START`의 Tailscale 주소 `100.100.1.1`에서 NFSv4를 마운트할 수 있어야 합니다.
- DSM NFS 권한은 Tailscale 클라이언트 대역 `100.64.0.0/10`을 허용해야 합니다.
- 비공개 이미지를 사용하려면 매니저에서 `ghcr.io` 인증을 완료해야 합니다.
- 공개 포트 `1080`, `3000`, `5005`, `6379`, `8000`, `9443`을 사용할 수 있어야 합니다.

Tailscale 기반 Swarm을 새로 초기화했다면, 포트를 공개하는 서비스를 배포하기 전에
라우팅 메시 네트워크를 같은 MTU로 다시 생성합니다.

```sh
docker network rm ingress
docker network create --driver overlay --ingress \
  --opt com.docker.network.driver.mtu=1200 ingress
```

## 로컬 검증

운영용이 아닌 임시 값으로 환경 변수 치환을 검증합니다.

```sh
BITWARDEN_SSO_CLIENT_ID=test BITWARDEN_SSO_CLIENT_SECRET=test \
  docker stack config -c bitwarden/docker-compose.yml >/dev/null

FLAME_PASSWORD=test docker stack config -c flame/docker-compose.yml >/dev/null

GRAFANA_OAUTH_CLIENT_ID=test GRAFANA_OAUTH_CLIENT_SECRET=test \
GRAFANA_SMTP_USER=test GRAFANA_SMTP_PASSWORD=test \
  docker stack config -c grafana/docker-compose.yml >/dev/null

SPRING_ENCRYPT_KEY=test docker stack config -c platform/docker-compose.yml >/dev/null

docker stack config -c chzzk/docker-compose.yml >/dev/null

docker stack config -c evergreen/docker-compose.yml >/dev/null

docker stack config -c portainer/docker-compose.yml >/dev/null
```

배포 후 실제 스케줄러와 네트워크 상태를 확인합니다.

```sh
docker stack services STACK_NAME
docker stack ps --no-trunc STACK_NAME
docker network inspect grafana_default
docker network inspect platform_default
docker service ps --no-trunc portainer_agent
```

문법 검증만으로는 NFS 가용성, 레지스트리 인증, 서비스 준비 상태,
노드 간 오버레이 연결을 확인할 수 없습니다.

## 후속 작업: DEV·STG·PRD 환경 분리

환경 분리는 추후 진행하며, 현재는 환경별 배포·승인·승격 workflow를 추가하지
않습니다. 공통 CI는 테스트·버전 이미지 발행·GitHub Release 생성을 유지하고,
실제 배포는 Renovate의 이미지 변경 PR과 Portainer GitOps 업데이트로 수행합니다.
아래 항목은 아직 구현되지 않은 후속 작업입니다.

- [ ] GitOps의 애플리케이션 Compose를 DEV·STG·PRD별로 분리합니다.
  예: `platform/dev/docker-compose.yml`, `platform/stg/docker-compose.yml`,
  `platform/prd/docker-compose.yml`. 환경별 프로필, Secret 참조, 네트워크,
  볼륨, 외부 포트와 배포 대상을 정하고 공용 인프라의 분리 범위도 확인합니다.
- [ ] Renovate의 전체 Compose minor·patch 자동 병합 정책을 환경별로 조정합니다.
  애플리케이션 DEV는 새 이미지 업데이트 PR을 받고, STG·PRD는 독립적인 최신
  버전 업데이트를 비활성화하여 검증된 이미지의 승격 PR로만 변경합니다.
  공용 인프라 및 GitHub Actions 의존성 정책은 별도로 관리합니다.
- [ ] Portainer에 환경별 스택을 구성하고 각 Git 브랜치·Compose 경로·배포 대상을
  연결합니다. 예: `platform-dev`, `platform-stg`, `platform-prd`가 `main`의
  각 환경 경로를 참조합니다. 설치된 Portainer의 기능과 polling 설정을 확인합니다.
- [ ] DEV 배포 후 검증한 이미지 참조만 STG로, STG 검증 후 PRD로 복사하는
  승격 PR 절차를 마련합니다. 이미지를 재빌드하거나 환경별로 재태깅하지 않고,
  같은 산출물임을 보장하도록 이미지 digest 고정도 적용합니다.
- [ ] PRD 변경 PR에 필수 리뷰·필수 검사를 강제하는 저장소 보호 규칙을 설정합니다.
  승인 후 병합된 Compose 변경을 Portainer가 배포하도록 합니다.
- [ ] Compose 검증에 모든 환경 경로를 포함하고, 실제 배포 후 상태 확인 및
  smoke test 기준을 마련합니다. CI의 Compose 검사 통과만으로 배포 성공을
  판단하지 않습니다.
- [ ] 초기에는 수동 승격 PR로 운영하고, 필요해지면 배포 검증 결과를 확인해 다음
  환경의 이미지 참조만 변경하는 승격 workflow를 추가합니다. Renovate 설정만으로
  DEV → STG → PRD 검증 순서가 보장되지는 않습니다.
- [ ] 환경별 이전 이미지 참조로 되돌리는 롤백 절차와 실패 버전 재제안 방지 정책을
  확인합니다.

예정된 흐름:

```text
CI 이미지 발행 → Renovate DEV PR → 병합 → Portainer DEV 배포·검증
  → STG 승격 PR → 병합 → Portainer STG 배포·검증
  → PRD 승격 PR → 승인·병합 → Portainer PRD 배포·검증
```
