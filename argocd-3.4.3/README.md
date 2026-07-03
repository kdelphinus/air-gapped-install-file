# ArgoCD v3.4.3 오프라인 설치 명세

본 문서는 **ArgoCD v3.4.3** (Helm Chart **v9.5.21**) 폐쇄망 Kubernetes 환경 구성 명세를 정의합니다.

---

## 1. 버전 정보

| 항목 | 사양 | 비고 |
| :--- | :--- | :--- |
| **ArgoCD Version** | **v3.4.3** (최신 안정 버전) | GitOps CD 플랫폼 |
| **Helm Chart** | **v9.5.21** | argo-cd Helm 차트 버전 |
| **대상 OS** | Rocky Linux (RHEL-based) / Ubuntu (Debian-based) | 클러스터 호스트 OS |

---

## 2. 포함 컨테이너 이미지 (6종)

에어갭 오프라인 환경 구성을 위해 반입되어야 하는 전체 이미지 목록입니다.

| 이미지 명 | 버전 Tag | 용도 |
| :--- | :--- | :--- |
| `quay.io/argoproj/argocd` | `v3.4.4` | ArgoCD 핵심 컴포넌트 (서버, 컨트롤러, repo-server 등) |
| `ghcr.io/dexidp/dex` | `v2.45.1` | 외부 OIDC 및 ID 공급자 연동 (Dex SSO) |
| `ecr-public.aws.com/docker/library/redis` | `8.2.3-alpine` | ArgoCD 캐시 스토리지 |
| `ghcr.io/oliver006/redis_exporter` | `v1.86.0` | Redis 모니터링 메트릭 수집기 |
| `public.ecr.aws/docker/library/haproxy` | `3.0.8-alpine` | Redis HA 고가용성 구성 프록시 |
| `quay.io/argoprojlabs/argocd-extension-installer` | `v1.0.1` | ArgoCD 확장 기능(UI 등) 설치 도구 |

---

## 3. 스토리지 구성

| 스토리지 타입 | 설명 |
| :--- | :--- |
| `none` | 영구 저장소 없음 (재시작 시 캐시 초기화) |
| `hostpath` | 노드 호스트 경로 기반 저장 (기본값) |
| `nas` | NFS 기반 NAS 저장 (정적 PV/PVC 할당) |
| `nfs-dynamic` | NFS 기반 동적 할당 (StorageClass 필요) |

---

## 4. 네트워크 접속 정보

| 방법 | 포트/주소 | 비고 |
| :--- | :--- | :--- |
| NodePort | `<NODE_IP>:30001` | 기본 NodePort 노출 |
| HTTPRoute (도메인) | `http://argocd.devops.internal` | Envoy Gateway 연동 시 |
| 포트 포워딩 (임시) | `localhost:8080` | `kubectl port-forward` 사용 |

---

## 5. 디렉토리 구조

```text
argocd-3.4.3/
├── charts/          # Helm 차트 (argo-cd-9.5.21.tgz 원본 및 압축 해제 폴더)
├── images/          # 컨테이너 이미지 (.tar 파일) 및 Harbor 업로드 스크립트
│   └── upload_images_to_harbor_v3-lite.sh
├── manifests/       # 정적 K8s 매니페스트 (HTTPRoute, PV/PVC 정의)
│   ├── nas-pv.yaml
│   ├── argocd-nodeport-svc.yaml
│   └── argocd-httproute.yaml
├── scripts/         # 설치 및 운영 스크립트 (루트 상대 경로 실행 필수)
│   ├── install.sh
│   ├── uninstall.sh
│   └── download_assets_offline.sh
├── values.yaml      # 기본 설정 값 (Harbor 기반 이미지 경로 포함)
└── values.yaml.orig # values.yaml 백업 원본 (install.sh가 멱등성 보장용으로 사용)
```

---

## 6. 보안 권고 사항

- `server.insecure: true` 설정으로 HTTP 서비스 중 (TLS는 외부 Ingress나 Envoy Gateway에서 처리하는 것을 권장)
- 초기 비밀번호(`argocd-initial-admin-secret`)는 최초 로그인 후 반드시 변경하고 해당 Secret을 삭제해 주십시오.
