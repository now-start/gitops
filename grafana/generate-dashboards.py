"""Rebuild the three provisioned dashboards with python generate-dashboards.py."""
import json
from pathlib import Path

ROOT = Path(__file__).parent / 'dashboards'
DS = {'type': 'prometheus', 'uid': 'prometheus'}
S = 'service_name=~"$service",instance=~"$instance"'
HTTP = S + ',uri!~"/actuator.*"'
CONT = 'service=~"$swarm_service",node=~"$node"'


def variable(name, query, label):
    return dict(name=name, label=label, type='query', datasource=DS,
                query={'query': query, 'refId': name}, definition=query,
                refresh=1, sort=1, multi=True, includeAll=True, allValue='.*',
                current={'text': 'All', 'value': '$__all'})


def panel(title, expressions, unit='short', description='', table=False):
    if isinstance(expressions, str):
        expressions = [(expressions, '{{service_name}} / {{instance}}')]
    return dict(title=title, type='table' if table else 'timeseries', datasource=DS,
                description=description,
                targets=[dict(refId=chr(65+i), expr=expr, legendFormat=legend,
                              range=not table, instant=table, format='table' if table else 'time_series')
                         for i, (expr, legend) in enumerate(expressions)],
                fieldConfig={'defaults': {'unit': unit, 'custom': {'drawStyle': 'line', 'lineWidth': 2,
                             'fillOpacity': 8, 'spanNulls': False}}, 'overrides': []},
                options={'legend': {'displayMode': 'table', 'placement': 'bottom', 'calcs': ['lastNotNull', 'max']},
                         'tooltip': {'mode': 'multi', 'sort': 'desc'}})


