# 모니터링 운영 가이드

kube-prometheus-stack 기반 모니터링 스택의 구성과 운영 방법을 설명합니다.

---

## 1. 구성 개요

### 수집 대상 (총 20개 타겟, 모두 활성)

| 대상 | 네임스페이스 | 수집 메트릭 |
| :--- | :--- | :--- |
| node-exporter | monitoring | 서버 CPU / 메모리 / 디스크 / 네트워크 |
| kube-state-metrics | monitoring | 파드 / 디플로이먼트 / PVC 상태 |
| kubelet | kube-system | 컨테이너 리소스 사용량 |
| apiserver | default | K8s API 응답 지연 / 에러율 |
| coredns | kube-system | DNS 조회 지연 / 에러 |
| gitlab-exporter | gitlab | HTTP 요청 처리율 / 지연 |
| gitlab-postgresql | gitlab | DB 커넥션 수 / 쿼리 성능 |
| gitlab-redis | gitlab | 메모리 사용량 / 커넥션 수 |
| gitlab-gitaly | gitlab | gRPC 요청 처리율 / 지연 |
| argocd (4개 컴포넌트) | argocd | 앱 Sync/Health 상태 / Reconciliation 지연 |

### 컴포넌트 역할

| 컴포넌트 | 역할 |
| :--- | :--- |
| **Prometheus** | 메트릭 수집 및 저장, 알림 룰 평가 |
| **Alertmanager** | 알림 수신 후 채널(이메일/Slack 등)로 발송 |
| **Grafana** | 수집된 메트릭 시각화 |
| **node-exporter** | 서버(노드) 자체 메트릭 수집 에이전트 |
| **kube-state-metrics** | K8s 오브젝트 상태 메트릭 수집 |

---

## 2. Grafana 접속

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
# http://localhost:3000
```

| 항목 | 기본값 |
| :--- | :--- |
| ID | `admin` |
| Password | `admin` |

---

## 3. 대시보드 활용 가이드

### 평소에 볼 대시보드 (3개)

#### Node Exporter / Nodes — 서버 자체 상태

**언제**: 서버가 느리다고 느껴질 때

| 패널 | 정상 기준 | 조치 |
| :--- | :--- | :--- |
| CPU Usage | 평균 80% 미만 | 과도한 파드 줄이기 |
| Memory Available | 여유 메모리 10% 이상 | 메모리 누수 파드 확인 |
| Disk Space Used% | 85% 미만 | 불필요한 이미지/로그 정리 |
| Network Receive/Transmit | 급격한 스파이크 없음 | 트래픽 폭증 원인 파악 |

#### Kubernetes / Compute Resources / Namespace (Pods) — 파드별 리소스

**언제**: 특정 서비스가 느리거나 OOMKilled 발생 시

상단 드롭다운에서 네임스페이스를 선택합니다 (gitlab, argocd, jenkins 등).

| 패널 | 확인 내용 |
| :--- | :--- |
| CPU Usage vs Request | Request 대비 실제 사용량 — 지속적으로 초과하면 limit 조정 필요 |
| Memory Usage vs Limit | Limit에 근접하면 OOMKill 위험 |

#### GitLab / Overview 또는 ArgoCD / Overview — 앱 상태

**언제**: 해당 서비스에 이상이 있을 때

GitLab 확인 항목:

- HTTP 5xx 상태코드 급증 → 장애 신호
- DB 커넥션 80개 초과 → 쿼리 병목 의심
- Redis 메모리 85% 초과 → 캐시 압박

ArgoCD 확인 항목:

- OutOfSync 앱 수 → 0이 정상
- Degraded 앱 수 → 0이 정상

---

### 장애 대응 순서

```text
서비스 이상 감지
    │
    ▼
Node Exporter / Nodes
서버 CPU / 메모리 / 디스크 포화?
    │ YES → 파드 스케일 다운 또는 서버 스펙 업
    │ NO
    ▼
Kubernetes / Compute Resources / Namespace
특정 파드 CPU / 메모리 폭주?
    │ YES → 해당 파드 로그 확인 (kubectl logs)
    │ NO
    ▼
GitLab / ArgoCD Overview
HTTP 에러율 상승 또는 앱 상태 이상?
    │ YES → 앱 레벨 로그 및 이벤트 확인
    │ NO
    ▼
Kubernetes / API server
API 응답 지연 또는 에러율 증가?
    │ YES → K8s 컴포넌트 상태 점검
