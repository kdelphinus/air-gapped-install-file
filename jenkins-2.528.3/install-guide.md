# 🚀 Jenkins v2.528.3 오프라인 설치 가이드

폐쇄망 환경에서 Jenkins v2.528.3을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)

## 1단계: 호스트 디렉토리 생성

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다. PV 데이터 저장 경로를 대상 노드에 미리 생성합니다.

```bash
chmod +x scripts/setup-host-dirs.sh
./scripts/setup-host-dirs.sh
```

## 2단계: 이미지 Harbor 업로드

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 3단계: 운영 설정 (values.yaml 및 PV)

루트 디렉토리의 설정 파일들을 환경에 맞게 수정합니다.

| 파일명 | 용도 | 주요 수정 항목 |
| :--- | :--- | :--- |
| **`values.yaml`** | Jenkins 운영 설정 | 이미지 경로, 리소스 제한, 서비스 타입 등 |
| **`manifests/pv-volume.yaml`** | Jenkins 홈 PV 정의 | 노드 이름(`nodeAffinity`), 저장 경로 |
| **`manifests/gradle-cache-pv-pvc.yaml`** | Gradle 캐시 PV/PVC | 저장 경로 |

## 4단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 Jenkins를 배포할 노드 이름을 입력합니다.

스크립트 자동 처리 항목:

- 네임스페이스 및 PV/PVC 적용
- 노드 라벨 적용 (`jenkins-node=true`)
- Helm 배포 및 초기 관리자 비밀번호 출력
- CoreDNS 도메인 자동 등록 (`DOMAIN` 설정 시)

## 5단계: 설치 확인

```bash
# 파드 및 서비스 상태 확인
kubectl get pods,svc -n jenkins

# 초기 관리자 비밀번호 확인
kubectl get secret jenkins -n jenkins \
  -o jsonpath="{.data.jenkins-admin-password}" | base64 -d && echo
```

| 접속 방식 | 주소 | 비고 |
| :--- | :--- | :--- |
| **NodePort** | `http://<NODE_IP>:30000` | 기본 접속 포트 |
| **관리자 계정** | `admin` | 초기 ID |

## 💡 참고 사항

- **마이그레이션**: 파이프라인 이전 절차는 `export_import/guide.md`를 참조하십시오.
- **빌드 이미지**: Jenkins 관리 메뉴에서 `docker-registry` 시크릿을 등록하여 빌드 노드에서 Harbor 이미지를 사용할 수 있습니다.

## 삭제

```bash
./scripts/uninstall.sh
```

## Manual Installation & Upgrade

자동화 설치 스크립트(`install.sh`)를 사용하지 않고, 수동으로 Jenkins 리소스 및 Helm 릴리스를 배포하고자 할 때 아래 절차를 수행합니다.

### 1. K8s 네임스페이스 및 정적 PV/PVC 생성

정적 볼륨 매니페스트를 먼저 생성해야 합니다.

```bash
# 1. 네임스페이스 생성
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

# 2. Jenkins 홈 PV 적용
kubectl apply -f ./manifests/pv-volume.yaml

# 3. Gradle 캐시 PV/PVC 적용
kubectl apply -f ./manifests/gradle-cache-pv-pvc.yaml
```

### 2. Helm 오버라이드 설정 파일 생성 (`values-infra.yaml`)

사용 환경에 맞는 인프라 사양을 `values-infra.yaml`에 작성합니다. 관리자 비밀번호(`controller.admin.password`)는 절대 수동으로 작성하지 않고 비워두어 Helm이 무작위 비밀번호를 안전히 자동 생성하도록 합니다.

```yaml
# values-infra.yaml 수동 예시
controller:
  image:
    registry: "harbor.example.com"
    repository: "library/cmp-jenkins-full"
    tag: "2.528.3"
    pullPolicy: "Always"
  imagePullSecrets:
    - name: "regcred"
  serviceType: "NodePort"
  nodePort: "30000"
  nodeSelector: {}
  runAsUser: 1000
  fsGroup: 1000
  installPlugins: false
  sidecars:
    configAutoReload:
      image:
        registry: "harbor.example.com"
        repository: "library/k8s-sidecar"
        tag: "1.30.7"
        pullPolicy: "IfNotPresent"

agent:
  image:
    registry: "harbor.example.com"
    repository: "library/inbound-agent"
    tag: "latest"
    pullPolicy: "IfNotPresent"
  imagePullSecrets:
    - name: "regcred"

persistence:
  storageClass: "manual"
  size: "20Gi"
```

### 3. Helm 차트 수동 설치 및 업그레이드

컴포넌트 루트 디렉토리에서 Helm 명령어를 사용하여 릴리스를 배포합니다.

```bash
helm upgrade --install jenkins ./charts/jenkins \
  --namespace jenkins \
  -f ./values.yaml \
  -f ./values-infra.yaml
```
