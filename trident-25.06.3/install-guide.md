# NetApp Trident 설치 가이드

이 문서는 폐쇄망(Air-gapped) 환경에서 NetApp Trident 25.06.3을 설치하고 관리하는 방법을 설명합니다.

## 1. 전제 조건

- Kubernetes 클러스터 (v1.20 이상 권장).
- Helm v3 설치 완료.
- (필요 시) `charts/` 디렉토리에 Trident Operator Helm 차트 준비.
- (필요 시) `images/` 디렉토리에 컨테이너 이미지 준비 또는 Harbor에 이미지 업로드 완료.

## 2. 자동 설치 및 관리 (Recommended)

컴포넌트 루트 디렉토리에서 제공되는 통합 설치 스크립트를 사용하여 설치, 업그레이드 또는 초기화를 수행할 수 있습니다.

```bash
# 설치 스크립트 실행
./scripts/install.sh
```

### 스크립트 주요 기능

- **설정 보존**: `install.conf`에 입력 정보를 저장하여 재설치 시 재사용 가능.
- **대화형 메뉴**: 기존 설치 감지 시 업그레이드(Upgrade), 재설치(Reinstall), 초기화(Reset) 옵션 제공.
- **자동 동기화**: 사용자 입력을 `values.yaml`에 반영한 후 Helm 배포 수행.

## 3. 수동 설치 절차 (Manual Installation & Upgrade)

자동화 스크립트 사용이 어려운 환경에서는 아래 단계에 따라 수동으로 설치할 수 있습니다.

### 3.1. 네임스페이스 생성

```bash
kubectl create ns trident
```

### 3.2. Helm 차트 설치

```bash
# charts 디렉토리 내의 로컬 차트 경로를 지정합니다.
helm upgrade --install trident ./charts/trident-operator \
  --namespace trident \
  --version 100.2506.3 \
  -f ./values.yaml
```

### 3.3. 백엔드 및 스토리지 클래스 적용

```bash
# NetApp ONTAP 백엔드 설정 적용
kubectl apply -f manifests/001_backend_setup.yaml

# StorageClass(Delete/Retain) 적용
kubectl apply -f manifests/002_storage_class.yaml
```

## 4. 설치 확인 및 테스트

### 4.1. 서비스 상태 확인

```bash
# Trident Operator 및 CSI Pod 상태 확인
kubectl get pods -n trident
```

### 4.2. 동적 프로비저닝 테스트

테스트용 PVC와 Pod를 생성하여 스토리지가 정상적으로 할당되는지 확인합니다.

```bash
# 테스트 매니페스트 적용
kubectl apply -f manifests/003_test.yaml

# PVC Bound 상태 및 Pod 실행 확인
kubectl get pvc,pod -n default
```
