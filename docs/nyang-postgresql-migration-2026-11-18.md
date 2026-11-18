# Nyang-Nyang Bot PostgreSQL 6.0.0 전환

## 범위

- 대상: Swarm `chzzk_nyang-nyang-bot` 한 서비스.
- 원본: MariaDB `nyang_nyang_bot`, 앱 5.9.12 / `b04c63c8f9a7b183843d87858e75a0ed3f3e8892`.
- 대상 DB: PostgreSQL 18.3 `nyang_nyang_bot`, `postgres_haproxy:5432` primary/TLS 접속.
- 새 앱: PostgreSQL 전용 6.0.0 / `913321076ca83a197f218e900d0c35f817fb0945`.
- 기존 전용 DB 계정과 비밀번호는 유지한다. MariaDB 전용 Hibernate 타입 설정은 제거한다. DB 세션·JVM은 UTC로 통일한다.
- 이관 데이터 생략 없음. 16개 업무 테이블과 Flyway baseline 이력 1개를 모두 포함한다.

## 사전 검증

- 운영 이미지 revision과 소스 main 일치 확인.
- 리허설 전체 스냅샷 17테이블 8,592행.
- 전체 행·컬럼 정규화 SHA-256 및 다음 ID 대조 일치.
- PK 17개, FK 25개, UNIQUE 19개, CHECK 48개로 원본과 대상 일치.
- 원본 외래 키 조회 인덱스까지 PostgreSQL에 명시적으로 구성.
- 원본 TIMESTAMP(6)를 UTC 세션에서 읽고 timestamptz(6)로 보존.
- OAuth 토큰, 포인트 원장, NULL, 생성 컬럼 등 전체 값을 비교. 원문은 로그에 출력하지 않음.
- 실제 리허설 데이터를 연결한 6.0.0 앱 health/readiness UP, Flyway/JPA 검증 통과.
- 검증 앱은 채팅 연결, 타이머, Google 동기화, 룰렛 복구와 서비스 등록을 비활성화.
- 전체 Java 392개 테스트 통과. JVM UTC 환경도 전체 통과.
- 중앙 Config는 UTC 세션을 설정하며 서울 달력·출력·새벽 4시 스케줄은 명시적으로 Asia/Seoul을 사용한다.
- 중앙 Config의 nyang 설정 테스트 통과, Swarm Compose 검증 통과.

## 보호 파일

NOW_START의 `/volume1/docker/nyang-postgresql-migration` 폴더는 0700이다.
스냅샷은 0600으로 생성한다. 사용자·OAuth 정보가 포함되어 Git과 로그에 원문을 남기지 않는다.
원본 MariaDB를 삭제하거나 수정하지 않는다.

## 최종 운영 전환

- 2026-11-18 20:07:42 KST 쓰기 중지를 시작했고 기존 컨테이너는 20:07:51 KST 종료했다. 다른 원본 DB 연결이 0개임을 확인했다.
- REPEATABLE READ 읽기 전용 일관 스냅샷으로 17테이블 8,592행을 추출했다.
- `final.json` SHA-256: `3cf0a13c66a4e7f7297d92f4e2c8904823cd647c944c78e979aa185a8b3b4e0d`.
- 스키마·전체 데이터·identity 다음 값을 한 트랜잭션으로 반영하고 `IMPORT_COMMITTED`를 확인했다.
- 커밋 후 대상의 모든 행·컬럼을 다시 읽어 원본 스냅샷과 정규화 해시 일치를 검증했다. 원본 재조회에서도 `SOURCE_UNCHANGED`를 확인했다.
- 최종 대조가 끝난 뒤 중앙 Config main `6bb6f04`를 반영했다. Config 3개 replica 모두 PostgreSQL URL 및 UTC 세션 설정을 확인했다.
- GitOps main `a7e2bc8`으로 6.0.0, TZ=UTC, replicas=1을 반영하고 동일 설정으로 Swarm 서비스를 재개했다.
- 운영 태스크 `apm4mshf8fv1`이 5분 이상 재시작 없이 Running, replicas 1/1이다. health/readiness 모두 UP, actuator 버전 6.0.0 / revision 9133210을 확인했다.
- 이미지 digest: `sha256:c4d8d543797178a9ca29e07c36abe3c163f5a99806e90cac83d7034d9fae5d4d`.
- 애플리케이션 JDBC 연결 10개 모두 TLS 사용, 미검증 PostgreSQL 제약 조건 0개를 확인했다.
- CHZZK 조회 API에서 활성 세션 1개 및 CHAT 구독을 확인했다. DONATION 구독에는 별도의 후원 조회 권한 부족 403이 발생한다. 이 권한 문제는 해결되지 않았으며 이전 운영에서도 발생했는지는 확인하지 못했다.
- 임시 원격 이관/검증 컨테이너, 리허설 DB, 검증 JAR와 로컬 테스트 DB 컨테이너를 정리했다. 원본 MariaDB와 보호된 최종 스냅샷·검증 로그는 보존했다.
- 실행 재개 후 발생하는 정상적인 신규 데이터 변경은 이관 직전의 전체 대조 결과와 구분한다.

| 테이블 | 이관 행 수 |
| --- | ---: |
| command | 2 |
| command_execution | 530 |
| donation | 0 |
| flyway_schema_history | 1 |
| oauth_credential | 88 |
| overlay_access_token | 1 |
| overlay_display_job | 0 |
| point_adjustment_preset | 36 |
| point_ledger_entry | 1,775 |
| reward_grant | 0 |
| roulette_config | 0 |
| roulette_option | 0 |
| roulette_round | 0 |
| roulette_run | 0 |
| timer_message | 0 |
| user_account | 1,058 |
| weekly_chat_count | 5,101 |
| **합계** | **8,592** |

## 릴리스 및 검증 기록

- [6.0.0 릴리스](https://github.com/now-start/nyang-nyang-bot/releases/tag/6.0.0)
- [애플리케이션 CI 성공](https://github.com/now-start/nyang-nyang-bot/actions/runs/44290054106)
- [운영 GitOps 검증 성공](https://github.com/now-start/gitops/actions/runs/44292110299)
