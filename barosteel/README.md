# 바로스틸 배포

냥냥봇과 같은 독립 Docker Swarm 스택이다. 스택 이름은 `barosteel`, 정의 파일은 `barosteel/docker-compose.yml`이다.

## 구성

- 이미지: `ghcr.io/now-start/barosteel:0.1.0` (다른 스택과 동일하게 Compose에서 버전 관리)
- 설정: `configserver:http://config:8888` 필수 연결
- DB: platform의 `barosteel.yaml`에 등록한 `{cipher}` 값을 Config Server가 복호화해 제공
- 서버·관리 엔드포인트: platform 공통 `application.yaml` 상속
- 네트워크: `platform_default`, `grafana_default`; 호스트 포트 직접 공개 없음
- 경로: Gateway의 `/barosteel/**` 자동 라우팅, 애플리케이션 내부 루트 경로
- 복제 수: 1; 갱신은 stop-first, 실패 시 rollback

DB용 Swarm Secret과 configtree는 사용하지 않는다. Config Server는 해당 암호문을 생성한 키로 복호화할 수 있어야 한다. 평문 DB 정보는 Compose나 환경변수 예시 파일에 기록하지 않는다.

## 배포 순서

1. Gateway `6.1.3`과 Config Server `2.1.17`의 이미지 발행 성공을 확인한 뒤 `platform/docker-compose.yml`의 이미지 버전을 갱신한다. 현재 파일은 기존 운영 버전을 유지한다.
2. Config Server에 바로스틸 DB 암호화 설정을 반영한다. 복호화와 MariaDB 연결은 운영 환경에서 확인한다.
3. Compose에 지정된 바로스틸 `0.1.0` 이미지의 발행 성공을 확인한다. 이후 릴리스도 `docker-compose.yml`의 이미지 태그를 변경해 반영한다.
4. `docker stack config -c barosteel/docker-compose.yml`로 렌더링을 검증한 뒤 배포한다.
5. Gateway를 통한 로그인·로그아웃·정적 파일·견적·포인트 기능을 확인한다.

이미지 버전은 `0.1.0`으로 지정했으며 배포는 실행하지 않았다. 초기 관리자 등록은 애플리케이션의 관리자 초기화 절차를 따른다.

## 운영 조건

공유 세션과 분산 로그인 제한을 구현하기 전까지 복제 수를 1로 유지한다. 갱신 시 짧은 중단과 세션 종료가 발생할 수 있다. 실제 이미지의 상태 검사 도구가 확인되지 않아 셸 기반 healthcheck는 추가하지 않았다.
