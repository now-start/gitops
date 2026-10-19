# 바로스틸 통합 앱 스케일 아웃

하나의 이미지와 DB를 사용한다. 모든 인스턴스가 모든 업무와 외부 API를 제공하며 Eureka 이름은 `barosteel`이다.
기존 Spring Gateway discovery 라우팅을 유지하고 별도 Nginx·업무별 라우트·내부 HTTP 설정은 사용하지 않는다.

Config Server의 `barosteel.yaml`에서 DB와 `barosteel.session.shared: true`를 제공한다.
공유 세션·로그인 제한·업로드 파일은 동일 DB에 저장된다. 푸시는 DB 작업 선점과 lease를 사용한다.
외부 발송 후 프로세스가 종료되는 경우 재전송 가능성이 있으므로 정확히 한 번 발송을 보장하지는 않는다.

`docker service scale barosteel_barosteel=3`으로 통합 앱을 증설하고 Compose의 `deploy.replicas`도 함께 맞춘다.
DB 연결 풀과 DB 처리 용량은 전체 인스턴스 수에 맞게 산정한다.

현재 선언된 태그가 이번 로컬 변경을 포함한다는 뜻은 아니다. 프로젝트 버전 변경으로 CI가 새 이미지를 발행한 후 Renovate의 태그 갱신을 반영한다.
Config 저장소 반영, 실제 Eureka/Gateway/Swarm 연결과 MariaDB 검증은 배포 전에 수행한다.
실제 운영 배포는 별도 검증한다. 관련 작업: barosteel #45, #46. 운영 검증: #12.

## 생존 및 준비 상태 검사

Config Server 공통 설정의 `management.endpoint.health.probes.enabled: true`로
`/actuator/health/liveness`와 `/actuator/health/readiness`를 활성화한다.
Docker healthcheck는 관리 포트 8081의 liveness만 검사하며 외부에 포트를 공개하지 않는다.
검사는 `/cnb/lifecycle/launcher -- /workspace/health-check`로 실행한다.
검사 포트와 경로는 루트 Gradle의 `BPE_DEFAULT_THC_PORT`/`BPE_DEFAULT_THC_PATH`로 이미지에 포함한다.
기본 Tiny 런타임 이미지를 유지하며 셸/curl 없이 바이너리를 직접 실행한다.
현재 선언된 기존 태그에 이 도구가 있다고 가정하면 안 된다. 변경된 앱 이미지 발행 및
검사 바이너리/응답 확인 및 Renovate의 이미지 태그 갱신 반영 후 이 Compose를 배포한다.
Platform 저장소의 Config Server 공통 probes 설정도 먼저 반영해야 한다.

readiness는 기본적으로 앱의 요청 수락 상태를 나타내며 DB 등 외부 의존성을 자동 포함하지 않는다.
현재 Gateway/Eureka 구성에 readiness 기반 트래픽 제외가 연동됐다는 뜻은 아니다.
그 연동과 반복 배포 검증은 [barosteel #25](https://github.com/now-start/barosteel/issues/25)에서 관리한다.
별도 관리 포트 검사이므로 서비스 포트의 모든 장애를 감지하지는 못한다.
