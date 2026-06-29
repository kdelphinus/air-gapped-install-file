# Kubernetes Offline Builder 설치 및 사용 가이드

이 문서는 Kubernetes 오프라인 설치 번들을 생성하기 위한 빌더 사용 절차입니다.

## 1. 전제 조건

- 온라인 Ubuntu 24.04 또는 Rocky Linux 9.6 호스트
- root 또는 sudo 권한
- 인터넷 접근 가능
- `curl`, `tar`, `bash`, `apt-get` 사용 가능

> Rocky/RHEL 계열은 현재 `rocky9.6`을 1차 검증 대상으로 지원합니다.

## 2. 설정 파일

기본 설정은 `install.conf`에 저장합니다.

```bash
cd k8s-offline-builder
vi install.conf
```

주요 항목:

| 항목 | 설명 |
| --- | --- |
| `K8S_VERSION` | 생성할 Kubernetes patch 버전 |
| `TARGET_OS` | 대상 OS 식별자 |
| `CONTAINER_RUNTIME` | 컨테이너 런타임 |
| `CONTAINERD_VERSION` | containerd 버전 정책. Ubuntu는 `auto`, Rocky 9.6은 `auto` 입력 시 `2.1.*`로 정규화 |
| `CNI_CHOICE` | CNI 선택값 |
| `CALICO_VERSION` | Calico 버전 |
| `CALICO_INSTALL_METHOD` | `manifest` 또는 `operator` |
| `CILIUM_VERSION` | Cilium 버전 |
| `ENABLE_HUBBLE` | Cilium Hubble 활성화 여부 |
| `MTU_VALUE` | Cilium 설치 시 적용할 MTU |
| `BUNDLE_OUTPUT_DIR` | 생성 산출물 루트 |

## 3. 온라인 수집

```bash
sudo ./scripts/download_assets_offline.sh
```

이 단계는 다음 작업을 수행합니다.

- Kubernetes minor repo 자동 계산
- kubeadm/kubelet/kubectl 패키지와 의존성 수집
- containerd 패키지 수집. Rocky 9.6은 Kubernetes 1.33 호환성 기준으로 `containerd.io-2.1.*` 라인을 사용합니다.
- kubeadm 기준 core image 목록 생성 및 export
- CNI 매니페스트, Helm chart, 이미지 수집
- 번들 생성용 staging 디렉터리 구성

현재 구현은 Ubuntu 24.04와 Rocky Linux 9.6 기준으로 실제 수집을 수행합니다. 외부 네트워크와 APT/DNF repo 등록이 필요하므로 `sudo`로 실행합니다.

### 설정값 검증

`scripts/download_assets_offline.sh`와 `scripts/build_bundle.sh`는 공통 함수 파일 `scripts/lib/common.sh`를 통해 다음 항목을 먼저 검증합니다.

- `K8S_VERSION`: `v1.33.11` 형식. `1.33.11`처럼 `v`를 생략하면 자동으로 `v1.33.11`로 보정합니다.
- `TARGET_OS`: 현재 `ubuntu24.04` 또는 `rocky9.6`을 허용합니다.
- `ARCH`: 현재 `amd64`만 허용합니다.
- `CONTAINER_RUNTIME`: 현재 `containerd`만 허용합니다.
- `CNI_CHOICE`: `calico` 또는 `cilium`
- `CALICO_INSTALL_METHOD`: `manifest` 또는 `operator`

### 호환성 정책 검증

컴포넌트 간 버전 호환성은 `manifests/compatibility.yaml`에 기록합니다. 이 파일은 자동 생성 결과가 아니라, 공식 문서와 실제 검증 결과를 반영하는 내부 정책 파일입니다.

체크 기준:

- Kubernetes 핵심 컴포넌트: Kubernetes Version Skew Policy 기준
- containerd: Kubernetes CRI 요구사항과 containerd 릴리스 지원 범위 기준
- Calico: Tigera/Calico의 Kubernetes 지원 범위 기준
- Cilium: Cilium의 Kubernetes compatibility matrix 기준

`download_assets_offline.sh`와 `build_bundle.sh`는 실제 수집/생성 전에 다음 값을 정책 파일과 대조합니다.

- Kubernetes minor 버전
- 대상 OS와 아키텍처
- container runtime과 containerd 버전 정책
- CNI 종류, CNI 버전, 설치 방식
- `policy.validatedTuples`에 명시된 전체 조합

정책에 없는 조합은 네트워크 수집을 시작하기 전에 오류로 중단됩니다.

## 4. 번들 생성

```bash
./scripts/build_bundle.sh
```

예상 산출물:

```text
bundles/k8s-v1.33.11-ubuntu24.04/
bundles/k8s-v1.33.11-ubuntu24.04.tar.gz
bundles/k8s-v1.33.11-rocky9.6/
bundles/k8s-v1.33.11-rocky9.6.tar.gz
```

`build_bundle.sh`는 staging 디렉터리를 만들고, 수집된 자산, 번들 내부용 스크립트와 `install.conf`를 배치한 뒤 tar.gz 아카이브를 생성합니다.

```bash
./scripts/build_bundle.sh --dry-run  # 경로만 확인
./scripts/build_bundle.sh            # staging 생성 + tar.gz 생성
```

## 5. 폐쇄망 설치

생성된 번들 내부의 `scripts/install.sh`가 실제 폐쇄망 노드에서 실행될 설치 스크립트입니다.
실제 클러스터 설치 전에는 생성된 버전 고정 번들의 `install-guide.md`에 있는 설치 전 체크리스트를 먼저 확인합니다.

빌더 루트의 `scripts/install.sh`는 실수로 빌더 자체를 설치 대상으로 사용하는 것을 막기 위한 안내용 진입점입니다.

현재 번들 설치 지원 범위:

- Ubuntu 24.04
- Rocky Linux 9.6
- containerd
- kubeadm 기반 control-plane init
- worker/control-plane join
- Calico manifest 설치
- Calico Tigera operator 설치
- Cilium Helm chart 설치
- WSL2 사전 설정 보조 스크립트

Cilium 선택 시 kube-proxy phase를 건너뛰고 Cilium의 `kubeProxyReplacement=true` 설정으로 설치합니다.

## 6. Manual Installation & Upgrade

이 빌더는 Kubernetes 번들을 생성하는 도구이므로 직접 `helm upgrade --install`이나 `kubectl apply`로 배포되는 서비스가 아닙니다.

수동 절차는 생성된 버전 고정 번들의 `install-guide.md`를 따릅니다. 빌더 자체에서 수동으로 확인할 항목은 다음과 같습니다.

```bash
# 설정 로드 가능 여부 확인
bash -n scripts/download_assets_offline.sh
bash -n scripts/build_bundle.sh

# 생성 대상 이름 확인
./scripts/build_bundle.sh --dry-run
```

## 7. 다음 구현 단계

1. Rocky 9.6 실환경 RPM 수집/설치 스모크 테스트
2. 기존 `k8s-1.33.11-ubuntu24.04` 산출물 재현 검증
