# GitLab v18.7 오프라인 설치 가이드

폐쇄망 환경에서 GitLab v18.7을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- (도메인 접속 사용 시) Envoy Gateway 또는 Ingress-Nginx 설치 완료

## Values 파일 구조

Helm 배포는 세 가지 values 파일을 순서대로 병합합니다. 뒤에 오는 파일이 앞의 값을 덮어씁니다.

| 순서 | 파일 | 관리 주체 | 역할 |
| :--- | :--- | :--- | :--- |
| 1 | `values.yaml` | 수동 편집 | 도메인·IP·Ingress·스토리지 등 환경 기본 설정 |
| 2 | `gitlab-components.yaml` | 스크립트 자동 생성 | 선택 설치 컴포넌트 on/off |
| 3 | `gitlab-images-override.yaml` | 스크립트 자동 생성 | Harbor 이미지 경로 오버라이드 |

`gitlab-components.yaml`과 `gitlab-images-override.yaml`은 설치·업그레이드 스크립트가 자동으로 생성합니다.
직접 Helm 명령어를 실행할 때는 세 파일을 명시적으로 `-f` 옵션으로 나열합니다.

### 선택 설치 컴포넌트

`gitlab-components.yaml`로 제어하는 선택적 컴포넌트 목록입니다.
스크립트 실행 중 인터랙티브하게 선택하거나, 파일을 직접 편집해 적용할 수 있습니다.

| 컴포넌트 | 기본값 | 필요한 경우 |
| :--- | :--- | :--- |
| 컨테이너 레지스트리 | 비활성화 | GitLab에서 Docker 이미지 Push/Pull 필요 시 |
| KAS (Kubernetes Agent) | 비활성화 | GitLab에서 K8s 클러스터 직접 연동 필요 시 |
| Cert Manager | 비활성화 | HTTPS/TLS 인증서 자동 관리 필요 시 |
| GitLab Runner | 비활성화 | CI/CD 파이프라인 자동 실행 필요 시 |
| Prometheus / Exporter | 비활성화 | 리소스 모니터링 필요 시 |

> 선택 컴포넌트 활성화 시 해당 이미지를 Harbor에 사전 업로드해야 합니다.

## 1단계: 호스트 디렉토리 생성

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다. PV 데이터 저장 경로를 대상 노드에 미리 생성합니다.

```bash
chmod +x scripts/setup-host-dirs.sh
./scripts/setup-host-dirs.sh
```

## 2단계: 이미지 Harbor 업로드

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 3단계: 운영 설정

환경에 맞게 아래 파일들을 수정합니다.

| 파일명 | 용도 | 주요 수정 항목 |
| :--- | :--- | :--- |
| **`values.yaml`** | 환경 기본 설정 | 도메인, 노드 IP, Ingress 방식, 스토리지 |
| **`manifests/gitlab-pv.yaml`** | 영구 저장소(PV) 정의 | 노드 이름(`nodeAffinity`), 저장 경로 |
| **`manifests/gitlab-httproutes.yaml`** | Envoy용 라우팅 설정 | 도메인 이름, 게이트웨이 참조 |

## 4단계: 설치 실행

### 스크립트로 설치 (권장)

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 다음 항목을 선택/입력합니다:

1. **이미지 소스**: Harbor 레지스트리 또는 로컬 tar import
2. **선택적 컴포넌트**: 레지스트리, KAS, Cert Manager, Runner, Prometheus
3. **Ingress 방식**: NGINX Ingress 또는 Envoy Gateway
4. **대상 노드**: GitLab을 배치할 특정 노드 이름 (생략 시 자동 스케줄링)

스크립트 완료 후 생성되는 파일:

- `gitlab-components.yaml` — 선택한 컴포넌트 상태
- `gitlab-components-state.sh` — 업그레이드 시 재사용할 상태 변수
- `gitlab-images-override.yaml` — Harbor 이미지 경로 (Harbor 모드 선택 시)

### 직접 Helm 명령어로 설치

스크립트 없이 직접 실행할 경우, 세 파일을 순서대로 `-f`로 지정합니다.

