# Kubernetes Offline Builder 설치 및 사용 가이드

이 문서는 Kubernetes 오프라인 설치 번들을 생성하기 위한 빌더 사용 절차입니다.

## 1. 전제 조건

- 온라인 Ubuntu 24.04 호스트
- root 또는 sudo 권한
- 인터넷 접근 가능
- `curl`, `tar`, `bash`, `apt-get` 사용 가능

> Rocky/RHEL 계열 지원은 다음 단계에서 추가합니다.

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
| `CNI_CHOICE` | CNI 선택값 |
| `CALICO_VERSION` | Calico 버전 |
| `CALICO_INSTALL_METHOD` | `manifest` 또는 `operator` |
| `BUNDLE_OUTPUT_DIR` | 생성 산출물 루트 |

## 3. 온라인 수집

```bash
sudo ./scripts/download.sh
```

이 단계는 향후 다음 작업을 수행합니다.

- Kubernetes minor repo 자동 계산
- kubeadm/kubelet/kubectl 패키지와 의존성 수집
- containerd 패키지 수집
- kubeadm 기준 core image 목록 생성 및 export
- CNI 매니페스트와 이미지 수집
- 번들 생성용 staging 디렉터리 구성

현재 1차 골격 단계에서는 설정값 검증과 실행 계획 출력까지만 수행합니다.

### 설정값 검증

`scripts/download.sh`와 `scripts/build_bundle.sh`는 공통 함수 파일 `scripts/lib/common.sh`를 통해 다음 항목을 먼저 검증합니다.

- `K8S_VERSION`: `v1.33.11` 형식. `1.33.11`처럼 `v`를 생략하면 자동으로 `v1.33.11`로 보정합니다.
- `TARGET_OS`: 현재 `ubuntu24.04`만 허용합니다.
- `ARCH`: 현재 `amd64`만 허용합니다.
- `CONTAINER_RUNTIME`: 현재 `containerd`만 허용합니다.
- `CNI_CHOICE`: `calico` 또는 `cilium`
- `CALICO_INSTALL_METHOD`: `manifest` 또는 `operator`

### 호환성 정책 관리

컴포넌트 간 버전 호환성은 `manifests/compatibility.yaml`에 기록합니다. 이 파일은 자동 생성 결과가 아니라, 공식 문서와 실제 검증 결과를 반영하는 내부 정책 파일입니다.

체크 기준:

- Kubernetes 핵심 컴포넌트: Kubernetes Version Skew Policy 기준
- containerd: Kubernetes CRI 요구사항과 containerd 릴리스 지원 범위 기준
- Calico: Tigera/Calico의 Kubernetes 지원 범위 기준
- Cilium: Cilium의 Kubernetes compatibility matrix 기준

다음 단계에서는 `download.sh`가 실제 수집 전에 이 정책 파일과 설정값을 대조하도록 확장합니다.

## 4. 번들 생성

```bash
./scripts/build_bundle.sh
```

예상 산출물:

```text
bundles/k8s-v1.33.11-ubuntu24.04/
bundles/k8s-v1.33.11-ubuntu24.04.tar.gz
```

현재 1차 골격 단계에서는 대상 경로 계산과 생성 계획 출력까지만 수행합니다.

## 5. 폐쇄망 설치

생성된 번들 내부의 `scripts/install.sh`가 실제 폐쇄망 노드에서 실행될 설치 스크립트입니다.

빌더 루트의 `scripts/install.sh`는 실수로 빌더 자체를 설치 대상으로 사용하는 것을 막기 위한 안내용 진입점입니다.

## 6. Manual Installation & Upgrade

이 빌더는 Kubernetes 번들을 생성하는 도구이므로 직접 `helm upgrade --install`이나 `kubectl apply`로 배포되는 서비스가 아닙니다.

수동 절차는 생성된 버전 고정 번들의 `install-guide.md`를 따릅니다. 빌더 자체에서 수동으로 확인할 항목은 다음과 같습니다.

```bash
# 설정 로드 가능 여부 확인
bash -n scripts/download.sh
bash -n scripts/build_bundle.sh

# 생성 대상 이름 확인
./scripts/build_bundle.sh --dry-run
```

## 7. 다음 구현 단계

1. Ubuntu 24.04용 DEB 수집 구현
2. kubeadm image list 기반 이미지 export 구현
3. Calico manifest/operator 방식별 자산 수집 구현
4. 번들 디렉터리 생성 및 tar.gz 패키징 구현
5. 기존 `k8s-1.33.11-ubuntu24.04` 산출물 재현 검증
