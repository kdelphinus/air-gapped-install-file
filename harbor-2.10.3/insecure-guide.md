# Harbor Insecure Registry 등록

Harbor와 HTTP 통신을 위해 Insecure 등록이 필요합니다.

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
