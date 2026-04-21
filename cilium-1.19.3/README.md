# Cilium 1.19.3 Air-Gapped Package

Cilium은 eBPF 기반의 오픈 소스 네트워킹, 보안 및 관측성을 제공하는 CNI(Container Network Interface)입니다. 본 패키지는 폐쇄망(Air-Gapped) 환경에서의 Cilium 1.19.3 설치를 위해 구성되었습니다.

## 🚀 주요 기능
- **eBPF 기반 네트워킹**: 고성능 L3/L4 네트워킹 및 부하 분산.
- **Hubble 가시성**: 네트워크 흐름 모니터링 및 보안 정책 시각화 (선택 설치 가능).
- **Kube-proxy 대체**: eBPF를 이용한 효율적인 서비스 라우팅.
- **보안 정책**: 레이블 기반의 세밀한 네트워크 접근 제어.

## 📁 디렉토리 구조
```text
cilium-1.19.3/
├── charts/             # Cilium 1.19.3 Helm Chart
├── images/             # Cilium 및 Hubble 관련 컨테이너 이미지 (.tar)
├── manifests/          # 추가 설정을 위한 K8s 리소스 (HTTPRoute 등)
├── scripts/
│   ├── install.sh      # 대화형 설치 스크립트 (Upgrade/Reinstall/Reset)
│   └── uninstall.sh    # 리소스 및 호스트 잔재 완전 삭제 스크립트
├── values.yaml         # 운영(Harbor) 환경용 설정
├── values-local.yaml   # 로컬 환경용 설정
├── README.md           # 서비스 설명서
└── install-guide.md    # 단계별 설치 가이드
```

## 🔌 주요 포트 사용 현황 (Host Port)
Cilium은 클러스터 안정성을 위해 아래의 호스트 포트를 점유합니다.
| 포트 번호 | 프로토콜 | 컴포넌트 | 용도 |
| :--- | :--- | :--- | :--- |
| **9234** | TCP | Operator | Health Check (Liveness/Readiness) |
| **9963** | TCP | Operator | Prometheus Metrics |
| **4240** | TCP | Agent | Cluster-wide Health Check |
| **4244** | TCP | Agent | Hubble Server (Intra-cluster) |
| **9876** | TCP | Agent | Agent API (Local) |
| **9890** | TCP | Agent | Agent Metrics |

## 📋 요구 사항
- **Kubernetes**: v1.16+ (본 패키지는 v1.30 대응 기준)
- **Kernel**: 4.19+ (eBPF 기능을 위해 5.4+ 권장)
- **Helm**: v3.x 이상

## 🛠 설치 요약
1. `images/` 내의 이미지를 Harbor에 업로드하거나 노드에 Import합니다.
2. `scripts/install.sh`를 실행하여 설치를 진행합니다.
3. 삭제가 필요한 경우 `scripts/uninstall.sh`를 사용합니다.

자세한 내용은 [install-guide.md](./install-guide.md)를 참조하세요.
