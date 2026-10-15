# 바로스틸 통합 앱 스케일 아웃

하나의 이미지와 DB를 사용한다. 모든 인스턴스가 모든 업무와 외부 API를 제공하며 Eureka 이름은 `barosteel`이다.
기존 Spring Gateway discovery 라우팅을 유지하고 별도 Nginx·업무별 라우트·내부 HTTP 설정은 사용하지 않는다.

Config Server의 `barosteel.yaml`에서 DB와 `barosteel.session.shared: true`를 제공한다.
공유 세션·로그인 제한·업로드 파일은 동일 DB에 저장된다. 푸시는 DB 작업 선점과 lease를 사용한다.
외부 발송 후 프로세스가 종료되는 경우 재전송 가능성이 있으므로 정확히 한 번 발송을 보장하지는 않는다.

`docker service scale barosteel_barosteel=3`으로 통합 앱을 증설하고 Compose의 `deploy.replicas`도 함께 맞춘다.
DB 연결 풀과 DB 처리 용량은 전체 인스턴스 수에 맞게 산정한다.

현재 태그 0.1.18이 이번 로컬 변경을 포함한다는 뜻은 아니다. 변경을 포함하는 새 이미지 발행 후 태그를 교체해야 한다.
Config 저장소 반영, 실제 Eureka/Gateway/Swarm 연결과 MariaDB 검증은 배포 전에 수행한다.
실제 운영 배포는 별도 검증한다. 관련 작업: barosteel #45, #46. 운영 검증: #12.
