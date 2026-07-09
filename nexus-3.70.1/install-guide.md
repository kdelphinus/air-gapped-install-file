# 🚀 Nexus Repository 오프라인 설치 가이드 (ctr 기반)

폐쇄망 환경에서 `ctr`을 사용하여 Nexus3를 설치하고 라이브러리 저장소를 구성하는 절차입니다.

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.



## 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: 설치 실행

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# 헬름 설치 (루트의 values.yaml 및 values-infra.yaml 자동 반영)
chmod +x scripts/install.sh
./scripts/install.sh
```

## 3단계: 초기 비밀번호 확인

설치 완료 후 파드가 `Running` 상태가 되면 아래 명령어로 초기 `admin` 비밀번호를 확인합니다.

```bash
kubectl exec -it nexus-0 -n nexus -- cat /nexus-data/admin.password
```

## 삭제

```bash
./scripts/uninstall.sh
```

삭제 시 PV/PVC 삭제 여부를 선택합니다. PV 는 `Retain` 정책이므로 PVC 삭제 후에도 호스트 데이터는 유지됩니다.

## Manual Installation & Upgrade

자동화 설치 스크립트(`install.sh`)를 사용하지 않고, 수동으로 Nexus 리소스 및 Helm 릴리스를 배포하고자 할 때 아래 절차를 수행합니다.

### 1. Helm 오버라이드 설정 파일 생성 (`values-infra.yaml`)

사용 환경에 맞는 인프라 사양을 `values-infra.yaml`에 작성합니다.

```yaml
# values-infra.yaml 수동 예시
image:
  repository: "harbor.example.com/library/nexus3"
  tag: "3.70.1"
  pullPolicy: "IfNotPresent"

persistence:
  enabled: true
  accessMode: "ReadWriteOnce"
  storageClass: "nfs-provisioner"
  size: "100Gi"

nodeSelector: {}
```

### 2. Helm 차트 수동 설치 및 업그레이드

컴포넌트 루트 디렉토리에서 Helm 명령어를 사용하여 릴리스를 배포합니다.

```bash
# 1. Nexus 네임스페이스 생성
kubectl create namespace nexus --dry-run=client -o yaml | kubectl apply -f -

# 2. Helm 설치 및 업그레이드 구동
helm upgrade --install nexus ./charts/nexus-repository-manager \
  --namespace nexus \
  -f ./values.yaml \
  -f ./values-infra.yaml
```
