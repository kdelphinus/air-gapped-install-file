# ArgoCD v2.12.1 오프라인 설치 가이드

폐쇄망 환경에서 ArgoCD v2.12.1을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- (도메인 접속 사용 시) Envoy Gateway 설치 완료
- (NAS 사용 시) 모든 노드에 NFS 클라이언트 설치 완료

## Phase 1: 이미지 Harbor 업로드

```bash
cd scripts

# upload_images.sh 상단 Config 수정
HARBOR_REGISTRY="<NODE_IP>:30002"
HARBOR_PROJECT="<PROJECT>"
HARBOR_USER="admin"
HARBOR_PASSWORD="<PASSWORD>"

chmod +x upload_images.sh
./upload_images.sh
```

## Phase 2: install-argocd.sh 설정

`install-argocd.sh` 상단 Config 블록을 환경에 맞게 수정합니다.

```bash
# ==================== Config ====================
# Harbor Registry
HARBOR_REGISTRY="<NODE_IP>:30002"
HARBOR_PROJECT="<PROJECT>"

# Storage: "none" | "nas" | "hostpath"
STORAGE_TYPE="hostpath"

# hostPath Settings - STORAGE_TYPE="hostpath" 일 때 사용
HOSTPATH_REDIS="/data/argocd/redis"
HOSTPATH_REPO="/data/argocd/repo-cache"

# NAS Settings - STORAGE_TYPE="nas" 일 때 사용
NAS_SERVER="192.168.1.50"
NAS_REDIS_PATH="/nas/argocd/redis"
NAS_REPO_PATH="/nas/argocd/repo"

# Networking
NODEPORT="30001"
DOMAIN="argocd.devops.internal"   # "" 이면 HTTPRoute 미생성 및 CoreDNS 등록 건너뜀
TLS_ENABLED="false"               # "true" | "false" — https/http 결정
GATEWAY_NAME="cmp-gateway"
GATEWAY_NAMESPACE="envoy-gateway-system"
# ================================================
```

## Phase 3: (NAS 사용 시) PV/PVC 설정

NAS(NFS) 스토리지를 사용하는 경우 `nas-pv.yaml` 의 NFS 서버 주소와 경로를 수정합니다.

```bash
# NAS 사용 시 nas-pv.yaml 수정 후 적용
kubectl apply -f nas-pv.yaml
```

## Phase 4: 설치 실행

```bash
chmod +x install-argocd.sh
./install-argocd.sh
```

스크립트가 자동으로 처리하는 항목:

- Namespace 생성
- NAS PV/PVC 적용 (`nas` 선택 시)
- Helm 설치 (Harbor 이미지 경로 + 스토리지 설정)
- NodePort 서비스 생성
- HTTPRoute 생성 (`DOMAIN` 설정 시)
- CoreDNS에 `DOMAIN` 등록 (`DOMAIN` 설정 시)

> DNS 서버 없이 도메인을 사용하는 경우 `DOMAIN`을 설정하면 스크립트가 클러스터 내부 CoreDNS에
> 자동으로 등록합니다. 클라이언트(PC) `/etc/hosts`는 별도로 추가해야 합니다.

## Phase 5: 설치 확인

```bash
kubectl get pods -n argocd
kubectl get svc -n argocd
kubectl get httproute -n argocd
```

## Phase 6: 초기 접속

초기 비밀번호 확인:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

| 방법 | 주소 |
| :--- | :--- |
| NodePort | `http://<NODE_IP>:30001` |
| 도메인 | `http://argocd.devops.internal` (DNS/hosts 등록 필요) |
| 포트 포워딩 (임시) | `kubectl port-forward svc/argocd-server -n argocd 8080:80` |

도메인 접속 시 hosts 파일 또는 DNS에 추가:

```text
<GATEWAY_IP>  argocd.devops.internal
```

초기 비밀번호는 최초 로그인 후 반드시 변경하고 Secret을 삭제합니다.

```bash
kubectl delete secret argocd-initial-admin-secret -n argocd
```

## 참고: Jenkins/Harbor 연동 가이드

ArgoCD와 Jenkins, Harbor 연동 절차는 `argocd-jenkins-harbor-integration.md` 를 참조하세요.
