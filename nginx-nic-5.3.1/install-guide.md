# 🚀 F5 NGINX Ingress Controller v5.3.1 오프라인 설치 가이드 (Helm 기반)

폐쇄망 환경에서 F5 NGINX Ingress Controller (NIC) v5.3.1 OSS 버전을
Helm을 사용하여 Kubernetes 위에 설치하는 절차를 안내합니다.

> **OSS 전용 가이드입니다.** `nginx/nginx-ingress` 이미지만 사용하며,
> NGINX Plus 및 유료 기능은 다루지 않습니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료 (1.25.0 이상 권장)
- `kubectl` 및 `helm` CLI 사용 가능
- Harbor 레지스트리 구축 완료 (`<NODE_IP>:30002`)
- 인터넷 연결 환경에서 이미지 및 Helm 차트 사전 준비 완료

---

## 1단계: 인터넷 연결 환경에서 — 이미지 및 차트 준비

> 이 단계는 **인터넷 연결 환경**(준비 서버)에서 수행합니다.

### 이미지 및 차트 다운로드

```bash
# 프로젝트 폴더 이동
cd nginx-nic-5.3.1

# 이미지 다운로드 (skopeo 또는 docker 필요)
# 기본적으로 ctr을 사용하며, docker 사용 시 -e docker 옵션 부여
./scripts/download_images.sh
```

### 에어갭 환경으로 파일 이관

USB, SCP, 내부 파일 서버 등 허용된 방법으로
`nginx-nic-5.3.1/` 전체 폴더를 에어갭 서버로 복사합니다.

---

## 2단계: 에어갭 환경에서 — 이미지 로드 및 Harbor 푸시

> 이 단계부터는 **에어갭(폐쇄망) 환경**에서 수행합니다.

### 이미지 Harbor 푸시

1. `images/upload_images_to_harbor_v3-lite.sh` 파일을 열어 상단 설정을 확인합니다.
2. `<NODE_IP>`를 실제 Harbor IP로 변경하거나 환경변수로 지정합니다.
3. 스크립트를 실행합니다.

```bash
cd nginx-nic-5.3.1/images
# Harbor 비밀번호를 입력하라는 메시지가 표시됩니다.
./upload_images_to_harbor_v3-lite.sh
```

---

## 3단계: 설정 파일 수정 (values.yaml)

`nginx-nic-5.3.1/values.yaml` 파일을 열어 다음 항목을 확인하고 수정합니다.

```yaml
controller:
  image:
    repository: "<NODE_IP>:30002/library/nginx-ingress" # Harbor IP로 변경
    tag: "5.3.1"
```

---

## 4단계: 설치 (Helm 실행)

`nginx-nic-5.3.1` 루트 디렉토리에서 설치 스크립트를 실행합니다.
이 스크립트는 **CRD를 먼저 설치**한 후 Helm 배포를 수행합니다.

```bash
cd nginx-nic-5.3.1
./scripts/install.sh
```

### 설치 스크립트 주요 동작:
1. `manifests/` 내의 CRD들을 `kubectl apply -k`로 설치합니다.
2. `nginx-ingress` 네임스페이스를 생성합니다.
3. `values.yaml` 설정을 기반으로 Helm 차트를 설치합니다.

---

## 5단계: 설치 확인

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

## 🛠️ 트러블슈팅

### 1. CRD 관련 오류
CRD가 먼저 설치되지 않으면 Ingress 리소스 생성 시 `no matches for kind "VirtualServer"` 등의 오류가 발생할 수 있습니다. `scripts/install.sh`를 통해 CRD가 정상적으로 설치되었는지 확인하세요.

### 2. 이미지 Pull 오류
Harbor에 이미지가 정상적으로 업로드되었는지, `values.yaml`의 레지스트리 주소가 올바른지 확인하세요.
`kubectl describe pod <pod_name> -n nginx-ingress` 명령으로 상세 사유를 확인할 수 있습니다.
