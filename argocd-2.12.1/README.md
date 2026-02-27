# ArgoCD 2.12.1 폐쇄망 설치 가이드

폐쇄망(Air-gapped) 환경에서 ArgoCD 2.12.1을 Helm으로 설치하는 가이드입니다.
NAS(NFS) / hostPath 스토리지 및 NodePort · HTTPRoute 네트워크 설정이 포함되어 있습니다.

## 폴더 구조

```
argocd-2.12.1/
├── argo-cd/                # Helm 차트 원본
├── images/                 # 컨테이너 이미지 (.tar)
├── scripts/                # 이미지 업로드/다운로드 스크립트
├── values.yaml             # ArgoCD Helm 설정
├── nas-pv.yaml             # NAS(NFS) 사용 시 PV/PVC 정의
├── install-argocd.sh       # 설치 자동화 스크립트 (네트워크 설정 포함)
├── argocd-nodeport-svc.yaml   # NodePort 서비스 (참고용)
├── argocd-httproute.yaml      # HTTPRoute (참고용)
└── README.md
```

---

## 1. 준비 사항

- Kubernetes 클러스터 구성 완료
- Harbor 레지스트리 접근 가능
- (도메인 접속 사용 시) Envoy Gateway 설치 완료

**포함된 리소스:**

- Helm 차트: v7.4.1 (ArgoCD v2.12.1)
- 컨테이너 이미지: `argocd`, `redis`, `haproxy` (.tar)

---

## 2. 이미지 업로드

```bash
# scripts/upload_images.sh 상단 Config 수정
HARBOR_REGISTRY="<HARBOR_IP>:30002"
HARBOR_PROJECT="<PROJECT>"
HARBOR_USER="admin"
HARBOR_PASSWORD="<PASSWORD>"

# 실행
cd scripts
chmod +x upload_images.sh
./upload_images.sh
```

---

## 3. 설치 스크립트 설정

`install-argocd.sh` 상단 Config 블록만 수정하면 됩니다.

```bash
# ==================== Config ====================
# Harbor Registry
HARBOR_REGISTRY="<HARBOR_IP>:30002"
HARBOR_PROJECT="<PROJECT>"

# Storage: "none" | "nas" | "hostpath"
STORAGE_TYPE="hostpath"

# NAS (NFS) Settings - STORAGE_TYPE="nas" 일 때 사용
NAS_SERVER="192.168.1.50"
NAS_REDIS_PATH="/nas/argocd/redis"
NAS_REPO_PATH="/nas/argocd/repo"

# hostPath Settings - STORAGE_TYPE="hostpath" 일 때 사용
HOSTPATH_REDIS="/data/argocd/redis"
HOSTPATH_REPO="/data/argocd/repo-cache"

# Networking
NODEPORT="30001"                      # NodePort 번호
DOMAIN="argocd.devops.internal"       # HTTPRoute 도메인, "" 이면 HTTPRoute 미생성
GATEWAY_NAME="cmp-gateway"
GATEWAY_NAMESPACE="envoy-gateway-system"
# ================================================
```

**설정 후 실행:**

```bash
chmod +x install-argocd.sh
./install-argocd.sh
```

**스크립트가 자동으로 처리하는 항목:**

- namespace 생성
- NAS PV/PVC 적용 (nas 선택 시)
- Helm 설치 (Harbor 이미지 경로 + 스토리지 설정)
- NodePort 서비스 생성
- HTTPRoute 생성 (DOMAIN 설정 시)

---

## 4. 설치 확인

```bash
kubectl get pods -n argocd
kubectl get svc -n argocd
kubectl get httproute -n argocd
```

---

## 5. 접속 정보

### 초기 계정

| 항목 | 값 |
| :--- | :--- |
| ID | `admin` |
| PW | 설치 시 자동 생성 (아래 명령으로 확인) |

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

> **참고:** 초기 비밀번호는 최초 로그인 후 반드시 변경하고, secret을 삭제하세요.
>
> ```bash
> kubectl delete secret argocd-initial-admin-secret -n argocd
> ```

### 접속 방법

| 방법 | 주소 |
| :--- | :--- |
| NodePort | `http://<NODE_IP>:30001` |
| 도메인 | `http://argocd.devops.internal` (DNS/hosts 등록 필요) |
| 포트 포워딩 (임시) | `kubectl port-forward svc/argocd-server -n argocd 8080:80` → `http://localhost:8080` |

**도메인 접속 시 hosts 파일 또는 DNS에 아래 항목 추가:**

```text
<GATEWAY_IP>  argocd.devops.internal
```

---

## 주의 사항

- NAS 사용 시 모든 노드에 NFS 클라이언트 설치 필요
- `values.yaml`의 Harbor 주소가 실제 환경과 일치하는지 확인
- `server.insecure: true` 설정으로 HTTP 서비스 중 (Gateway에서 TLS 처리)
