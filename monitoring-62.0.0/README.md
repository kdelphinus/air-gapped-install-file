# 📊 Monitoring (kube-prometheus-stack v62.0.0)

K8s 클러스터 전반의 지표 수집(Prometheus) 및 시각화(Grafana)를 위한 통합 모니터링 도구입니다.

## 📦 구성 요소

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | Prometheus & Grafana 통합 Helm 차트 |
| `manifests/` | 대시보드 추가 설정 및 수동 PVC 리소스 |
| `images/` | 오프라인 이미지 저장소 (Prometheus, Grafana, Node-Exporter 등) |
| `scripts/` | 오프라인 이미지 로드 스크립트 |

## 🛠️ 주요 설정 (변수화)

### 1. Registry (Harbor)
- `values.yaml` 내 `global.imageRegistry`

### 2. Storage Strategy (NFS vs HostPath)
- **NFS (기본)**: `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate` 활용.
- **HostPath**: `prometheus.prometheusSpec.persistence.enabled: true` 및 별도 `hostpath`용 StorageClass 필요.

## 💡 운영 팁

- **지속성**: Prometheus 데이터는 기본 15일 보관하도록 설정되어 있습니다. (용량 주의)
- **Node-Exporter**: 모든 노드에 설치되어 CPU/Memory 등의 하드웨어 지표를 수집합니다.
