# 🚀 F5 NGINX Ingress Controller v5.3.1 오프라인 설치 가이드 (Helm 기반)

폐쇄망 환경에서 F5 NGINX Ingress Controller (NIC) v5.3.1 OSS 버전을 Helm을 사용하여 Kubernetes 위에 설치하는 절차를 안내합니다.

> **OSS 전용 가이드입니다.** `nginx/nginx-ingress` 이미지만 사용하며, NGINX Plus 및 유료 기능은 다루지 않습니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 1. 전제 조건

- Kubernetes 클러스터 구성 완료 (1.25.0 이상 권장)
- `kubectl` 및 `helm` CLI 사용 가능
- Harbor 레지스트리 구축 완료 (`<NODE_IP>:30002`)
- 인터넷 연결 환경에서 이미지 및 Helm 차트 사전 준비 완료

---

## 2. 1단계: 에어갭 환경에서 — 이미지 로드 및 Harbor 푸시

> 이 단계부터는 **에어갭(폐쇄망) 환경**에서 수행합니다.

### 이미지 Harbor 푸시

폐쇄망 내 반입 완료 후, 컴포넌트 루트 디렉토리(`nginx-nic-5.3.1/`) 기준에서 이미지 마이그레이션 스크립트를 실행합니다.

```bash
# 이미지 업로드 스크립트 실행 권한 부여 및 수행
# (스크립트 실행 시 Harbor 비밀번호를 요청합니다)
chmod +x ./images/upload_images_to_harbor_v3-lite.sh
sudo ./images/upload_images_to_harbor_v3-lite.sh
```

* **동작 원리**:
  * docker, skopeo, ctr 도구를 자동 감지하여 업로드를 처리합니다.
  * **`skopeo`**가 설치된 머신인 경우, 로컬 containerd에 로드하지 않고 tar 아카이브에서 Harbor 레지스트리로 바로 이미지 복사(Copy)를 진행하여 업로드 속도를 극대화합니다.

---

## 3. 2단계: 설치 및 구성 실행 (대화형)

설치 자동화 스크립트는 실행 시 필요한 설정값들을 대화식 CLI로 입력받아 설치 및 업그레이드를 수행합니다.

```bash
# 설치 스크립트 실행
sudo ./scripts/install.sh
```

### 주요 입력 정보 및 처리 방식
* **이미지 소스**:
  * Harbor 방식은 `<HARBOR_REGISTRY>/<HARBOR_PROJECT>/...` 이미지를 사용합니다.
  * 로컬 방식은 각 노드에 사전 로드된 기본 컨테이너 이미지를 활용합니다.
* **설정 동기화**:
  * 입력된 설정은 base인 `values.yaml`을 변경하지 않고, 가변 인프라 설정 전용 파일인 `values-infra.yaml`을 생성하여 병합 배포하므로 **Single Source of Truth**가 보장됩니다.
  * 생성된 `values-infra.yaml` 및 `install.conf`는 일반 삭제 시에도 디렉토리에 보존되어 재설치 및 업그레이드 시 멱등 배포를 보장하며, 오직 `--reset` 초기화 명령 시에만 소거됩니다.

---

## 4. 3단계: 설치 확인

```bash
# Pod 상태 확인
kubectl get pods -n nginx-ingress

# Service NodePort 확인 (30080, 30443)
kubectl get svc -n nginx-ingress

# CRD 등록 확인
kubectl get crd | grep nginx
```

### 포트 확인

| 프로토콜 | NodePort | 용도 |
| :--- | :--- | :--- |
| **HTTP** | **30080** | 일반 웹 트래픽 |
| **HTTPS** | **30443** | 보안 웹 트래픽 |

---

## 5. 수동 설치 및 업그레이드 가이드 (Manual Installation & Upgrade)

자동화 스크립트 장애 대처용 수동 반영 가이드라인입니다.

### 5.1. 수동 설치 진행
1. `values.yaml` 을 수정하지 않고 그대로 두고, `values-infra.yaml` 파일을 작성하여 로컬 사양(이미지 레지스트리 경로, NodePort, replicas)을 오버라이드합니다.
   ```yaml
   controller:
     image:
       repository: "192.168.1.10:30002/library/nginx-ingress"
       tag: "5.3.1"
       pullPolicy: "IfNotPresent"
     replicaCount: 1
     ingressClass:
       name: "nginx"
     service:
       type: NodePort
       httpPort:
         port: 80
         nodePort: 30080
       httpsPort:
         port: 443
         nodePort: 30443
   ```
2. Kubernetes CRD 자원 배포 및 Helm 배포를 직접 적용합니다.
   ```bash
   # 1. CRD 리소스 적용 (manifests/ 디렉토리 기준)
   kubectl apply -k ./manifests/

   # 2. 네임스페이스 생성
   kubectl create namespace nginx-ingress --dry-run=client -o yaml | kubectl apply -f -

   # 3. Helm 배포 (멱등 배포)
   helm upgrade --install nginx-ingress ./charts/nginx-ingress-5.3.1 \
     -n nginx-ingress \
     -f ./values.yaml \
     -f ./values-infra.yaml
   ```

---

## 6. 서비스 삭제 및 초기화

NGINX Ingress Controller를 완전히 제거하려면 다음 명령을 사용합니다.

```bash
# 리소스 삭제 (설정 파일 및 CRD 보존)
sudo ./scripts/uninstall.sh

# 완전 초기화 (설정 파일 삭제 및 공유 CRD 다중 승인 확인 후 제거)
sudo ./scripts/uninstall.sh --reset
```

---

## 🛠️ 트러블슈팅

### 1. CRD 관련 오류

CRD가 먼저 설치되지 않으면 Ingress 리소스 생성 시 `no matches for kind "VirtualServer"` 등의 오류가 발생할 수 있습니다. `scripts/install.sh`를 통해 CRD가 정상적으로 설치되었는지 확인하세요.

### 2. 이미지 Pull 오류

Harbor에 이미지가 정상적으로 업로드되었는지, `values-infra.yaml`의 레지스트리 주소가 올바른지 확인하세요.
`kubectl describe pod <pod_name> -n nginx-ingress` 명령으로 상세 사유를 확인할 수 있습니다.
