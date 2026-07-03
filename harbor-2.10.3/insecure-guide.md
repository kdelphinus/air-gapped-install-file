# Harbor Insecure Registry 등록

Harbor와 HTTP 통신을 위해 Insecure 등록이 필요합니다. 이 설정은 이미지를 push하거나 Kubernetes 노드가 이미지를 pull하는 런타임마다 적용해야 합니다.

## 설정

### 1. containerd 버전 확인

containerd v2.x에서 CRI 플러그인 경로가 변경되었습니다. 버전에 따라 `config.toml`에 작성해야 할 섹션 키가 다르므로 반드시 먼저 확인하세요.

```bash
containerd --version
```

### 2. containerd config.toml에 config_path 추가

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

### 2. hosts.toml 생성

레지스트리 주소에 맞는 디렉토리를 만들고 `hosts.toml`을 작성합니다.

```bash
# 예시: Harbor가 10.185.40.43:30002 인 경우
sudo mkdir -p /etc/containerd/certs.d/10.185.40.43:30002

sudo tee /etc/containerd/certs.d/10.185.40.43:30002/hosts.toml <<'EOF'
server = "http://10.185.40.43:30002"

[host."http://10.185.40.43:30002"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
```

### 3. containerd 재시작

```bash
sudo systemctl restart containerd
```

### 4. 설정 확인

```bash
grep "config_path" /etc/containerd/config.toml
cat /etc/containerd/certs.d/10.185.40.43:30002/hosts.toml
```

## 부록: Docker/Buildah 로그인 및 kind 노드 설정

HTTP Harbor 주소를 이미지 이름으로 사용할 때는 `http://` 또는 `https://`를 붙이지 않습니다.

```text
좋은 예: harbor.example.local:30002/library/sample-app:1.0.0
나쁜 예: http://harbor.example.local:30002/library/sample-app:1.0.0
```

Docker CLI는 registry 주소가 Docker daemon의 insecure registry로 등록되어 있어야 HTTP 로그인과 push가 가능합니다. Buildah는 명령별로 `--tls-verify=false`를 지정할 수 있습니다.

```bash
HARBOR_REGISTRY="harbor.example.local:30002"

printf '%s' '<PASSWORD>' | docker login "${HARBOR_REGISTRY}" \
  -u admin --password-stdin

buildah login --tls-verify=false \
  --username admin \
  --password '<PASSWORD>' \
  "${HARBOR_REGISTRY}"

buildah push --tls-verify=false "${HARBOR_REGISTRY}/library/sample-app:1.0.0"
```

Harbor project가 public이면 Kubernetes pull에는 별도 Secret이 필요하지 않습니다. 다만 manifest에 `imagePullSecrets`가 남아 있으면 해당 Secret이 없는 namespace에서 pull 경고가 발생할 수 있으므로 public project를 사용할 때는 manifest에서 제거합니다. private project를 사용할 때만 애플리케이션 namespace에 Secret을 생성합니다.

```bash
kubectl create secret docker-registry harbor-regcred \
  --docker-server="${HARBOR_REGISTRY}" \
  --docker-username=admin \
  --docker-password='<PASSWORD>' \
  -n <APP_NAMESPACE>
```

kind 환경에서는 호스트 OS가 아니라 kind 노드 컨테이너 내부의 containerd 설정을 수정해야 합니다. worker 노드가 여러 대라면 이미지를 pull하는 모든 worker 노드에 동일하게 적용합니다.

```bash
KIND_NODE_NAME="test-cluster-worker"
HARBOR_REGISTRY="harbor.example.local:30002"

docker exec "${KIND_NODE_NAME}" mkdir -p "/etc/containerd/certs.d/${HARBOR_REGISTRY}"

docker exec "${KIND_NODE_NAME}" sh -c "cat > '/etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml'" <<EOF
server = "http://${HARBOR_REGISTRY}"

[host."http://${HARBOR_REGISTRY}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

docker exec "${KIND_NODE_NAME}" systemctl restart containerd
```

설정 후에는 실제 노드 컨테이너 내부 파일과 containerd 상태를 확인합니다.

```bash
docker exec "${KIND_NODE_NAME}" cat "/etc/containerd/certs.d/${HARBOR_REGISTRY}/hosts.toml"
docker exec "${KIND_NODE_NAME}" systemctl status containerd --no-pager
```
