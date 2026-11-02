# 공통 overlay 이전

## 변경 범위

`platform`이 MTU 1200의 `platform_default` overlay를 생성한다. 고정 IPAM subnet은 지정하지 않는다.
`grafana`, `barosteel`, `chzzk`, `evergreen`은 이 네트워크를 외부 기본 네트워크로 사용한다.
Portainer·CockroachDB 등 다른 스택은 이번 통합 대상이 아니다.

Admin·Gateway·Barosteel은 CIDR 필터와 `hazelcast.local.localAddress` 강제 지정을 제거하고
Hazelcast TCP/IP 기본 주소 선택을 사용한다. 멤버 DNS는 각각 `tasks.platform_admin`,
`tasks.platform_gateway`, `tasks.barosteel_barosteel`이다. 클러스터 이름·포트 자동 증가 비활성화·
세션·캐시·백업·종료 정책은 유지한다.

Eureka는 `tasks.platform_eureka`의 IPv4 응답과 로컬 IP의 교집합이 한 개일 때 자기 주소로 선택한다.
초기 탐색은 최대 10회, 시도 사이 1초 대기한다. DNS 조회 시간은 별도다.
실제 Swarm에서는 healthy 이전 task가 DNS에 나타나지 않으므로, 실패하면 Docker 자체 hostname의
IPv4와 로컬 IP가 유일하게 일치하는 주소로 부트스트랩한다. loopback·모호한 주소는 거부한다.
Eureka는 공통 overlay 하나에만 연결해야 하며, healthy 이후 task DNS로 피어를 갱신한다.
기동 후 DNS 실패·빈 응답·자기 주소 누락에는 이전 피어를 유지하고, 정상 응답이 자기 주소만 포함하면
마지막 피어도 제거한다. 피어 갱신과 등록 URL 보정은 유지한다.

## 준비와 적용 순서

1. `platform`과 `barosteel`의 앱 변경을 검증하고 새 버전의 이미지를 발행한다.
   이번 전환 이미지는 Admin 2.11.25, Gateway 6.2.5, Eureka 2.5.8, Barosteel 0.2.13이며 Config는 2.1.25를 유지한다.
2. 대상 스택의 GitOps 자동 동기화를 잠시 중단하고 기존 Compose·이미지 digest·중앙 설정 revision·
   네트워크 subnet/MTU와 연결 서비스를 기록한다. Config Server는 Git의 중앙 설정을 읽으므로
   중앙 설정 공개와 앱 전환도 같은 작업 창에서 조율한다.
3. 기존 앱이 실행 중인 상태에서 CIDR 설정만 먼저 제거하거나 Compose만 먼저 반영하지 않는다.
   특히 기존 Barosteel은 자체 overlay 대역을 요구한다. 이번 전환은 서비스 중단을 포함한 작업으로 계획한다.
4. 실제 연결 서비스를 확인한 뒤 대상 소비 스택과 플랫폼을 중단한다. 고정 대역을 없애려면
   모든 연결이 해제된 기존 `platform_default`를 제거하고 플랫폼 스택으로 새로 생성한다.
   Compose의 IPAM 항목 삭제만으로 기존 네트워크 subnet이 바뀌지는 않는다.
5. 새 앱 이미지와 중앙 설정을 사용해 `platform`을 먼저 배포하고 Config·Eureka가 정상 기동하는지 확인한다.
   이후 `grafana`, `barosteel`, `chzzk`, `evergreen`을 배포한다.
6. 아래 검증 후 사용하지 않는 이전 `grafana_default`·`barosteel_default`의 연결이 없는지 확인하고 정리한다.
   모든 대상이 안정화된 후 자동 동기화를 재개한다.

## 검증

- 각 Compose에 `docker stack config -c <경로>`를 실행하고 `git diff --check`를 통과한다.
- 서비스별 네트워크 연결이 `platform_default`인지, 생성된 네트워크 MTU가 1200인지 확인한다.
- Config 접근과 Grafana OTLP 데이터 수신, Gateway의 서비스 라우팅을 확인한다.
- Hazelcast의 서비스별 replica가 동일한 클러스터에 합류하고 다른 서비스와 섞이지 않는지 확인한다.
  DNS 응답에 자기 task IP가 없는 경우 Hazelcast가 다른 non-loopback 주소로 대체할 수 있으므로
  실제 bind 주소와 멤버 목록을 확인한다. overlay 하나가 컨테이너 인터페이스 하나를 뜻하지는 않는다.
- Eureka를 처음 배포할 때 Docker hostname으로 기동하고 healthy 이후 task DNS에 자기 IP가 나타나는지 확인한다.
- Eureka replica 교체·증감 시 피어 목록과 등록 URL이 실제 task IP로 갱신되는지 확인한다.
- Barosteel·Gateway 롤링 배포 후 세션 공유와 로그인 흐름을 확인한다.
- Admin Swagger에서 Barosteel API 문서가 로드되고, Gateway의 익명 문서 요청은 거절되는지 확인한다.

## 롤백

이전 이미지·중앙 설정·Compose를 함께 복구한다. CIDR 기반 구버전을 다시 사용할 경우 이전 고정 subnet도
필요하다. 새 공통 네트워크에 구버전 이미지만 되돌리지 않는다. 연결 서비스 중단과 네트워크 재생성이
필요할 수 있으므로 작업 전에 이전 설정을 확보한다. 메모리 세션·캐시는 전체 종료 시 소실될 수 있다.

이 문서는 적용 절차다. 로컬 코드 수정이나 테스트 통과가 운영 배포 완료를 의미하지 않는다.
