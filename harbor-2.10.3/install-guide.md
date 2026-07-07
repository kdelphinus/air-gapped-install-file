# 🚀 Harbor v2.10.3 오프라인 설치 가이드

폐쇄망 환경에서 Harbor v2.10.3을 Kubernetes 위에 Helm으로 설치하는 절차를 안내합니다.

## Phase 0: 인터넷 연결 호스트에서 에셋 다운로드

폐쇄망 환경으로 반입하기 전에, 인터넷이 연결된 외부망 호스트에서 아래 스크립트를 실행하여 Helm 차트와 컨테이너 이미지들을 다운로드합니다.

```bash
# 컴포넌트 루트 디렉토리에서 실행
sudo ./scripts/download_assets_offline.sh
```

- 스크립트 실행이 완료되면 `charts/` 폴더에 Helm 차트가, `images/` 폴더에 9개의 Harbor 구동용 컨테이너 이미지 `.tar` 파일이 다운로드됩니다.
- 다운로드 완료 후 컴포넌트 디렉토리를 압축하여 폐쇄망 내부로 이관합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료 (master + worker)
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 설치용 이미지 `.tar` 및 Helm 차트 준비 완료 (Phase 0을 통해 다운로드)

## 설치 전 필수 확인 사항

- **NodePort로 직접 접속 시**: Harbor 접속 URL에 NodePort를 포함합니다. 예: `http://<NODE_IP>:30002`
- **Envoy 또는 Ingress로 접속 시**: Harbor 접속 URL에 실제 외부 도메인 또는 VIP를 입력합니다.
- **TLS 도메인 접속 시**: 사전에 인증서로 Kubernetes Secret 생성 필요, 접속 URL의 호스트명과 인증서 도메인이 일치해야 합니다.
- **저장 경로**: `SAVE_PATH` (데이터 저장 경로)는 `NODE_NAME` 노드에서 디렉토리가 생성되어 있어야 함 (권한: `chmod 777`)

## 1단계: 구성 이미지 로드 (ctr import)