def write(uid, title, panels, variables, note):
    intro = dict(id=1, title='읽는 방법', type='text', gridPos={'x': 0, 'y': 0, 'w': 24, 'h': 3},
                 options={'mode': 'markdown', 'content': note})
    for i, item in enumerate(panels):
        item.update(id=i+2, gridPos={'x': (i%2)*12, 'y': 3+(i//2)*9, 'w': 12, 'h': 9})
    dashboard = dict(uid=uid, title=title, schemaVersion=39, version=1, editable=False,
                     tags=['now-start', 'operations'], timezone='browser', refresh='30s',
                     time={'from': 'now-1h', 'to': 'now'}, templating={'list': variables},
                     annotations={'list': []}, panels=[intro]+panels,
                     links=[{'title': label, 'type': 'link', 'url': '/d/'+target, 'keepTime': True}
                            for target,label in [('nowstart-services','서비스 현황'),('nowstart-spring','Spring Boot 상세'),('nowstart-swarm','Swarm 인프라')]])
    if uid == 'nowstart-services':
        dashboard['panels'] = [p for p in dashboard['panels'] if p['title'] not in ['서비스 목표 / 실행 개수', '새 태스크 생성 · 최근 1시간']]
    ROOT.mkdir(exist_ok=True)
    (ROOT / (uid.removeprefix('nowstart-')+'.json')).write_text(json.dumps(dashboard, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


appvars = [variable('service','label_values(jvm_memory_used_bytes, service_name)','서비스'),
           variable('instance','label_values(jvm_memory_used_bytes{service_name=~"$service"}, instance)','인스턴스')]
rate = f'sum by(service_name) (rate(http_server_requests_seconds_count{{{HTTP}}}[$__rate_interval]))'
errors = f'sum by(service_name) (rate(http_server_requests_seconds_count{{{HTTP},status=~"5.."}}[$__rate_interval]))'
write('nowstart-services','서비스 현황 · Spring Boot',[
    panel('요청량 · 서비스별', [(rate,'{{service_name}}')], 'reqps', 'Actuator 경로 제외. Gateway 프록시 요청은 아래 Route 패널에서 별도로 확인합니다.'),
    panel('HTTP 5xx 비율', [(f'100 * (({errors}) or (0 * ({rate}))) / clamp_min(({rate}), 0.000001)','{{service_name}}')], 'percent'),
    panel('응답 시간 p95 / p99', [(f'histogram_quantile({q}, sum by(le,service_name) (rate(http_server_requests_seconds_bucket{{{HTTP}}}[$__rate_interval])))', '{{service_name}} p'+str(int(q*100))) for q in [.95,.99]], 's'),
    panel('메트릭 수신 인스턴스 수', [(f'count by(service_name) (max by(service_name,instance) (timestamp(jvm_memory_used_bytes{{{S}}}) > time()-180))','{{service_name}}')], description='최근 3분 내 수신한 JVM 인스턴스 수. readiness와 동일하지 않습니다.'),
    panel('서비스 목표 / 실행 개수', [('swarm_service_desired_replicas','{{service}} 목표'),('swarm_service_running_replicas','{{service}} 실행')]),
    panel('서비스 버전 · 인스턴스', [(f'count by(service_name,service_version,instance,host_name) (jvm_memory_used_bytes{{{S}}})','')], table=True, description='버전 변경과 인스턴스 교체를 확인합니다.'),
    panel('오류 로그 발생률', [(f'sum by(service_name) (rate(logback_events_total{{{S},level="error"}}[$__rate_interval]))','{{service_name}}')], 'ops'),
    panel('느린 API p95 · 상위 10', [(f'topk(10,histogram_quantile(0.95,sum by(le,service_name,uri) (rate(http_server_requests_seconds_bucket{{{HTTP}}}[$__rate_interval]))))','{{service_name}} {{uri}}')], 's'),
    panel('Gateway Route 요청량', [('sum by(routeId) (rate(spring_cloud_gateway_requests_seconds_count[$__rate_interval]))','{{routeId}}')], 'reqps', 'Gateway 전체 프록시 트래픽. 상단 서비스 필터와 독립적입니다.'),
    panel('Gateway Route 5xx', [('sum by(routeId) (rate(spring_cloud_gateway_requests_seconds_count{httpStatusCode=~"5.."}[$__rate_interval]))','{{routeId}}')], 'reqps'),
    panel('Gateway Route p95', [('histogram_quantile(0.95,sum by(le,routeId) (rate(spring_cloud_gateway_requests_seconds_bucket[$__rate_interval])))','{{routeId}}')], 's'),
    panel('새 태스크 생성 · 최근 1시간', [('count by(service) (swarm_task_created_timestamp_seconds > time()-3600)','{{service}}')], description='배포 및 재시도 모두 포함. Docker의 동일 컨테이너 restart count와 다릅니다.'),
],appvars,'사용자 영향은 요청량 → 5xx → p95/p99 순서로 확인하세요. 평균은 문제 인스턴스를 가릴 수 있습니다. [로그 탐색](/a/grafana-lokiexplore-app/explore) · [트레이스 탐색](/a/grafana-exploretraces-app/)에서 같은 서비스와 시간 범위를 선택하세요. No data는 정상/0을 의미하지 않습니다.')

write('nowstart-spring','Spring Boot 상세 · JVM / DB / 외부 호출',[
    panel('Heap 사용량 / 확보량', [(f'sum by(service_name,instance) (jvm_memory_{m}_bytes{{{S},area="heap"}})','{{service_name}} {{instance}} '+m) for m in ['used','committed']], 'bytes'),
    panel('Heap 사용률', f'100 * sum by(service_name,instance) (jvm_memory_used_bytes{{{S},area="heap"}}) / sum by(service_name,instance) (jvm_memory_max_bytes{{{S},area="heap"}} > 0)', 'percent'),
    panel('GC 후 Old 영역 사용률', f'100 * jvm_memory_usage_after_gc{{{S}}}', 'percent', 'GC 후 long-lived 영역 비율. 전체 Heap 또는 Docker 제한 대비 비율이 아닙니다.'),
    panel('GC 정지 시간 비율', f'100 * sum by(service_name,instance) (rate(jvm_gc_pause_seconds_sum{{{S}}}[$__rate_interval]))', 'percent'),
    panel('GC 정지 p95', f'histogram_quantile(0.95,sum by(le,service_name,instance) (rate(jvm_gc_pause_seconds_bucket{{{S}}}[$__rate_interval])))', 's'),
    panel('Non-heap 사용량', f'sum by(service_name,instance) (jvm_memory_used_bytes{{{S},area="nonheap"}})', 'bytes'),
    panel('Direct 버퍼 사용량', f'jvm_buffer_memory_used_bytes{{{S},id="direct"}}', 'bytes'),
    panel('프로세스 CPU 사용률', f'100 * process_cpu_usage{{{S}}}', 'percent', 'JVM OperatingSystemMXBean 기준 비율. 코어 사용량은 인프라 대시보드에서 확인하세요.'),
    panel('스레드 상태', [(f'sum by(service_name,instance,state) (jvm_threads_states{{{S}}})','{{service_name}} {{instance}} {{state}}')]),
    panel('Executor 큐 대기', [(f'executor_queued_tasks{{{S}}}','{{service_name}} {{instance}} {{name}}')]),
    panel('DB 연결 사용률', f'100 * hikaricp_connections_active{{{S}}} / hikaricp_connections_max{{{S}}}', 'percent'),
    panel('DB 연결 대기', [(f'hikaricp_connections_pending{{{S}}}','{{service_name}} {{instance}} {{pool}}')]),
    panel('DB 연결 획득 p95', f'histogram_quantile(0.95,sum by(le,service_name,instance) (rate(hikaricp_connections_acquire_seconds_bucket{{{S}}}[$__rate_interval])))', 's'),
    panel('외부 HTTP 호출 p95', f'histogram_quantile(0.95,sum by(le,service_name,instance) (rate(http_client_requests_seconds_bucket{{{S}}}[$__rate_interval])))', 's'),
    panel('Circuit Breaker 실패율', [(f'resilience4j_circuitbreaker_failure_rate{{{S}}}','{{service_name}} {{name}}')], 'percent'),
    panel('프로세스 uptime', f'process_uptime_seconds{{{S}}}', 's'),
],appvars,'서비스와 인스턴스를 선택하세요. JVM 메모리는 컨테이너 전체 메모리가 아닙니다. DB·Circuit Breaker가 없는 앱은 해당 패널이 비어 있는 것이 정상입니다. [로그](/a/grafana-lokiexplore-app/explore) · [트레이스](/a/grafana-exploretraces-app/)')

infra_vars=[variable('service','label_values(process_uptime_seconds, service_name)','서비스')]
write('nowstart-swarm','Swarm 인프라 · 현재 수집 범위',[
    panel('시스템 메모리 사용률 · 수집 앱 기준', [('100 * system_memory_utilization_ratio{state="used"}','{{service_name}} {{instance}}')], 'percent', '현재 evergreen에서만 수집. 모든 Swarm 노드의 사용률이 아닙니다.'),
    panel('시스템 메모리 사용량', [('system_memory_usage_bytes{state="used"}','{{service_name}} {{instance}}')], 'bytes'),
    panel('시스템 CPU 사용률 · 앱 관측', [('100 * system_cpu_usage{service_name=~"$service"}','{{service_name}} {{instance}}')], 'percent', '각 JVM이 관측한 시스템 CPU 비율입니다. 같은 노드의 여러 앱을 합산하지 마세요.'),
    panel('프로세스 CPU 사용률', [('100 * process_cpu_usage{service_name=~"$service"}','{{service_name}} {{instance}}')], 'percent'),
    panel('애플리케이션 디스크 여유', [('disk_free_bytes{service_name=~"$service"}','{{service_name}} {{instance}} {{path}}')], 'bytes', '앱의 작업 디렉터리 기준 파일시스템. 전체 노드 디스크 목록이 아닙니다.'),
    panel('애플리케이션 디스크 사용률', [('100 * (1 - disk_free_bytes{service_name=~"$service"} / disk_total_bytes{service_name=~"$service"})','{{service_name}} {{instance}} {{path}}')], 'percent'),
    panel('프로세스 uptime · 재기동 확인', [('process_uptime_seconds{service_name=~"$service"}','{{service_name}} {{instance}}')], 's'),
    panel('프로세스 실제 메모리 · 제공 앱만', [('process_memory_usage_bytes','{{service_name}} {{instance}}')], 'bytes'),
    panel('OTel Collector 메모리 RSS', [('otelcol_process_memory_rss','{{instance}}')], 'bytes'),
    panel('OTel 로그 전송 실패', [('sum(rate(otelcol_exporter_send_failed_log_records_total[$__rate_interval]))','실패 / 초')], 'ops'),
],infra_vars,'**기존 메트릭만 사용합니다.** 컨테이너 전체 메모리/상한, 노드별 자원, Swarm 목표 replica, OOM 지표는 현재 미수집이므로 표시하지 않습니다. 시스템 메모리는 evergreen만 제공합니다. No data는 0 또는 정상 상태를 뜻하지 않습니다. 상단 서비스 필터는 앱 지표에만 적용됩니다.')