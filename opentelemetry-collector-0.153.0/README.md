# 📝 OpenTelemetry Collector Infrastructure Specification

본 문서는 **OpenTelemetry Collector v0.153.0** 및 **Helm Chart v0.158.0**을 기반으로 구축된 클러스터 상태/분산 추적/로그 수집 시스템 명세를 정의합니다.

## 1. 시스템 버전 정보 (Version Specification)

폐쇄망 환경의 관측 가능성(Observability) 및 표준 준수를 위해 다음 버전이 적용되었습니다.

| 항목 | 버전 | 비고 |
| --- | --- | --- |
| **OpenTelemetry Collector** | **v0.153.0** | 수집기 엔진 (Contrib 번들 탑재로 모든 Receiver/Exporter 기본 사용 가능) |
| **Helm Chart** | **v0.158.0** | open-telemetry/opentelemetry-collector 공식 헬름 차트 |
| **K8s 호환성** | **v1.24 이상** | 표준 Kubernetes API 기반 동작 |

---

## 2. 시스템 아키텍처 및 역할 (Architecture)

OpenTelemetry Collector는 애플리케이션 및 인프라의 관측 데이터(Trace, Metric, Log)를 수집, 가공, 내보내기 하는 중앙 중개 에이전트 역할을 합니다.

### 🔹 Receivers (수신 규격)
* **OTLP Receiver**: 분산 추적 및 애플리케이션 메트릭의 범용 프로토콜 (gRPC: `4317`, HTTP: `4318`).
* **Prometheus Receiver**: 수집기 자체 메트릭 및 Prometheus 엔드포인트 스크래핑.
* **Host Metrics Receiver**: CPU, 메모리, 디스크, 네트워크, 파일시스템 상태 수집 (DaemonSet 모드 전용).

### 🔹 Processors (가공 및 제어)
* **Memory Limiter**: 과도한 메트릭 주입으로 인한 OOMKilled 장애 방지 (Memory Limit의 80% 상한 제어).
* **Batch**: 대량의 메트릭 데이터를 버퍼링하여 일괄 전송함으로써 네트워크 대역폭 및 성능 극대화.

### 🔹 Exporters (송신 규격)
* **Prometheus Exporter**: 수집된 메트릭을 Prometheus가 수집해 갈 수 있도록 엔드포인트(`8889`) 노출.
* **Debug Exporter**: 수집기 파드 로그에서 텔레메트리 전송 현황 디버깅 제공.

---

## 3. 리소스 명세 및 네트워크 (Resources & Networking)

### 🔹 서비스 포트 맵핑 (Service Ports)

| 프로토콜 | 포트 번호 | 타입 | 용도 |
| --- | --- | --- | --- |
| **OTLP gRPC** | **4317** | TCP | 애플리케이션 분산 추적(Tracing) 및 OTLP 메트릭 수신 |
| **OTLP HTTP** | **4318** | TCP | 웹 애플리케이션 및 브라우저 OTLP 수신 |
| **Prometheus Exporter** | **8889** | TCP | Prometheus Server 연동 메트릭 조회 엔드포인트 |
| **Health Check** | **13133** | TCP | K8s Liveness/Readiness 프로브 헬스체크 |
| **Collector Metrics** | **8888** | TCP | 수집기 내부 자체 성능 지표 엔드포인트 |

---

## 4. 배포 모드 선택 (Deployment Type)

설치 스크립트 실행 시 인프라 구조와 목적에 맞게 배포 방식을 분기하여 구성할 수 있습니다.

| 항목 | DaemonSet 모드 (기본값) | Deployment 모드 |
| --- | --- | --- |
| **주 목적** | 노드별 하드웨어 정보 및 인프라 로그 수집 | 애플리케이션 분산 추적(Tracing) 중앙 집계 서버 |
| **자원 할당** | 모든 워커 노드에 1개씩 강제 배포 | Replica 수 지정을 통한 중앙 집중 분산 배포 |
| **실IP 보존** | 수집 에이전트와 노드 매칭으로 자동 보존 | 서비스 프록시 거쳐 전달되므로 OTLP 헤더 기반 추적 필요 |
| **권장 대상** | Kubernetes 전 영역 클러스터 모니터링 에이전트 | MSA 서비스 간 대용량 트레이스 수집 전용 |

---

## 5. 폐쇄망 운영 가이드 (Operational Guide)

### ✅ 에이전트 상태 진단
설치된 OpenTelemetry Collector의 작동 여부 및 트래픽 유입 상태는 다음과 같이 수집기 파드 로그에서 검증할 수 있습니다.

```bash
# 수집기 파드 로그 확인 (Debug Exporter가 활성화되어 있어 수신 현황이 매초 로그에 나타남)
kubectl logs -f -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
```

### ✅ Prometheus 연동 절차
Prometheus(`monitoring` 네임스페이스)가 OTel Collector에서 내보내는 메트릭을 가져갈 수 있도록, Prometheus 스크랩 대상(Scrape Config) 또는 `PodMonitor`/`ServiceMonitor` 리소스를 배포하십시오. 기본 Exporter 포트는 `8889`입니다.

---

## 6. OpenTelemetry Operator와의 연동 가이드 (Operator Integration)

본 컴포넌트는 헬름으로 배포되어 독립적으로 동작하는 독립형(Standalone) 모드의 OTel Collector입니다. K8s 클러스터 내에 **OpenTelemetry Operator**를 도입하여 연동할 경우 다음과 같은 표준 아키텍처 패턴을 구성할 수 있습니다.

### 🔹 중앙 게이트웨이 패턴 (Centralized Gateway Pattern)
* **역할 분담**:
  * **OTel Operator**: 애플리케이션 파드에 SDK 에이전트를 자동 주입(Auto-injection)하는 목적으로만 사용합니다.
  * **본 컴포넌트 (OTel Collector)**: 수집된 모든 트레이스/메트릭/로그 데이터를 중앙에서 가공, 버퍼링 및 내보내기(Export)하는 **중앙 집중식 게이트웨이(Gateway)**로 활용합니다.
* **이점**: 애플리케이션 노드들의 개별 에이전트 성능 부하를 최소화하고, 수집 정책(Filtering, Batching, Redaction)을 본 컴포넌트의 `values.yaml` 한 곳에서 일괄 통제할 수 있습니다.

### 🔹 오퍼레이터 자동 주입 설정 (Instrumentation CR)
Operator가 설치된 클러스터에서 애플리케이션 파드에 에이전트를 자동 주입하기 위해 다음과 같은 `Instrumentation` 리소스를 배포하고, 전송 대상 엔드포인트를 본 컴포넌트의 서비스로 주입합니다.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: devops-instrumentation
  namespace: monitoring
spec:
  exporter:
    # 본 컴포넌트의 OTLP gRPC 수신 서비스 주소로 지정
    endpoint: http://otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317
  propagators:
    - tracecontext
    - baggage
    - b3
  sampler:
    type: parentbased_always_on
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:1.32.0
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.48.0
```

애플리케이션 배포 시 Pod 템플릿의 metadata에 아래 어노테이션을 설정하면 지정된 버전의 모니터링 에이전트가 자동 구성되어 게이트웨이로 텔레메트리를 송신합니다.
```yaml
annotations:
  instrumentation.opentelemetry.io/inject-java: "true"
```

