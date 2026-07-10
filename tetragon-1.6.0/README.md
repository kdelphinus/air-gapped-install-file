# Tetragon 1.6.0 (Runtime Security Enforcement)

eBPF 기반의 오픈소스 런타임 보안 도구인 Tetragon을 폐쇄망 환경에 배포하기 위한 패키지입니다.

---

## 📌 개요

Tetragon은 커널 레벨에서 프로세스·파일·네트워크 이벤트를 실시간으로 감시하고, `TracingPolicy` CRD를 통해 특정 동작을 **즉시 차단(Sigkill)** 할 수 있습니다. Falco가 감지(Detection) 역할이라면, Tetragon은 차단(Enforcement) 역할을 담당합니다.

- **Helm Chart:** 1.6.0
- **Tetragon Engine:** 1.6.0
- **Tetragon Operator:** 1.6.0
- **Hubble Export Stdout:** 1.1.0
- **설치 네임스페이스:** `kube-system`
- **커널 요구사항:** 5.10+ (BTF 지원 필수)

---

## 📂 디렉토리 구조

```text
tetragon-1.6.0/
├── charts/          # Tetragon Helm Chart (v1.6.0)
├── images/          # 오프라인 이미지(.tar) 및 Harbor 업로드 스크립트
├── manifests/       # TracingPolicy 예시 (block-sensitive-read.yaml)
├── scripts/         # 설치, 제거 및 에셋 다운로드 스크립트
├── values.yaml      # 표준 K8s용 배포 기본 설정
├── README.md        # 서비스 사양 및 구조 설명 (본 파일)
└── install-guide.md # 단계별 설치 및 차단 테스트 가이드
```

---

## 🛠️ 주요 설정 및 특이사항

### 1. TracingPolicy — 차단 정책
Tetragon은 기본 차단 정책이 없습니다. 차단 동작은 `TracingPolicy` CRD로 정의하며, `kubectl apply -f`로 즉시 적용되고 재시작이 필요 없습니다.
`manifests/block-sensitive-read.yaml`은 `/etc/shadow` 읽기를 차단하는 **테스트용 예시**입니다. 실 운영 시에는 환경에 맞는 정책으로 교체하세요.

### 2. BTF 지원 필수
Tetragon은 커널 BTF(BPF Type Format)를 사용합니다. 설치 전 반드시 확인합니다.
```bash
ls /sys/kernel/btf/vmlinux   # 존재해야 함
```
BTF 미지원 환경에서는 Tetragon 파드가 구동되지 않습니다.

### 3. 이미지 구성 및 에어갭 완결성
폐쇄망 자립 배포를 위해 3가지 필수 이미지를 수집 및 로드합니다.
* `quay.io/cilium/tetragon:v1.6.0` - Tetragon 메인 에이전트 (DaemonSet)
* `quay.io/cilium/tetragon-operator:v1.6.0` - CRD 관리 및 정책 동기화
* `quay.io/cilium/hubble-export-stdout:v1.1.0` - Hubble 로그 stdout export sidecar

인프라 가변 정보는 `install.conf` 와 `values-infra.yaml` 을 활용하여 관리하므로, 원본 설정인 `values.yaml` 의 원형이 그대로 보존됩니다.

---

## 🚀 시작하기

상세한 설치 및 차단 테스트 방법은 **[install-guide.md](./install-guide.md)**를 참조하세요.

1. **에셋 준비:** `./scripts/download_assets_offline.sh` (외부망)
2. **이미지 업로드:** `./images/upload_images_to_harbor_v3-lite.sh` (폐쇄망)
3. **설치 실행:** `./scripts/install.sh` (폐쇄망)
