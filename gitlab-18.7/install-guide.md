# GitLab v18.7 오프라인 설치 가이드

폐쇄망 환경에서 GitLab EE v18.7을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- (도메인 접속 사용 시) Envoy Gateway 또는 Ingress-Nginx 설치 완료

## 디렉토리 구조

| 경로 | 설명 |
| :--- | :--- |
| `gitlab/` | GitLab Helm 차트 |
| `images/` | GitLab 컨테이너 이미지 `.tar` 파일 |
| `install-gitlab.sh` | 설치 자동화 스크립트 |
| `install-gitlab-values.yaml` | Helm values 설정 파일 |
| `gitlab-pv.yaml` | PV 정의 파일 (Gitaly, PostgreSQL, MinIO, Redis) |
| `gitlab-httproutes.yaml` | HTTPRoute 정의 파일 (Envoy Gateway 사용 시) |
| `setup-host-dirs.sh` | 호스트 디렉토리 사전 생성 스크립트 |

## Phase 1: 호스트 디렉토리 생성

PV 데이터 저장 경로를 대상 노드에 미리 생성합니다.

```bash
chmod +x setup-host-dirs.sh
./setup-host-dirs.sh
```

## Phase 2: Harbor에 이미지 업로드

`images/upload_images_to_harbor_v3-lite.sh` 상단 Config를 수정한 후 실행합니다.

```bash
cd images

# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : . (현재 디렉터리의 .tar 파일을 직접 사용)
# HARBOR_REGISTRY: <NODE_IP>:30002
# HARBOR_PROJECT : <PROJECT>
# HARBOR_USER    : admin
# HARBOR_PASSWORD: <Harbor 관리자 비밀번호>

chmod +x upload_images_to_harbor_v3-lite.sh
./upload_images_to_harbor_v3-lite.sh
cd ..
```

## Phase 3: PV 파일 설정

`gitlab-pv.yaml` 에서 아래 항목을 환경에 맞게 수정합니다.

| 항목 | 설명 |
| :--- | :--- |
| `nodeAffinity` 노드명 | PV가 위치할 워커 노드 이름 |
| `hostPath.path` | 호스트 데이터 저장 경로 |
| `storage` 용량 | Gitaly: 50Gi, PostgreSQL: 10Gi, MinIO: 10Gi, Redis: 10Gi |

## Phase 4: install-gitlab.sh 설정

`install-gitlab.sh` 상단 Config 블록을 환경에 맞게 수정합니다.

| 변수 | 설명 | 예시 |
| :--- | :--- | :--- |
| `NAMESPACE` | GitLab 설치 네임스페이스 | `gitlab` |
| `RELEASE_NAME` | Helm release 이름 | `gitlab` |
| `HARBOR_REGISTRY` | Harbor 레지스트리 주소 | `<NODE_IP>:30002` |
| `HARBOR_PROJECT` | Harbor 프로젝트 이름 | `library` |
| `DOMAIN` | CoreDNS 등록 도메인 (`""` 이면 등록 안 함) | `gitlab.devops.internal` |

> DNS 서버 없이 도메인을 사용하는 경우 `DOMAIN`을 설정하면 스크립트가 클러스터 내부 CoreDNS에
> 자동으로 등록합니다. 클라이언트(PC) `/etc/hosts`는 별도로 추가해야 합니다.

## Phase 5: 설치 실행

```bash
chmod +x install-gitlab.sh
./install-gitlab.sh
```

스크립트 실행 중 아래 항목을 인터랙티브하게 입력합니다.

1. Ingress 방식 선택 (NGINX Ingress / Envoy Gateway HTTPRoute)
2. GitLab을 배포할 노드 이름 (Enter 입력 시 자동 배치)

스크립트가 자동으로 처리하는 항목:

- 기존 리소스 정리 (Helm release, PV, Namespace)
- HTTPRoute 적용 (Envoy Gateway 선택 시)
- PV 생성 및 노드 라벨 적용
- Harbor 이미지 경로 오버라이드 파일 자동 생성
- Helm 배포
- CoreDNS에 `DOMAIN` 등록 (`DOMAIN` 설정 시)

## Phase 6: 설치 확인

```bash
kubectl get pods -n gitlab
kubectl get pv | grep gitlab
kubectl get svc -n gitlab
```

`gitlab-migrations` 및 `gitlab-minio-create-buckets` Job이 성공해야 합니다.

```bash
kubectl get jobs -n gitlab
```

## Phase 7: 초기 접속

초기 root 비밀번호 확인:

```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath="{.data.password}" | base64 -d && echo
```

| 항목 | 값 |
| :--- | :--- |
| 접속 주소 | `http://<NODE_IP>` (Ingress 노드 IP) 또는 설정한 도메인 |
| 계정 | `root` |
| 비밀번호 | 위 명령으로 확인 |
