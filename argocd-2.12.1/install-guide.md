# 🚀 ArgoCD v2.12.1 오프라인 설치 가이드

폐쇄망 환경에서 ArgoCD v2.12.1을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- (도메인 접속 사용 시) Envoy Gateway 설치 완료
- (NAS 사용 시) 모든 노드에 NFS 클라이언트 설치 완료

## 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: 설치 스크립트 설정

`scripts/install.sh` 상단 Config 블록을 환경에 맞게 수정합니다.

```bash
# ==================== Config ====================
# Harbor Registry
HARBOR_REGISTRY="<NODE_IP>:30002"
HARBOR_PROJECT="library"

# Storage: "none" | "nas" | "hostpath"
STORAGE_TYPE="hostpath"

# hostPath Settings
HOSTPATH_REDIS="/data/argocd/redis"
HOSTPATH_REPO="/data/argocd/repo-cache"

# NAS Settings (STORAGE_TYPE="nas" 시 사용)
NAS_SERVER="192.168.1.50"
NAS_REDIS_PATH="/nas/argocd/redis"
NAS_REPO_PATH="/nas/argocd/repo"

# Networking
NODEPORT="30001"
DOMAIN="argocd.devops.internal"
GATEWAY_NAME="cmp-gateway"
GATEWAY_NAMESPACE="envoy-gateway-system"
# ================================================
```

## 3단계: (NAS 사용 시) PV/PVC 설정

NAS(NFS) 스토리지를 사용하는 경우 `manifests/nas-pv.yaml`의 NFS 서버 주소와 경로를 수정합니다.

```bash
# NAS 사용 시 매니페스트 적용
kubectl apply -f manifests/nas-pv.yaml
```

## 4단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 자동 처리 항목:

- Namespace 생성 및 스토리지 설정 적용
- Helm 설치 (Harbor 이미지 경로 기반)
- NodePort 및 HTTPRoute 생성 (`DOMAIN` 설정 시)
- CoreDNS 도메인 자동 등록 (`DOMAIN` 설정 시)

## 5단계: 설치 확인

```bash
kubectl get pods -n argocd
kubectl get svc -n argocd
kubectl get httproute -n argocd
```

## 6단계: 초기 접속 및 비밀번호 변경

초기 비밀번호 확인:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

| 접속 방식 | 주소 | 비고 |
| :--- | :--- | :--- |
| **NodePort** | `http://<NODE_IP>:30001` | 일반 접속 |
| **도메인** | `http://argocd.devops.internal` | DNS/hosts 설정 필요 |

도메인 접속 시 `/etc/hosts` 파일에 추가:
`<GATEWAY_IP>  argocd.devops.internal`

> **보안 권고**: 최초 로그인 후 비밀번호를 변경하고 초기 Secret을 삭제하십시오.
> `kubectl delete secret argocd-initial-admin-secret -n argocd`

## 삭제

```bash
./scripts/uninstall.sh
```
