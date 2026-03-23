# ArgoCD v2.12.1 오프라인 설치 명세

본 문서는 **ArgoCD v2.12.1** 폐쇄망 Kubernetes 환경 구성 명세를 정의합니다.

## 버전 정보

| 항목 | 사양 | 비고 |
| :--- | :--- | :--- |
| **ArgoCD Version** | **2.12.1** | GitOps CD 플랫폼 |
| **Helm Chart** | **v7.4.1** | argo-cd Helm 차트 버전 |
| **대상 OS** | Rocky Linux 9.6 | 클러스터 호스트 OS |

## 포함 컨테이너 이미지

| 이미지 | 용도 |
| :--- | :--- |
| `argocd` | ArgoCD 핵심 컴포넌트 (서버, 컨트롤러, repo-server 등) |
| `redis` | ArgoCD 캐시 스토리지 |
| `haproxy` | Redis HA 프록시 |

## 스토리지 구성

| 스토리지 타입 | 설명 |
| :--- | :--- |
| `none` | 영구 저장소 없음 (재시작 시 캐시 초기화) |
| `hostpath` | 노드 호스트 경로 기반 저장 (기본값) |
| `nas` | NFS 기반 NAS 저장 (NFS 클라이언트 설치 필요) |

## 네트워크 접속 정보

| 방법 | 포트/주소 | 비고 |
| :--- | :--- | :--- |
| NodePort | `<NODE_IP>:30001` | 기본 NodePort |
| HTTPRoute (도메인) | `http://argocd.devops.internal` | Envoy Gateway 연동 시 |
| 포트 포워딩 (임시) | `localhost:8080` | `kubectl port-forward` 사용 |

## 주요 컴포넌트

| 컴포넌트 | 역할 |
| :--- | :--- |
| `argocd-server` | 웹 UI 및 API 서버 |
| `argocd-repo-server` | Git 저장소 연결 및 매니페스트 처리 |
| `argocd-application-controller` | K8s 상태 모니터링 및 동기화 |
| `argocd-applicationset-controller` | ApplicationSet 처리 |
| `argocd-notifications-controller` | 알림 처리 |
| `redis` | 내부 캐시 |

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `argo-cd/` | Helm 차트 원본 |
| `images/` | 컨테이너 이미지 `.tar` 파일 및 `upload_images_to_harbor_v3-lite.sh` |
| `scripts/` | 이미지 다운로드/업로드 스크립트 |
| `values.yaml` | ArgoCD Helm 설정 |
| `nas-pv.yaml` | NAS(NFS) 사용 시 PV/PVC 정의 |
| `install.sh` | 설치 자동화 스크립트 |
| `uninstall.sh` | 삭제 자동화 스크립트 |
| `argocd-nodeport-svc.yaml` | NodePort 서비스 정의 (참고용) |
| `argocd-httproute.yaml` | HTTPRoute 정의 (참고용) |

## 보안 참고

- `server.insecure: true` 설정으로 HTTP 서비스 중 (TLS는 Envoy Gateway에서 처리)
- 초기 비밀번호는 최초 로그인 후 반드시 변경하고 Secret을 삭제해야 합니다.
