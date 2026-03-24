# Falco 8.0.1 (Intrusion Detection System)

eBPF 기반의 오픈소스 컨테이너 런타임 보안 도구인 Falco를 폐쇄망 환경에 배포하기 위한 패키지입니다.

## 📌 개요

Falco는 커널 이벤트를 실시간으로 감시하여 컨테이너 및 호스트의 이상행위를 감지하고 알림을 생성합니다. 본 패키지는 **WSL2/K3s 환경** 및 **표준 K8s** 모두에서 안정적으로 동작하도록 최적화되어 있습니다.

- **Helm Chart:** 8.0.1
- **Falco Engine:** 0.43.0 (API 3.10.0 호환)
- **FalcoSidekick:** 2.29.0
- **Driver Kind:** Modern eBPF (Kernel 5.8+ 권장)

## 📂 디렉토리 구조

```text
falco-8.0.1/
├── charts/          # Falco Helm Chart (v8.0.1)
├── images/          # 오프라인 이미지(.tar) 및 Harbor 업로드 스크립트
├── manifests/       # 보안 위협 탐지 테스트용 K8s 매니페스트
├── scripts/         # 설치, 제거 및 에셋 다운로드 스크립트
├── values.yaml      # 표준 K8s용 배포 설정 (Harbor 기준)
├── values-local.yaml# 로컬 K3s 테스트용 설정 (Docker Hub 기준)
├── README.md        # 서비스 사양 및 구조 설명 (본 파일)
└── install-guide.md # 단계별 설치 및 실습 가이드
```

## 🛠️ 주요 설정 및 특이사항

### 1. 엔진 버전 호환성

Chart 8.0.1은 **Falco 엔진 0.43.0** 이상을 필요로 합니다. 하위 버전(예: 0.38.0) 사용 시 플러그인 API 버전 불일치로 구동되지 않으므로 주의가 필요합니다.

### 2. K3s 전용 설정

K3s 환경에서 컨테이너 메타데이터를 수집하기 위해 다음 소켓 경로를 사용합니다.

- `/run/k3s/containerd/containerd.sock`

본 패키지의 `scripts/install.sh`는 이 경로를 자동으로 감지하여 적용합니다.

### 3. 폐쇄망 최적화

- `falcoctl`의 외부 아티팩트(Rule/Plugin) 다운로드 기능을 비활성화했습니다.
- 모든 필수 규칙은 차트에 포함된 기본 규칙을 사용하며, 추가 규칙은 `manifests/`에 정의할 수 있습니다.

### 4. WSL2 커널 파라미터

WSL2에서 구동 시 `inotify` 리소스 부족으로 에러가 발생할 수 있습니다. 설치 전 다음 명령어로 확장이 필요합니다.

```bash
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=1048576
```

## 🚀 시작하기

상세한 설치 및 테스트 방법은 **[install-guide.md](./install-guide.md)**를 참조하세요.

1. **에셋 준비:** `./scripts/download_assets_offline.sh` (외부망)
2. **이미지 업로드:** `./images/upload_images_to_harbor_v3-lite.sh` (폐쇄망)
3. **설치 실행:** `./scripts/install.sh` (폐쇄망)