```

---

### 나머지 대시보드 참조표

| 대시보드 | 보는 상황 |
| :--- | :--- |
| `Kubernetes / API server` | kubectl 명령이 느리거나 타임아웃 날 때 |
| `Kubernetes / Persistent Volumes` | PVC Pending 또는 디스크 관련 오류 |
| `CoreDNS` | 서비스 간 DNS 조회 실패 |
| `Alertmanager / Overview` | 발송된 알림 이력 확인 |
| `Kubernetes / Networking / *` | 네트워크 정책 또는 트래픽 이슈 |
| `etcd` | K8s 클러스터 상태 저장소 이상 시 |
| 나머지 `Kubernetes / *` | 심층 디버깅 시 참조 |

---

## 4. 알림(Alert) 설정

### 기본 내장 알림 룰 (145개, 자동 활성)

kube-prometheus-stack이 아래 항목을 자동으로 감시합니다.

| 카테고리 | 주요 알림 |
| :--- | :--- |
| 노드 | `NodeCPUHighUsage`, `NodeMemoryHighUtilization`, `NodeFilesystemAlmostOutOfSpace` |
| 파드 | `KubePodCrashLooping`, `KubePodNotReady`, `KubeContainerWaiting` |
| 디플로이먼트 | `KubeDeploymentReplicasMismatch`, `KubeDeploymentRolloutStuck` |
| PV / PVC | `KubePersistentVolumeFillingUp`, `KubePersistentVolumeErrors` |
| K8s 컴포넌트 | `KubeAPIDown`, `KubeSchedulerDown`, `KubeControllerManagerDown` |

### 커스텀 알림 룰 (`manifests/alertrules-custom.yaml`)

| 알림 이름 | 조건 | 심각도 |
| :--- | :--- | :--- |
| `ArgoCDAppOutOfSync` | 앱이 5분 이상 OutOfSync | warning |
| `ArgoCDAppDegraded` | 앱이 5분 이상 Degraded | critical |
| `ArgoCDAppMissing` | 앱 리소스가 2분 이상 Missing | critical |
| `GitLabHighHTTPErrorRate` | HTTP 5xx 에러율 5% 초과 5분 지속 | critical |
| `GitLabPostgresHighConnections` | DB 커넥션 80개 초과 | warning |
| `GitLabRedisHighMemory` | Redis 메모리 85% 초과 | warning |
| `GitLabGitalyHighLatency` | Gitaly p99 응답 지연 5초 초과 | warning |
| `NodeDiskWillFillIn4Hours` | 현재 추세로 4시간 내 디스크 포화 예측 | critical |

### 발화 중인 알림 확인

```bash
# Alertmanager UI 접속
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 -n monitoring
# http://localhost:9093

# CLI로 확인
kubectl exec -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager-0 \
  -- wget -qO- 'http://localhost:9093/api/v2/alerts?active=true' | python3 -m json.tool
```

### 알림 채널 연동 (Alertmanager 설정)

알림은 현재 `null` 수신자로 설정되어 있습니다 (알림이 발화되지만 발송하지 않음).
실제 발송을 원하면 `values.yaml`의 `alertmanager.config` 섹션을 수정합니다.

#### Slack 연동 예시

```yaml
# values.yaml 에 추가
alertmanager:
  config:
    global:
      slack_api_url: "https://hooks.slack.com/services/XXXX/YYYY/ZZZZ"
    route:
      receiver: slack-notifications
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
    receivers:
      - name: slack-notifications
        slack_configs:
          - channel: "#alerts"
            title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
            send_resolved: true
```

#### 이메일 연동 예시

```yaml
# values.yaml 에 추가
alertmanager:
  config:
    global:
      smtp_smarthost: "smtp.example.com:587"
      smtp_from: "alertmanager@example.com"
      smtp_auth_username: "user@example.com"
      smtp_auth_password: "password"
    route:
      receiver: email-notifications
    receivers:
      - name: email-notifications
        email_configs:
          - to: "admin@example.com"
            send_resolved: true
```

설정 후 적용:

```bash
helm upgrade prometheus ./charts/kube-prometheus-stack \
  --namespace monitoring \
  -f values.yaml \
  --wait
```

---

## 5. Prometheus 직접 쿼리

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring
# http://localhost:9090
```

유용한 즉시 쿼리 예시:

```promql
# 노드 CPU 사용률 (%)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 파드별 메모리 사용량 Top 10
topk(10, sum by (pod, namespace) (container_memory_working_set_bytes{container!=""}))

# ArgoCD 앱 상태 목록
argocd_app_info

# GitLab HTTP 에러율
sum(rate(gitlab_http_requests_total{status=~"5.."}[5m])) / sum(rate(gitlab_http_requests_total[5m]))
```

---

## 6. 데이터 보존 기간

Prometheus 기본 보존 기간은 **15일**입니다.
변경이 필요하면 `values.yaml`의 `prometheus.prometheusSpec.retention` 값을 수정합니다.

```yaml
prometheus:
  prometheusSpec:
    retention: 30d   # 30일 보존
```