하버가 설치되기 전이므로, 하버 구성 이미지들을 **모든 Kubernetes 노드(Master, Worker)**에서 직접 로컬 `containerd`에 로드해야 합니다.

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
chmod +x scripts/load_images.sh
sudo ./scripts/load_images.sh
```

이미지 로드 확인:

```bash
sudo ctr -n k8s.io images list | grep harbor
```

## 2단계: 설치 및 환경 정보 입력

`install.sh`를 구동하면, 환경 정보가 대화식 인터프리터 프롬프트(CLI)로 안전하게 수집됩니다. 스크립트 파일을 직접 수정할 필요 없이, 입력된 변수 값은 컴포넌트 루트의 `install.conf` 및 `values-infra.yaml`에 보존되어 멱등성 있는 생명주기 제어가 가능하게 관리됩니다.

| 인프라 환경 변수 | 설명 | 예시 |
| :--- | :--- | :--- |
| `EXTERNAL_HOSTNAME` | Harbor 외부 접속 도메인명 또는 IP 주소 | `harbor.devops.internal` 또는 `<NODE_IP>` |
| `TLS_ENABLED` / `TLS_SECRET_NAME` | 외부 HTTPS TLS 적용 여부 및 인증서 Secret 명 | `true` / `harbor-tls-secret` |
| `STORAGE_MODE` | 볼륨 백엔드 모드 (HostPath 정적 / NFS 정적 / NFS SC 동적) | `hostpath`, `nfs`, `nfs-dynamic` |
| `SAVE_PATH` / `NODE_NAME` | HostPath 볼륨 사용 시 디렉토리 경로 및 매핑 노드명 | `/data/harbor` / `worker-01` |
| `NFS_SERVER` / `NFS_PATH` | NFS 정적 PV 매핑 서버 IP 및 내보내기 디렉토리 경로 | `192.168.1.100` / `/nfs/harbor` |
| `STORAGE_CLASS` | NFS 동적 프로비저닝을 위한 K8s StorageClass 명칭 | `nfs-client` |
| `MINIMIZE_RESOURCES` | 개발/검증 목적의 리소스(Limits/Requests) 제한 최소화 여부 | `true` (기본값 `false`) |

## 3단계: 설치 실행 및 대화형 설정

```bash
chmod +x scripts/install.sh scripts/uninstall.sh
./scripts/install.sh
```

스크립트 실행 중 아래 항목을 인터랙티브하게 선택/입력합니다.

1. **이미지 로드 방식 선택**:
   - **`1` 로컬 tar 직접 import (권장)**: 하버가 아직 설치되지 않은 최초 기동 단계에 선택하며 `images/*.tar`를 자동으로 임포트합니다.
   - **`2` 로컬 이미지 수동 로드 완료**: 이미 각 노드에 컨테이너 이미지 캐싱이 완료된 경우 스킵할 때 사용합니다.
2. **노출 방식 선택**:
   - **`1` Envoy Gateway (기본)**: `http://harbor.devops.internal` 등 Envoy HTTPRoute를 통해 외부 주소 해석을 매핑할 도메인을 수집합니다.
   - **`2` NodePort 직접 접속**: 포트 포워딩 또는 로컬 노드 포트로 직접 타겟팅해 기동합니다. (기본 HTTP 30002, HTTPS 30003 포트 오버라이드 가능)
   - **`3` nginx Ingress**: 인그레스 제어기를 활용해 도메인 접근을 처리합니다.
3. **리소스 사양 설정**:
   - **개발 환경 리소스 최소화 (y/N)**: 가상머신 등 리소스가 한정된 로컬 개발 장비에서 테스트할 경우, nginx/core/database 등 주요 파드의 Requests/Limits 제한을 최하위 사양(64Mi/128Mi 단위)으로 축소 오버라이드하여 가동 안정성을 확보합니다.
4. **스토리지 타입 선택**:
   - **`1` HostPath**: 특정 단일 노드의 로컬 디렉토리를 정적 PV로 사용합니다. 고정 타겟 노드 이름과 로컬 호스트 절대 경로를 지정합니다.
   - **`2` NFS 정적 할당**: NFS 서버 및 익스포트 디렉토리를 입력받아 정적 PV/PVC를 생성합니다.
   - **`3` NFS SC 동적 할당**: 클러스터의 StorageClass와 컴포넌트별 개별 DB/Redis 용량을 조절해 자동 스토리지 프로비저닝을 위임합니다.
5. **Harbor 관리자(`admin`) 비밀번호**: 최초/재설치 시에만 대화식으로 패스워드 입력을 요구하며, 평문으로 설정파일에 저장되지 않고 보안을 보존합니다. (Upgrade 시에는 기존 K8s Secret에서 자동 추출 및 상속 기동)

> **주의**: 기존 `install.conf`가 있는 상태에서 `업그레이드`를 선택하면 저장된 `STORAGE_MODE`를 그대로 사용합니다. HostPath에서 NFS 정적 또는 Dynamic으로 바꾸려면 `재설치` 또는 `초기화`를 선택해 스토리지 설정을 다시 입력하세요.

## 4단계: Envoy HTTPRoute 적용 (Envoy Gateway 선택 시)

`manifests/route-harbor.yaml`의 `hostnames`와 `parentRefs.name`을
실제 환경에 맞게 수정 후 적용합니다.

```bash
# hostnames: 를 실제 도메인으로 수정 후:
kubectl apply -f manifests/route-harbor.yaml
```

## 4단계: (TLS 미사용 시) Insecure Registry 등록

HTTP로 Harbor를 사용하는 경우, **모든 K8s 노드(Master + Worker)**에서 containerd가 해당 레지스트리를 신뢰하도록 등록해야 합니다. 이 설정이 없으면 이미지 push/pull 시 `http: server gave HTTP response to HTTPS client` 오류가 발생합니다.

자동화 스크립트를 사용하거나, 아래 수동 절차를 참고하세요.

### 방법 1: 스크립트 사용 (권장)

각 노드에서 실행합니다.

```bash
chmod +x scripts/insecurity_registry_add.sh
sudo ./scripts/insecurity_registry_add.sh
```

### 방법 2: 수동 설정

#### 1. containerd 버전 확인

containerd v2.x에서 CRI 플러그인 경로가 변경되었습니다. 버전에 따라 `config.toml`에 작성해야 할 섹션 키가 다르므로 반드시 먼저 확인하세요.

```bash
containerd --version
```

#### 2. containerd config.toml에 config_path 추가

`/etc/containerd/config.toml`을 열어 **containerd 버전에 맞는 섹션**에 `config_path`를 추가합니다.

```toml
# containerd v1.x
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"

# containerd v2.x (플러그인 키 변경됨)
[plugins."io.containerd.cri.v1.images".registry]
  config_path = "/etc/containerd/certs.d"
```

어떤 키가 사용되고 있는지 모르겠다면 아래 명령으로 확인합니다.

```bash
grep -n 'io.containerd' /etc/containerd/config.toml | grep -i 'cri\|registry'
```

- v1.x 키(`grpc.v1.cri`)에 설정했는데 실제 containerd가 v2.x라면 `config_path`가 **무시**되어 insecure registry가 동작하지 않습니다.
- 이미 해당 섹션이 있다면 `config_path` 줄만 추가하거나 값을 수정합니다. 빈 값(`config_path = ''`)이 설정되어 있다면 위 경로로 교체하세요.

#### 2. hosts.toml 생성

레지스트리 주소에 맞는 디렉토리를 만들고 `hosts.toml`을 작성합니다.

```bash
# 예시: Harbor가 172.30.235.20:30002 인 경우
sudo mkdir -p /etc/containerd/certs.d/172.30.235.20:30002

sudo tee /etc/containerd/certs.d/172.30.235.20:30002/hosts.toml <<'EOF'
server = "http://172.30.235.20:30002"

[host."http://172.30.235.20:30002"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
```

#### 3. containerd 재시작

```bash
sudo systemctl restart containerd
```

#### 4. 설정 확인

```bash
grep "config_path" /etc/containerd/config.toml
cat /etc/containerd/certs.d/172.30.235.20:30002/hosts.toml
```

## 5단계: (선택) Self-Signed TLS 인증서 생성

nginx Ingress + TLS 사용 시 자체 서명 인증서가 필요한 경우 생성합니다.

```bash
chmod +x scripts/create_self-signed_tls.sh
./scripts/create_self-signed_tls.sh
```

## 6단계: (선택) Harbor CA 인증서 시스템 등록 (HTTPS 사용 시)

Self-Signed 또는 사설 CA를 통해 HTTPS Harbor를 구성한 경우, **모든 K8s 노드 및 클라이언트**에서 해당 인증서를 신뢰하도록 등록해야 합니다.

### 1. OS 시스템 신뢰 등록 (전체 노드)

```bash
# 1. Harbor 서버에서 생성된 ca.crt 파일을 가져옵니다.
# (임시로 /tmp/ca.crt에 있다고 가정)

# 2. 신뢰할 수 있는 인증서 앵커 디렉토리로 복사 (Rocky/RHEL 계열)
sudo cp /tmp/ca.crt /etc/pki/ca-trust/source/anchors/harbor-ca.crt

# 3. 시스템 인증서 저장소 업데이트
sudo update-ca-trust
```

### 2. containerd 전용 인증서 위치 지정 (전체 노드)

OS 신뢰 등록 외에도 `containerd`가 해당 도메인에 대해 이 인증서를 명확히 참조하도록 설정해야 합니다. (4단계의 `config_path` 설정이 완료된 상태여야 합니다.)

```bash
# Harbor 도메인 변수 설정 (예: harbor.internal 또는 IP:Port)
HARBOR_DOMAIN="<EXTERNAL_HOSTNAME>"

# 인증서 디렉토리 생성 및 복사
sudo mkdir -p /etc/containerd/certs.d/$HARBOR_DOMAIN
sudo cp /etc/pki/ca-trust/source/anchors/harbor-ca.crt /etc/containerd/certs.d/$HARBOR_DOMAIN/ca.crt

# (필요 시) containerd 재시작
sudo systemctl restart containerd
```

> **주의**: 4단계에서 설명한 `/etc/containerd/config.toml` 내 `config_path` 설정이 `/etc/containerd/certs.d`를 바라보고 있는지 반드시 확인하세요.

> **참고**: Ubuntu/Debian 계열의 경우 `/usr/local/share/ca-certificates/harbor-ca.crt`로 복사 후 `sudo update-ca-certificates` 명령어를 사용합니다.

## 7단계: (선택) Trivy 취약점 DB 수동 반입

에어갭 환경에서는 Trivy가 인터넷을 통해 취약점 DB를 업데이트할 수 없습니다. 보안 스캔 기능을 사용하려면 수동으로 DB를 반입해야 합니다.

1.  **외부망**에서 아래 두 파일을 다운로드합니다.
    *   [Vulnerability DB](https://github.com/aquasecurity/trivy-db/releases/latest/download/trivy-offline-db.tgz) (파일명: `trivy-db.tar.gz`로 저장)
    *   [Java DB](https://github.com/aquasecurity/trivy-java-db/releases/latest/download/javadb.tar.gz) (파일명: `trivy-java-db.tar.gz`로 저장)
2.  다운로드한 두 파일을 Harbor 컴포넌트 루트(`harbor-2.10.3/`) 폴더에 넣습니다.
3.  반입 스크립트를 실행합니다.
    ```bash
    chmod +x scripts/import_trivy_db.sh
    ./scripts/import_trivy_db.sh
    ```

반입이 완료되면 Harbor UI에서 이미지를 선택하고 **[Scan]** 버튼을 눌러 보안 검사를 수행할 수 있습니다.

## 이미지 Push 예시

```bash
# 1. 이미지 import (로컬 .tar → containerd k8s.io 네임스페이스)
sudo ctr -n k8s.io images import my-image.tar

# 2. Tag (Harbor 대상 주소로 변환)
sudo ctr -n k8s.io images tag \
  docker.io/library/my-image:v1 \
  <NODE_IP>:30002/library/my-image:v1

# 3. Push (HTTP 사용 시 --plain-http 추가)
sudo ctr -n k8s.io images push \
  --plain-http \
  --user admin:<PASSWORD> \
  <NODE_IP>:30002/library/my-image:v1
```

## 삭제 및 리셋

```bash
# 기본 삭제 (설정 및 생성된 인프라 values 파일 유지)
./scripts/uninstall.sh

# 완전 리셋 (저장된 설정 및 인프라 values 파일도 모두 삭제)
./scripts/uninstall.sh --reset
```

## 보안 고려사항

- **비밀번호 정책**: 관리자 비밀번호는 최소 8자 이상 설정 (install.sh에서 검증)
- **TLS 권장**: 운영 환경에서는 외부 TLS + 내부 TLS 모두 활성화 권장
  (`internalTLS.enabled: true`)
- **자격 증명 관리**: 스크립트에 비밀번호를 직접 기재하지 않고,
  환경변수 또는 실행 시 프롬프트 사용
- **Insecure Registry**: TLS 미사용 시
  `insecurity_registry_add.sh`로 등록하되,
  신뢰할 수 있는 네트워크에서만 사용
- **Trivy 스캔**: 폐쇄망에서는 Trivy DB를 OCI artifact로
  반입 후 활성화 가능 (`values.yaml` 주석 참조)

## 트러블슈팅

- **Pod CrashLoopBackOff**: PV 마운트 경로 권한(`chmod 777`) 확인, 비밀번호 불일치 여부 점검
- **이미지 Push 실패**: 모든 노드에서 insecure registry 등록 여부 확인 (`scripts/insecurity_registry_add.sh`)
- **TLS 인증서 오류**: Secret 이름과 `EXTERNAL_HOSTNAME` 도메인 일치 여부, 인증서 만료일 확인
- **PVC Pending**: `NODE_NAME`이 실제 노드 이름과 일치하는지, nodeAffinity 설정 확인

## 부록: HTTP Harbor 로그인 및 Pull 확인

HTTP Harbor를 사용할 때 이미지 주소에는 `http://` 또는 `https://` 프로토콜을 포함하지 않습니다. 프로토콜은 클라이언트 옵션과 containerd registry 설정으로 처리합니다.

```text
좋은 예: harbor.example.local:30002/library/my-image:v1
나쁜 예: http://harbor.example.local:30002/library/my-image:v1
```

Harbor project가 public이면 Kubernetes에서 `imagePullSecrets` 없이 이미지를 pull할 수 있습니다. private project인 경우에는 애플리케이션 namespace에 `docker-registry` Secret을 생성하고 Pod 또는 ServiceAccount에 연결합니다.

```bash
kubectl create secret docker-registry harbor-regcred \
  --docker-server=<HARBOR_REGISTRY> \
  --docker-username=admin \
  --docker-password='<PASSWORD>' \
  -n <APP_NAMESPACE>
```

Docker 또는 Buildah로 HTTP Harbor에 로그인할 때는 HTTPS를 강제하지 않도록 옵션을 명시합니다.

```bash
printf '%s' '<PASSWORD>' | docker login <HARBOR_REGISTRY> \
  -u admin --password-stdin

buildah login --tls-verify=false \
  --username admin \
  --password '<PASSWORD>' \
  <HARBOR_REGISTRY>

buildah push --tls-verify=false <HARBOR_REGISTRY>/library/my-image:v1
```

containerd에서 직접 push할 때는 `--plain-http`를 사용합니다.

```bash
sudo ctr -n k8s.io images push \
  --plain-http \
  --user admin:<PASSWORD> \
  <HARBOR_REGISTRY>/library/my-image:v1
```

kind 클러스터처럼 Kubernetes 노드가 Docker 컨테이너로 실행되는 환경에서는 호스트가 아니라 kind 노드 컨테이너 안에서 insecure registry를 설정해야 합니다. 즉 `systemctl restart containerd`도 kind 노드 컨테이너 안에서 실행되어야 합니다.

```bash
KIND_NODE_NAME="test-cluster-worker"
HARBOR_REGISTRY="harbor.example.local:30002"

# hosts.toml 파일은 kind 노드 컨테이너 내부에 생성합니다.
docker exec "${KIND_NODE_NAME}" mkdir -p "/etc/containerd/certs.d/${HARBOR_REGISTRY}"

docker exec "${KIND_NODE_NAME}" sh -c "cat > '/etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml'" <<EOF
server = "http://${HARBOR_REGISTRY}"

[host."http://${HARBOR_REGISTRY}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

docker exec "${KIND_NODE_NAME}" systemctl restart containerd
```

실제 운영 환경에서는 위 예시의 `harbor.example.local:30002` 대신 DNS에 등록된 Harbor 도메인 또는 로드밸런서 주소를 사용합니다. DNS 서버에 등록하지 않았다면 Jenkins agent Pod의 `hostAliases`, Kubernetes worker 노드의 `/etc/hosts`, 또는 사내 DNS 중 하나로 동일한 이름이 해석되도록 맞춰야 합니다.

## Manual Installation & Upgrade

자동화 설치 스크립트(`install.sh`)를 사용하지 않고, 수동으로 Harbor 리소스 및 Helm 릴리스를 배포하고자 할 때 아래 절차를 수행합니다.

### 1. K8s 영구 스토리지(PV/PVC) 수동 생성

볼륨 구성을 위해 `manifests/harbor-persistence-infra.yaml` 파일을 수동으로 편집하여 작성한 뒤 적용합니다 (StorageClass를 사용할 경우 이 단계는 생략 가능).

```bash
# PV 및 PVC 리소스 배포
kubectl apply -f manifests/harbor-persistence-infra.yaml
```

### 2. Helm 오버라이드 설정 파일 생성 (`values-infra.yaml`)

패스워드 정보를 제외한 인프라 사양을 `values-infra.yaml`에 작성합니다.

```yaml
# values-infra.yaml 수동 예시
externalURL: http://harbor.devops.internal:30002

expose:
  type: nodePort
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: 30002

persistence:
  enabled: true
  resourcePolicy: "keep"
  persistentVolumeClaim:
    registry:
      existingClaim: "harbor-pvc"
      subPath: registry
    database:
      existingClaim: "harbor-pvc"
      subPath: database
    jobservice:
      jobLog:
        existingClaim: "harbor-pvc"
        subPath: jobservice-logs
    redis:
      existingClaim: "harbor-pvc"
      subPath: redis
    trivy:
      existingClaim: "harbor-pvc"
      subPath: trivy
```

### 3. Helm 차트 수동 설치 및 업그레이드

컴포넌트 루트 디렉토리에서 Helm 명령어를 사용하여 릴리스를 배포합니다. 비밀번호(`harborAdminPassword`)는 보안을 위해 명령줄 파라미터(`--set`)로 직접 주입합니다.

```bash
# 1. Harbor 네임스페이스 생성
kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -

# 2. Helm 설치 및 업그레이드 구동
helm upgrade --install harbor ./charts/harbor \
  --namespace harbor \
  -f ./values.yaml \
  -f ./values-infra.yaml \
  --set harborAdminPassword="<원하는_비밀번호_입력>" \
  --atomic \
  --wait
```
