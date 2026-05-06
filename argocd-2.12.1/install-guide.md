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

## 2단계: 설치 실행 (대화형)

설치 스크립트는 실행 시 필요한 설정값(이미지 소스, 스토리지 유형 등)을 대화형 프롬프트로 입력받습니다.

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

### 주요 입력 항목 안내

1. **이미지 소스**: Harbor 레지스트리를 사용할지, 로컬에 이미 로드된 이미지를 사용할지 선택합니다.
2. **스토리지 유형**: 
   - `hostpath`: 워커 노드의 로컬 디스크 경로를 사용합니다.
   - `nas`: NFS 서버의 특정 경로를 직접 매핑합니다 (정적 할당).
   - `nfs-dynamic`: 사전에 정의된 `StorageClass`를 통해 볼륨을 자동 할당받습니다.
   - `none`: 별도의 영구 저장소를 사용하지 않습니다.

## 3단계: 설치 확인

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
