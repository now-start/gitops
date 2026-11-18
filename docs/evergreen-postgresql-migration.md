# Evergreen PostgreSQL 3.0.0 전환 결과

2026-11-18 운영 전환. 대상은 `evergreen_coin`이며 lotto는 변경하지 않았다.
PostgreSQL 전용 3.0.0으로 전환했고 2.x 호환 계층이나 이전 버전 복귀 경로는 구성하지 않았다.

## 릴리스와 설정

- 앱 main: `a19c54b` (PostgreSQL 전용 3.0.0), 최종 `64056fc` (추가 Mako 보안 패치).
- 릴리스: https://github.com/now-start/evergreen/releases/tag/3.0.0
- 최종 CI: https://github.com/now-start/evergreen/actions/runs/44277104587 — 성공.
- 이미지: `ghcr.io/now-start/evergreen:3.0.0`.
- digest: `sha256:f519aa1b6b8775a0a2db7c65efeba3c87d07acdb81f562ab82669f3102ba0d69`.
- OCI revision: `64056fc4a134bdeeaa21b4c7938285d0aba1693f`.
- 중앙 Config main: `68004d2`. evergreen의 암호화된 datasource URL만 PostgreSQL로 변경했다.
- GitOps main: `74db060` (실거래 비활성 배포), `7b08fe8` (실거래 재개).
- coin의 배포 실패 동작은 `pause`다. PostgreSQL에 접속할 수 없는 2.x 이미지로 자동 복귀하지 않는다.

기존 PostgreSQL `evergreen` DB와 전용 소유 계정이 이미 준비되어 있었다.
기존 Config 자격증명으로 실제 primary/TLS 접속이 됨을 확인해 계정과 암호는 변경하지 않았다.
Config Server 세 복제본 모두 다음 접속 주소를 반환하는 것을 확인했다.

```text
jdbc:postgresql://postgres_haproxy:5432/evergreen?sslmode=require&connectTimeout=3
```

## 이관 데이터

[이관 전 스키마·규모 조사](evergreen-db-inventory-2026-11-18.md)를 기준으로 상태 1행과 핵심 이벤트 16행을 옮겼다.

| 항목 | 결과 |
| --- | --- |
| 원본 | MariaDB 10.11.11 / evergreen / revision 0002_remove_key_identity |
| 대상 | PostgreSQL / evergreen / revision 0001_postgresql |
| 상태 | id=1 한 행, payload 원문 보존 |
| 핵심 이벤트 | 16행, 기존 id/time/event/payload 원문 보존 |
| 원본 전체 마지막 ID | 161088 |
| 대상 다음 이벤트 ID | 161089 (기존에 생략한 ID를 재사용하지 않음) |
| 주문 순번 | 4 유지 |
| pending | 없음 |
| 손익 장부·잔액 기준선 | 추출 데이터와 현재 상태 일치 |

보존 종류는 initialization-approved, initialized, cashflow-reconciled, order-intent,
order-accepted, order-terminal, strategy-transition이다.
과거 valuation, unexpected-balance, strategy-evaluated, no-signal은 새 DB 적재에서 제외했다.
재개 후 새 평가·진단 이벤트는 PostgreSQL에 정상 기록된다.

원본 DB는 삭제·변경하지 않았다. 원본 워커 종료 후 원본 세션 잠금 및 consistent snapshot으로 추출했다.
스냅샷은 NOW_START의 `/volume1/docker/evergreen-migration-3/evergreen-v2.json`에 보관한다.
파일 권한은 0600, 상위 폴더는 0700이며 계좌·주문 정보가 있으므로 Git에 포함하지 않는다.
일회성 추출 스크립트도 같은 보호 폴더에 있다.

Swarm job 모드가 중복 태스크를 스케줄링하여 임시 job 서비스를 제거했다.
정리 중 먼저 완료된 추출 파일을 사용했으며, 추출기의 배타 잠금과 O_EXCL 생성으로 중복 덮어쓰기는 방지됐다.
이후 PostgreSQL 적재는 재시작 없는 단일 replicated 서비스로 실행했고 성공 후 임시 서비스를 제거했다.
적재기에서 체크섬·행 수·손익 장부·잔액 기준선 검증과 적재 후 원문 비교를 모두 통과했다.

## 검증

- 로컬 전체 1,063개 테스트 통과, 커버리지 90.20%.
- Mako 추가 패치 후 PostgreSQL migration·이관 테스트 38개 재통과.
- 최종 GitHub CI의 PostgreSQL 통합 검사, 전체 테스트, 보안 검사, amd64/arm64 이미지 빌드와 릴리스 성공.
- pip-audit 알려진 취약점 없음. GitHub 열린 Dependabot 경고도 해소 확인.
  자체 evergreen과 별도 인덱스 torch+cpu는 pip-audit의 PyPI 검사 대상이 아니다.
- Ruff, 포맷, mypy, docker stack config, git diff --check 통과.
- 실거래 비활성 상태에서 앱 health UP, 실제 primary 연결, TLS=true 검증.
- 재개 직전 거래소 미체결 주문 없음 확인. 주문 제출·취소를 별도 실행하지 않았다.
- 재개 후 health UP, trading.status=running, last_result=already-evaluated,
  error_type=null, attempt=0, pending 없음, 실행 잠금 1개 확인.
- 보존된 핵심 16행과 신규 이벤트 기록을 실제 PostgreSQL에서 확인.

## 완료 확인

2026-11-18 19:07:10 KST에 Swarm UpdateStatus가 completed로 종료됐다.
coin은 3.0.0 컨테이너 한 개가 healthy 상태이며 이전 컨테이너는 모두 종료됐다.
coin과 lotto 모두 1/1이다. 최종 health=UP, trading.status=running,
last_result=already-evaluated, error_type=null, attempt=0을 확인했다.
GitOps 실거래 재개 커밋의 Compose 검증 CI도 성공했다:
https://github.com/now-start/gitops/actions/runs/44281229768