```bash
NAMESPACE=gitlab
RELEASE=gitlab
HARBOR=<NODE_IP>:30002
PROJECT=library

# 1. 네임스페이스 및 PV 생성
kubectl create ns ${NAMESPACE}
kubectl apply -f manifests/gitlab-pv.yaml

# 2. gitlab-components.yaml 수동 작성 (선택 컴포넌트 결정)
#    활성화할 항목만 true로 변경 후 저장
cat > gitlab-components.yaml <<EOF
global:
  registry:
    enabled: false   # 컨테이너 레지스트리
  kas:
    enabled: false   # Kubernetes Agent Server
certmanager:
  install: false     # TLS 인증서 관리
gitlab-runner:
  install: false     # CI/CD Runner
prometheus:
  install: false     # 모니터링
gitlab:
  gitlab-exporter:
    enabled: false
EOF

# 3. gitlab-images-override.yaml 수동 작성 (Harbor 이미지 경로)
cat > gitlab-images-override.yaml <<EOF
global:
  image:
    registry: ${HARBOR}
    pullPolicy: IfNotPresent
  kubectl:
    image:
      repository: ${HARBOR}/${PROJECT}/kubectl
  certificates:
    image:
      repository: ${HARBOR}/${PROJECT}/certificates
  gitlabBase:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-base
gitlab:
  webservice:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-webservice-ce
    workhorse:
      image: "${HARBOR}/${PROJECT}/gitlab-workhorse-ce"
  sidekiq:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-sidekiq-ce
  toolbox:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-toolbox-ce
  gitlab-shell:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-shell
  gitaly:
    image:
      repository: ${HARBOR}/${PROJECT}/gitaly
  gitlab-exporter:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-exporter
  kas:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-kas
  migrations:
    image:
      repository: ${HARBOR}/${PROJECT}/gitlab-toolbox-ce
minio:
  image: "${HARBOR}/${PROJECT}/minio"
  imageTag: "RELEASE.2017-12-28T01-21-00Z"
  makeBucketJob:
    image:
      repository: "${HARBOR}/${PROJECT}/mc"
      tag: "RELEASE.2018-07-13T00-53-22Z"
postgresql:
  image:
    registry: ${HARBOR}
    repository: ${PROJECT}/postgresql
    tag: "16.2.0"
redis:
  image:
    registry: ${HARBOR}
    repository: ${PROJECT}/redis
    tag: "7.2.4"
registry:
  image:
    repository: ${HARBOR}/${PROJECT}/gitlab-container-registry
upgradeCheck:
  image:
    repository: ${HARBOR}/${PROJECT}/gitlab-base
EOF

# 4. Helm 설치
helm upgrade --install ${RELEASE} ./charts/gitlab \
  -f values.yaml \
  -f gitlab-components.yaml \
  -f gitlab-images-override.yaml \
  --namespace ${NAMESPACE} \
  --timeout 600s
```

## 5단계: 설치 확인

```bash
# 파드 및 서비스 상태 확인
kubectl get pods,svc -n gitlab

# 마이그레이션 Job 성공 여부 확인
kubectl get jobs -n gitlab
```

## 6단계: 초기 접속

초기 `root` 비밀번호 확인:

```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath="{.data.password}" | base64 -d && echo
```

| 항목 | 값 |
| :--- | :--- |
| **접속 주소** | `http://<NODE_IP>` 또는 설정한 도메인 |
| **관리자 계정** | `root` |
| **비밀번호** | 위 명령으로 확인한 값 |

> **보안 권고**: 최초 로그인 후 비밀번호를 즉시 변경하십시오.

## 업그레이드

### 스크립트로 업그레이드 (권장)

```bash
./scripts/upgrade.sh
```

이전 설치 시 저장된 `gitlab-components-state.sh`를 읽어 선택한 컴포넌트 상태를 자동으로 복원합니다.
유지 여부를 확인한 뒤, 변경이 필요하면 해당 항목만 다시 선택할 수 있습니다.

### 직접 Helm 명령어로 업그레이드

```bash
# gitlab-components.yaml 이 이미 있으면 그대로 재사용
helm upgrade gitlab ./charts/gitlab \
  -f values.yaml \
  -f gitlab-components.yaml \
  -f gitlab-images-override.yaml \
  --namespace gitlab \
  --timeout 600s
```

롤백이 필요한 경우:

```bash
helm rollback gitlab -n gitlab
```

## 삭제

```bash
./scripts/uninstall.sh
```
