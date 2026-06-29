# Kubernetes Offline Builder

Kubernetes 버전과 OS 버전을 고정하지 않고, 온라인 호스트에서 폐쇄망 설치 번들을 생성하기 위한 빌더 컴포넌트입니다.

기존 `k8s-<version>-<os>/` 디렉터리는 실제 설치 산출물로 유지하고, 이 디렉터리는 해당 산출물을 생성하는 공통 수집기/생성기 역할을 합니다.

## 목표

- Kubernetes patch 버전(`v1.33.11` 등)을 입력받아 minor repo(`v1.33`)를 자동 계산합니다.
- Ubuntu 24.04와 Rocky Linux 9.6을 1차 지원 대상으로 둡니다.
- 온라인 호스트에서 DEB/RPM, 바이너리, 매니페스트, 컨테이너 이미지를 수집합니다.
- 수집 결과를 `bundles/k8s-<version>-<os>/` 하위에 버전 고정 산출물로 생성합니다.
- 폐쇄망 노드는 생성된 번들 안의 `scripts/install.sh`만 사용합니다.

## 현재 범위

이 단계는 Ubuntu 24.04와 Rocky Linux 9.6 기준 수집/번들 생성의 초기 구현입니다.

- 공통 설정 파일: `install.conf`
- 예시 설정 템플릿: `templates/install.conf.example`
- 스크립트 진입점:
  - `scripts/download_assets_offline.sh`
  - `scripts/build_bundle.sh`
  - `scripts/install.sh`
  - `scripts/uninstall.sh`
- 공통 검증 함수: `scripts/lib/common.sh`
- 호환성 정책 seed: `manifests/compatibility.yaml`
- 번들 내부 스크립트 템플릿: `templates/scripts/`
- 산출물 루트: `bundles/`

현재 `download_assets_offline.sh`는 Ubuntu 24.04 기준 DEB, Rocky 9.6 기준 RPM, 공통 바이너리, 매니페스트, Helm chart, Kubernetes core image, Calico/Cilium image를 수집합니다.
`build_bundle.sh`는 staging 디렉터리에 수집 자산, 번들 스크립트, 설정을 배치하고 tar.gz 파일을 생성합니다.

번들 내부 `scripts/install.sh`는 Ubuntu 24.04 또는 Rocky 9.6 + containerd + Calico/Cilium 조합의 kubeadm init/join 설치를 수행합니다.

## 기본 사용 흐름

```bash
cd k8s-offline-builder

# 1. 설정 확인 및 수정
vi install.conf

# 2. 온라인 호스트에서 설치 자산 수집
sudo ./scripts/download_assets_offline.sh

# 3. 폐쇄망 전달용 번들 생성
./scripts/build_bundle.sh

# 4. 생성된 bundles/k8s-<version>-<os>.tar.gz 를 폐쇄망으로 전달
```

## 디렉터리 구조

```text
k8s-offline-builder/
├── charts/                 # 향후 Helm chart 캐시 또는 검증용 산출물
├── images/                 # 빌더 자체가 관리하는 공통 이미지 캐시
├── manifests/              # 공통 매니페스트 템플릿 또는 검증용 파일
├── bundles/                # 생성된 버전 고정 오프라인 번들
├── scripts/                # 빌더 실행 스크립트
├── templates/              # 설정 및 번들 파일 템플릿
├── install.conf            # 기본 빌드 설정
├── values.yaml             # 빌더 기본값 요약
├── README.md
└── install-guide.md
```

## 설계 원칙

- 온라인 수집과 오프라인 설치를 분리합니다.
- 생성된 번들은 항상 버전과 OS가 이름에 드러나야 합니다.
- 스크립트는 컴포넌트 루트 기준으로 실행되도록 `cd "$(dirname "$0")/.."` 패턴을 사용합니다.
- 외부 네트워크 접근은 `download_assets_offline.sh` 단계에만 존재해야 합니다.
- Rocky 9.6에서는 Kubernetes 1.33 호환성을 위해 `CONTAINERD_VERSION=auto`를 `2.1.*` 라인으로 정규화합니다.
- 노드에 IP가 여러 개 있으면 생성된 번들의 `install.conf`에서 `KUBELET_NODE_IP`를 노드별로 지정합니다.

## 호환성 체크 방향

빌더는 다음 두 단계로 호환성을 확인합니다.

1. **형식/지원 범위 검증**: `scripts/lib/common.sh`에서 `K8S_VERSION`, `TARGET_OS`, `CNI_CHOICE`, `CALICO_INSTALL_METHOD` 같은 입력값을 먼저 검증합니다.
2. **검증된 조합 정책**: `manifests/compatibility.yaml`에 공식 문서로 확인한 Kubernetes/containerd/CNI 조합만 기록하고, 다운로드/번들 생성 전에 이 정책과 대조합니다.

현재 정책은 `policy.validatedTuples`에 명시된 조합만 허용하는 strict 방식입니다.
새 Kubernetes minor 또는 CNI 버전을 추가하려면 공식 문서와 실환경 검증 결과를 확인한 뒤 정책 파일에 해당 조합을 추가합니다.

## 재현성 검증

기존 고정 산출물 `k8s-1.33.11-ubuntu24.04`와 builder 생성 번들의 기능 비교는 `docs/reproducibility-check-k8s-1.33.11-ubuntu24.04.md`를 참고합니다.
