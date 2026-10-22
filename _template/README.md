# 범용 Docker Swarm 스택 템플릿

오버레이 네트워크와 NFS 공유 볼륨을 사용하는 장기 실행 서비스용 기본형입니다.
NFS 서버 기본값은 `100.100.1.1`, 공유 경로 예제는 `/volume1/docker/app`입니다.
`docker stack deploy`용이며 Kubernetes나 일반 Compose의 동작까지 보장하는 템플릿은 아닙니다.

## 사용 방법

1. 이 디렉터리를 새 스택 디렉터리로 복사합니다.
2. `app`을 서비스 이름으로, `REPLACE_IMAGE:0.0.0`을 고정 버전 이미지로 바꿉니다.
3. NFS 기본값 `100.100.1.1:/volume1/docker/app`에서 `app`을 해당 서비스의 공유 디렉터리로 바꿉니다. 저장소가 필요 없으면 서비스의 `volumes`와 최상위 `volumes`를 함께 제거합니다.
4. 필요한 포트·환경변수·상태 검사 항목만 주석을 해제합니다. 시간대가 필요하면 `TZ: Asia/Seoul` 예제를 사용합니다. Spring/Paketo 이미지에서는 `THC_PORT: "8081"`, `THC_PATH: /actuator/health/readiness`와 `/workspace/health-check` 예제를 함께 활성화합니다.
5. `replicas`를 지정하거나, 노드마다 실행하려면 `mode: global`로 바꾸고 `replicas`를 제거합니다.
6. `docker stack config -c <stack>/docker-compose.yml`로 검증한 뒤 배포합니다.

서비스를 추가할 때도 `service-defaults`와 `deploy-defaults`를 상속합니다.
YAML 병합은 얕은 병합이므로 `deploy`를 다시 선언할 때 `<<: *deploy-defaults`를 포함해야 합니다.

## 공통 기본값

| 항목 | 기본값 |
| --- | --- |
| 네트워크 | overlay, MTU 1200 |
| 저장소 | NFS v4, hard 마운트, 서비스 경로 `/data` |
| 종료 유예 | 5분, `deploy` 밖의 서비스 속성 |
| 업데이트 | 한 개씩, stop-first, 실패 시 rollback, 5분 감시 |
| 롤백 | 한 개씩, stop-first, 실패 시 pause, 5분 감시 |
| 재시작 | any, 5초 지연 |
| 상태 검사 | 선택 사항. 활성화 시 30초 간격·30초 제한·3회 실패·5분 시작 유예 |

이미지·포트·환경변수·저장소·서비스 수·복제 수·배치 제약은 서비스별 입력입니다.
상태 검사 명령은 이미지에 실제 존재하고 서비스 자체의 생존 여부를 확인하는 명령을 사용합니다.
MTU 1200은 패킷 크기 설정이며 대역폭 제한이 아닙니다. 배포 네트워크에 맞게 조정할 수 있습니다.
NFS 공유 경로는 태스크가 배치될 모든 노드에서 접근 가능해야 하며, 컨테이너 사용자에게 필요한 읽기·쓰기 권한을 서버에서 설정합니다.
`hard` 마운트는 NFS 응답이 없으면 I/O를 재시도하며 기다립니다. 여러 복제본이 같은 경로를 쓰므로 애플리케이션의 동시 접근 지원 여부를 확인합니다.
사용자 권한, 시간대, NFS 서버 주소, 외부 네트워크 이름은 서비스와 환경에 맞게 지정합니다.

`restart_policy.condition: any`는 성공 종료도 재시작합니다. 초기화·마이그레이션처럼 완료 후
끝나야 하는 작업에는 이 장기 실행 서비스 템플릿을 그대로 사용하지 않습니다.

`.env.example`에는 선택적 시크릿 예제만 있습니다. 필요 없다면 삭제하고,
실제 값은 배포 도구의 환경 변수나 별도 시크릿 관리 기능에서 제공합니다.

Spring 상태 검사 예제는 이미지에 Paketo health-checker가 포함되고 Actuator readiness가 8081 포트에 노출된 경우에 사용합니다. THC 환경 변수만 추가해도 검사 실행 파일이나 Actuator가 자동으로 설치되는 것은 아닙니다.
