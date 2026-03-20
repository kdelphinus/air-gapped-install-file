# 🌐 MetalLB v0.14.8 (Bare-metal LoadBalancer)

폐쇄망 K8s 클러스터에서 `LoadBalancer` 타입의 서비스를 사용하기 위한 네트워크 로드밸런서입니다.

## 📦 구성 요소

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | MetalLB Helm 차트 (오프라인용) |
| `manifests/` | L2Advertisement 등 IP 대역 설정 리소스 |
| `images/` | 컨트롤러 및 스피커 이미지 `.tar` 및 `upload_images_to_harbor_v3-lite.sh` |
| `scripts/` | 이미지 로드 및 헬름 설치 자동화 스크립트 |

## 🛠️ 주요 설정 (변수화)

- **Registry**: `values.yaml` 내 `controller.image.repository` / `speaker.image.repository` (형식: `<NODE_IP>:30002/library/<name>`)
- **IP Range**: `manifests/l2-config.yaml` 내 `addresses` (기본: `192.168.1.200-250`)

## 💡 운영 팁

- **L2 Mode**: 가장 안정적이고 설정이 쉬운 ARP 기반의 계층 2 모드를 기본으로 사용합니다.
- **IP 대역**: 기존 호스트들과 충돌하지 않는 유휴 IP 대역을 할당해야 합니다.
