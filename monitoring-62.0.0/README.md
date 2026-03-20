# 📊 Monitoring (kube-prometheus-stack v62.0.0)

K8s 클러스터 전반의 지표 수집(Prometheus) 및 시각화(Grafana)를 위한 통합 모니터링 도구입니다.

## 📦 구성 요소

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | Prometheus & Grafana 통합 Helm 차트 |
| `images/` | 오프라인 이미지 저장소 (총 11개 `.tar`) 및 `upload_images_to_harbor_v3-lite.sh` |
| `scripts/` | 에셋 다운로드 스크립트 |

### images/ 목록

| 파일명 | 컴포넌트 |
| :--- | :--- |
| `quay.io-prometheus-prometheus-v2.54.1.tar` | Prometheus |
| `quay.io-prometheus-alertmanager-v0.27.0.tar` | Alertmanager |
| `quay.io-prometheus-operator-prometheus-operator-v0.76.1.tar` | Prometheus Operator |
| `quay.io-prometheus-operator-prometheus-config-reloader-v0.76.1.tar` | Config Reloader |
| `registry.k8s.io-ingress-nginx-kube-webhook-certgen-v20221220-controller-v1.5.1-58-g787ea74b6.tar` | Webhook Certgen (admission webhook) |
| `grafana-grafana-11.1.0.tar` | Grafana |
| `quay.io-kiwigrid-k8s-sidecar-1.27.4.tar` | Grafana Sidecar |
| `library-busybox-1.31.1.tar` | Grafana initChownData |
| `quay.io-prometheus-node-exporter-v1.8.2.tar` | Node Exporter |
| `registry.k8s.io-kube-state-metrics-kube-state-metrics-v2.13.0.tar` | kube-state-metrics |
| `registry.k8s.io-prometheus-adapter-prometheus-adapter-v0.12.0.tar` | Prometheus Adapter |

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
