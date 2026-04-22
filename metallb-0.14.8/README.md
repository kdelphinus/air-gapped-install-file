# 🌐 MetalLB v0.14.8 (Bare-metal LoadBalancer)

폐쇄망 K8s 클러스터에서 `LoadBalancer` 타입의 서비스를 사용하기 위한 네트워크 로드밸런서입니다.

## 📦 구성 요소

| 경로 | 설명 |
| :--- | :--- |
| `charts/` | MetalLB Helm 차트 (오프라인용) |
| `manifests/` | L2Advertisement 등 IP 대역 설정 리소스 |
| `images/` | 컨트롤러 및 스피커 이미지 `.tar` 및 `upload_images_to_harbor_v3-lite.sh` |
| `scripts/` | 이미지 로드 및 헬름 설치 자동화 스크립트 |

## 🚀 설치

```bash
sudo ./scripts/install.sh
```

- 이미지 소스(Harbor / 로컬 ctr), IP 풀 범위를 대화형으로 입력받아 설정을 `install.conf` 에 저장합니다.
- 기존 설치가 감지되면 **1) 업그레이드 / 2) 재설치 / 3) 초기화 / 4) 취소** 메뉴를 제공합니다.
- 상세 절차 및 수동 설치(`Manual Installation & Upgrade`)는 [install-guide.md](./install-guide.md) 참고.

## 🛠️ 주요 설정 (변수화)

- **Registry**: `values.yaml` 내 `controller.image.repository` / `speaker.image.repository` (형식: `<NODE_IP>:30002/library/<name>`)
- **IP Range**: `manifests/l2-config.yaml` 내 `addresses` (install.sh 가 자동 치환)

## 💡 운영 팁

- **L2 Mode**: 가장 안정적이고 설정이 쉬운 ARP 기반의 계층 2 모드를 기본으로 사용합니다.
- **IP 대역**: 기존 호스트들과 충돌하지 않는 유휴 IP 대역을 할당해야 합니다.
