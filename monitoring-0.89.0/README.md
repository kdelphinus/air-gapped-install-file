# 📊 Monitoring (kube-prometheus-stack v82.12.0)

K8s 클러스터 전반의 지표 수집(Prometheus) 및 시각화(Grafana)를 위한 통합 모니터링 도구입니다.

## 📦 구성 요소

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | Prometheus & Grafana 통합 Helm 차트 (v82.12.0) |
| `images/` | 오프라인 이미지 저장소 (총 11개 `.tar`) 및 `upload_images_to_harbor_v3-lite.sh` |
| `scripts/` | 에셋 다운로드 및 설치 스크립트 |

### images/ 목록 (v82.12.0 기준)

| 파일명 | 컴포넌트 | 버전 |
| :--- | :--- | :--- |
| `quay.io-prometheus-prometheus-v3.10.0.tar` | Prometheus | v3.10.0 |
| `quay.io-prometheus-alertmanager-v0.31.1.tar` | Alertmanager | v0.31.1 |
| `quay.io-prometheus-operator-prometheus-operator-v0.89.0.tar` | Prometheus Operator | v0.89.0 |
| `quay.io-prometheus-operator-prometheus-config-reloader-v0.89.0.tar` | Config Reloader | v0.89.0 |
| `ghcr.io-jkroepke-kube-webhook-certgen-1.7.8.tar` | Webhook Certgen | 1.7.8 |
| `docker.io-grafana-grafana-11.3.3.tar` | Grafana | 11.3.3 |
| `quay.io-kiwigrid-k8s-sidecar-2.5.0.tar` | Grafana Sidecar | 2.5.0 |
| `docker.io-library-busybox-1.37.0.tar` | Grafana initChownData | 1.37.0 |
| `quay.io-prometheus-node-exporter-v1.10.2.tar` | Node Exporter | v1.10.2 |
| `registry.k8s.io-kube-state-metrics-kube-state-metrics-v2.18.0.tar` | kube-state-metrics | v2.18.0 |

## 🛠️ 주요 설정 (변수화)

### 1. Registry (Harbor)

- `values.yaml` 내 `global.imageRegistry: "<NODE_IP>:30002"` 로 레지스트리를 지정합니다.
- 모든 `image.repository` 는 `library/<name>` 형태로 설정됩니다.
  `upload_images_to_harbor_v3-lite.sh` 가 이미지 경로의 마지막 세그먼트만 사용하여
  `<NODE_IP>:30002/library/<name>:<tag>` 로 업로드하기 때문입니다.

### 2. Storage Strategy (NFS vs HostPath)

- **NFS (기본)**: `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate` 활용.
- **HostPath**: `prometheus.prometheusSpec.persistence.enabled: true` 및 별도 `hostpath`용 StorageClass 필요.

## 💡 운영 팁

- **지속성**: Prometheus 데이터는 기본 15일 보관하도록 설정되어 있습니다. (용량 주의)
- **Node-Exporter**: 모든 노드에 설치되어 CPU/Memory 등의 하드웨어 지표를 수집합니다.
