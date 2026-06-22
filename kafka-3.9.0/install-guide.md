# Installation Guide - Apache Kafka v3.9.0 (KRaft Mode)

본 가이드는 폐쇄망(Air-Gapped) 환경에서 ZooKeeper 없이 3개의 카프카 브로커 노드로 고가용성(HA) 클러스터를 배포하기 위한 상세 지침을 제공합니다.

---

## 1. Prerequisites (사전 준비 작업)

인터넷망이 차단된 폐쇄망 환경에 설치하기 전, 인터넷이 연결된 PC에서 아래 절차를 수행하여 차트 및 이미지 자산을 획득해야 합니다.

### 1.1. 자산 다운로드 (인터넷망 PC)

1. 리포지토리 컴포넌트 루트 경로로 이동하여 다운로드 스크립트를 구동합니다.

  ```bash
  cd kafka-3.9.0
  ./scripts/download_assets_offline.sh
  ```

2. 성공적으로 완료되면 아래 파일들이 저장됩니다.
  - `charts/kafka` (Bitnami Kafka 31.4.0 차트)
  - `images/kafka-images.tar` (필수 컨테이너 이미지 4종 패키지)

3. 다운로드된 디렉토리 자산 전체를 이동식 매체 또는 로컬 네트워크망을 통해 폐쇄망 Target Node에 업로드합니다.

---

## 2. Air-Gapped Deployment (에어갭 설치 절차)

### 2.1. 이미지 업로드 (Harbor 레지스트리 사용 시)

로컬 이미지 로드가 아닌 프라이빗 Harbor 레지스트리를 사용한다면, 사전에 이미지를 업로드해야 합니다.

1. 업로드 스크립트를 실행합니다.

  ```bash
  ./scripts/upload_images_to_harbor_v3-lite.sh
  ```

2. 화면의 지시에 따라 Harbor Registry IP 및 대상 Project 이름을 입력하면 `skopeo` 또는 `docker/podman` 도구를 감지하여 이미지를 자동 업로드합니다.

### 2.2. 자동화 스크립트 실행 (`install.sh`)

1. 컴포넌트 루트 경로에서 설치 스크립트를 실행합니다.

  ```bash
  ./scripts/install.sh
  ```

2. 이미지 소스(`Harbor` 또는 `Local`)를 선택합니다.
3. 스토리지 유형을 선택합니다.
  - **`HostPath`**: 단일 노드 고정배치 또는 다중 노드 고가용성 테스트 배치(3개 노드 기재) 여부를 입력받아 매니페스트에 노드 어피니티를 주입합니다.
  - **`NAS` (NFS 정적)**: NFS 서버 IP 및 기본 공유 디렉토리 경로를 입력받습니다.
  - **`Dynamic`**: Kubernetes에 배포되어 있는 dynamic StorageClass 이름을 주입하여 동적 PVC로 릴리즈합니다.
4. 설치가 완료되면 `install.conf` 에 설정 값이 저장되며, 생성된 `values-custom.yaml` 은 향후 업그레이드 및 설정 확인을 위해 보존됩니다.

---

## 3. Manual Installation & Upgrade (수동 설치 및 폴백 절차)

만약 자동화 스크립트(`install.sh`)가 실패하거나 클러스터 규격에 따라 직접 커스텀 설치 및 업그레이드를 해야 하는 경우, 아래 지침을 통해 수동 배포를 진행할 수 있습니다.

### 3.1. 1:1 바인딩 정적 PV 수동 배포

Kubernetes StatefulSet은 `volumeClaimTemplates`에 의해 각 복제본 파드마다 고유한 PVC(`data-kafka-controller-0`, `data-kafka-controller-1`, `data-kafka-controller-2`)를 자동 요구합니다. PVC와 PV의 바인딩은 **1:1 Exclusive Binding**이므로, 정적 스토리지 구성 시 이에 대응하는 3개의 PV가 사전에 준비되어야 합니다.

#### HostPath 다중 노드 테스트용 PV 구성 예시

1. `manifests/pv-hostpath.yaml` 파일을 템플릿으로 사용하여 3개 타겟 노드(`node-1`, `node-2`, `node-3`)와 마운트 경로를 수동 치환하여 저장합니다.
2. 아래 명령어로 PV를 사전 적용합니다.

  ```bash
  kubectl apply -f manifests/pv-hostpath.yaml
  ```

### 3.2. Helm을 활용한 수동 릴리즈 배포

1. 커스텀 설정 파일을 생성합니다. (기존 템플릿 복사)

  ```bash
  cp values.yaml values-custom.yaml
  ```

2. `values-custom.yaml` 을 환경에 맞춰 수동 편집합니다.
  - 이미지 주소 및 태그 수정
  - `broker.replicaCount: 0` 으로 broker-only 노드를 비활성화합니다.
  - `controller.replicaCount: 3`, `controller.controllerOnly: false` 로 KRaft co-located 노드를 구성합니다.
  - 공유 스토리지 사용 시 `controller.podAntiAffinityPreset: soft` 로 지정하고, `hostpath` 단일 노드 테스트 시 `controller.podAntiAffinityPreset: ""` 및 `controller.nodeSelector` 를 타겟 노드로 지정합니다.

3. 릴리즈를 배포 또는 업그레이드합니다.

  ```bash
  helm upgrade --install kafka ./charts/kafka \
    --namespace kafka --create-namespace \
    -f ./values-custom.yaml
  ```

> [!TIP]
> `values-custom.yaml` 파일은 향후 클러스터 설정 변경이나 버전 업그레이드 시 커스텀 설정을 유지하기 위해 삭제하지 않고 형상 관리에 보존해 두는 것을 권장합니다.
