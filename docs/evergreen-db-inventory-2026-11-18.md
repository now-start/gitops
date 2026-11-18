# Evergreen 운영 DB 조사 — 2026-11-18

이 문서는 이관 전 조사 기록이다. 이후 결정과 실제 결과는 [PostgreSQL 3.0.0 전환 결과](evergreen-postgresql-migration.md)를 따른다.

NOW_START의 실행 컨테이너와 원본 DB를 SSH로 직접 확인했다. DB 조회는 READ ONLY 트랜잭션과
consistent snapshot, 쿼리당 15초 제한으로 수행했다. 배포·스키마·데이터 변경과 거래소 API 호출은 하지 않았다.
행 수는 2026-11-18 17:51 KST경 스냅샷이다. 서비스가 계속 실행 중이므로 이후 이벤트가 증가한다.

## 실제 배포 코드

- 서비스: `evergreen_coin`, NOW_START, 실행 replica 1.
- 이미지: `ghcr.io/now-start/evergreen:2.2.7`.
- 배포 digest: `sha256:73e8d5c195295343eb75f3dc900406e5701e1ba5fc8a6cd6a10b6e3dd3aa1db6`.
- 컨테이너: `2271e41e934e`, 이미지 ID `sha256:d62059b7c71cb2b4758e370b900b7932e45bd8b9e9f66e4db48fca70a4da4217`.
- OCI revision 라벨: `6eb99990400500798bdcb5381cb2ceeaa5d6a646`.
  [대응 소스 커밋](https://github.com/now-start/evergreen/commit/6eb99990400500798bdcb5381cb2ceeaa5d6a646).
  커밋 연결은 이미지 라벨 기준이며 GitHub 소스 전체와의 대조는 수행하지 않았다.
- 실제 패키지 위치: `/app/.venv/lib/python3.12/site-packages/evergreen`.
- Config 조회: 애플리케이션 `evergreen`, profile `default`, 현재 응답의 `live-enabled=true`.
  이는 별도 조회 프로세스가 읽은 Config 값이며 장기 실행 프로세스의 메모리 설정을 직접 읽은 것은 아니다.

컨테이너 파일과 로컬 소스를 LF 정규화 후 SHA-256으로 비교했다.
`database/config.py`, `connection.py`, `migration.py`, `v0001_execution.py`, `trading/recovery.py`는 일치한다.
`trading/state.py`, `trading/runtime.py`는 다르다. 로컬 2.2.4를 수정 기준으로 그대로 삼으면 안 된다.

운영에는 `v0002_remove_key_identity.py`가 추가되어 있고 DB revision도 `0002_remove_key_identity`다.
이 revision은 상태와 이벤트 JSON에서 API 키 identity를 제거한다. `JSON_REMOVE`/`JSON_VALID`를 사용하므로
새 PostgreSQL에서 전체 migration chain을 실행하려면 이 단계도 dialect에 맞게 처리해야 한다.
원본 0001만 적용하거나 기존 revision을 강제 stamp하는 방식으로 우회하지 않는다.

## 원본 DB와 스키마

접속점은 `nowstart.org:3306`, DB는 `evergreen`, 서버 버전은 `10.11.11-MariaDB`다.
운영 연결 코드는 `mysql+asyncmy`이며 PostgreSQL URL을 거부한다.
전체 테이블은 아래 3개이며 모두 InnoDB, `utf8mb3_general_ci`다. 조회 결과 별도 view는 없다.

| 테이블 | 정확한 행 수 | 할당 DATA_LENGTH | INDEX_LENGTH | AUTO_INCREMENT |
| --- | ---: | ---: | ---: | ---: |
| evergreen_alembic_version | 1 | 16,384 B | 0 B | 없음 |
| evergreen_execution_state | 1 | 16,384 B | 0 B | 2 |
| evergreen_execution_event | 160,968 | 200,998,912 B | 0 B | 160,969 |

총 할당 데이터 크기는 약 191.72 MiB다. InnoDB 메타데이터상의 할당량이며 백업 파일 크기가 아니다.
INDEX_LENGTH=0이어도 각 테이블에 기본 키는 있다. 추정 TABLE_ROWS와 정확한 COUNT(*)는 구분했다.

```sql
CREATE TABLE evergreen_alembic_version (
  version_num varchar(32) NOT NULL PRIMARY KEY
);
CREATE TABLE evergreen_execution_state (
  id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
  payload text NOT NULL
);
CREATE TABLE evergreen_execution_event (
  id int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
  time varchar(40) NOT NULL,
  event varchar(40) NOT NULL,
  payload text NOT NULL
);
```

위 DDL은 실제 SHOW CREATE TABLE의 컬럼·제약 요약이며 PostgreSQL 실행용 SQL이 아니다.

## 중요도와 최소 이관 범위

사용자는 중요하지 않은 데이터는 이관 없이 새 DB로 시작해도 된다고 했다.
조사 결과 **전체 초기화보다 상태 1행과 핵심 이벤트 16행만 보존하는 방식**을 제안한다.
아래 분류는 운영 소스의 참조 경로를 확인한 판단이며 실제 부분 적재 리허설은 아직 수행하지 않았다.

| 이벤트 | 행 수 | 판단 |
| --- | ---: | --- |
| valuation | 143,821 | 과거 평가·차트 자료, 이관 생략 후보 |
| unexpected-balance | 14,632 | 과거 잔액 불일치 진단 기록, 이관 생략 후보 |
| strategy-evaluated | 1,255 | 과거 전략 평가·차트 자료, 이관 생략 후보 |
| no-signal | 1,244 | 과거 신호 없음 기록, 이관 생략 후보 |
| order-intent | 4 | 주문 추적을 위해 보존 |
| order-accepted | 4 | 주문 추적을 위해 보존 |
| order-terminal | 4 | 손익 재구성과 잔액 기준선에 사용, 보존 |
| initialized | 1 | 손익 재구성과 최초 기준선에 사용, 보존 |
| cashflow-reconciled | 1 | 입출금 조정과 잔액 기준선에 사용, 보존 |
| initialization-approved | 1 | 설치 승인 이력 보존 |
| strategy-transition | 1 | 전략 변경 이력 보존 |

핵심 16행의 payload 합계는 **15,064 B**, 상태는 JSON 재직렬화 기준 약 452 B다.
나머지 이벤트 160,952행은 신규 DB 적재를 생략하고 원본 DB/백업에 보관할 수 있다.
별도 크기 조회에서는 valuation이 이미 1행 증가했다. 실행 시 최종 중지 시점 기준으로 다시 산정해야 한다.
이벤트 생략 시 새 DB에는 해당 과거 진단·평가 기록이 없으며, 별도 외부 소비자의 의존성은 확인하지 않았다.

상태 확인 결과:

- `pending=null`, `order_sequence=4`, `halted=false`.
- 저장 잔액과 전략 buffer가 존재한다. 전략은 `breakout-buffer-early3-v1`.
- `intent_context`와 `reserved_exit`는 없다.
- 이는 DB 상태이며 거래소의 실제 미체결 주문이 없다는 증명은 아니다.

실제 `Store.performance()`는 initialized/order-terminal/cashflow-reconciled 이벤트로 손익을 재구성하고,
`balance_baseline()`도 같은 이벤트에서 마지막 잔액 기준선을 찾는다.
따라서 이벤트가 단순 로그라고 보고 전부 버리면 이 기능의 연속성을 잃는다.
현재 상태를 버리면 order_sequence, peak, buffer, 잔액 기준선도 초기화된다.
빈 DB에서는 초기화 승인 없이는 워커가 실행되지 않으며, 초기화 시 기존 BTC 보유를 거부하는 경로도 있다.

## 다음 구현의 기준

1. 운영 2.2.7의 실제 커밋을 기준으로 PostgreSQL 드라이버·TLS·세션 잠금·소유권 검증을 구현한다.
2. 0002까지의 migration chain이 빈 PostgreSQL에서 동작하도록 검증한다.
3. 상태 1행과 위 7종류 이벤트를 기존 ID/시간/payload 그대로 적재하는 리허설을 준비한다.
   운영 전환 시 생긴 새로운 이벤트 종류는 자동 제외하지 않고 다시 분류한다.
4. 대상 이벤트 sequence는 보존한 이벤트의 최대 ID뿐 아니라 **최종 원본 전체 이벤트 최대 ID보다 크게** 맞춘다.
   생략한 과거 ID의 재사용을 피하고, 중지 시점 원본 AUTO_INCREMENT도 함께 확인한다.
5. 대상 Alembic revision은 검증된 migration chain으로 생성한다. 원본 이력 행을 무조건 덮어쓰지 않는다.
6. 상태 읽기, 손익 재구성, 잔액 기준선이 원본과 같은지 주문 없이 검증한다.
   실제 전환 때 모든 구 워커 종료와 거래소 미체결 주문 대조가 필요하다.

현재 조사에서는 원본 보존, 무변경 조회만 수행했다. PostgreSQL 연결 전환과 데이터 적재는 아직 하지 않았다.
