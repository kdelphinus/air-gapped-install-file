# ArgoCD 2.12.1 폐쇄망 설치 가이드 (Storage 커스텀 포함)

이 가이드는 폐쇄망(Air-gapped) 환경에서 ArgoCD 2.12.1 버전을 Helm을 통해 설치하는 과정을 설명합니다. NAS(NFS) 또는 hostPath를 사용한 데이터 보존 설정이 포함되어 있습니다.

## 📁 폴더 구조
```text
argocd-2.12.1/
├── argo-cd/             # Helm 차트 원본 소스
├── images/              # 컨테이너 이미지 (.tar)
├── scripts/             # 이미지 업로드/다운로드 스크립트
├── values.yaml          # ArgoCD 설정 파일 (Harbor 및 Storage 설정)
├── nas-pv.yaml          # NAS(NFS) 사용 시 필요한 PV/PVC 정의서
├── install-argocd.sh    # ArgoCD 설치 자동화 스크립트
└── README.md            # 이 가이드 파일
```

---

## 1. 준비 사항 (이미 완료됨)
인터넷망에서 필요한 자원들이 이미 다운로드되어 `argocd-2.12.1/` 폴더에 준비되어 있습니다.
- **Helm 차트**: v7.4.1 (ArgoCD v2.12.1 대응)
- **컨테이너 이미지**: `argocd`, `redis`, `haproxy` (.tar 파일)

---

## 2. 이미지 업로드 (폐쇄망 Harbor)
폐쇄망에 위치한 Harbor 레지스트리에 준비된 이미지를 업로드합니다.

1. `scripts/upload_images.sh` 파일 상단 Config 블록을 수정합니다.
   ```bash
   HARBOR_REGISTRY="harbor.local:30002"  # 실제 Harbor 주소
   HARBOR_PROJECT="goe"                  # 프로젝트명
   HARBOR_USER="admin"                   # 로그인 정보
   HARBOR_PASSWORD="password"
   ```
2. 스크립트 실행:
   ```bash
   cd scripts
   chmod +x upload_images.sh
   ./upload_images.sh
   ```

---

## 3. 설치 스크립트 설정 후 실행
`install-argocd.sh` 파일 상단 **Config 블록 하나만** 수정하면 Harbor 경로, 스토리지 방식이 모두 자동 적용됩니다.

```bash
# ==================== Config ====================
# Harbor Registry
HARBOR_REGISTRY="harbor.local:30002"   # 실제 Harbor 주소로 변경
HARBOR_PROJECT="goe"                   # 실제 프로젝트명으로 변경

# Storage: "none" | "nas" | "hostpath"
STORAGE_TYPE="none"                    # 스토리지 방식 선택

# NAS (NFS) Settings - STORAGE_TYPE="nas" 일 때 사용
NAS_SERVER="192.168.1.100"             # 실제 NAS IP로 변경
NAS_REDIS_PATH="/nas/argocd/redis"
NAS_REPO_PATH="/nas/argocd/repo"

# hostPath Settings - STORAGE_TYPE="hostpath" 일 때 사용
HOSTPATH_REDIS="/data/argocd/redis"
HOSTPATH_REPO="/data/argocd/repo-cache"
# ================================================
```

설정 완료 후 실행:
```bash
chmod +x install-argocd.sh
./install-argocd.sh
```

설치 확인:
```bash
kubectl get pods -n argocd
```

---

## 5. 설치 후 작업

### 외부 접속 (UI)
기본적으로 `ClusterIP`로 설치됩니다. 포트 포워딩을 통해 임시로 접속하거나 Ingress 설정을 추가하세요.
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### 초기 Admin 비밀번호 확인
설치 직후 생성되는 임시 비밀번호를 확인합니다.
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 주의 사항
- `values.yaml`의 `harbor.local:30002` 주소는 실제 환경에 맞춰 반드시 확인 및 수정이 필요합니다.
- NAS 사용 시 NFS 클라이언트가 모든 워커 노드에 설치되어 있어야 합니다.
