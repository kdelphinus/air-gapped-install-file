# Ingress Controller 전환 작업 가이드 (Community to F5 NGINX NIC)

본 문서는 Kubernetes 환경에서 기존 `ingress-nginx`(community)에서 **F5 NGINX Ingress Controller (이하 NIC) v5.3.1**로 전환하기 위한 표준 가이드입니다. 프로젝트 내 실제 헬름 차트(`strato-solution-install/` 디렉토리)와 인프라 팀의 공식 가이드(PDF)를 결합하여 작성되었습니다.

---

## 1. 환경별 주요 변경 설정 (Environment Specifics)

설치 및 전환 시 아래 항목들은 **운영 환경(IP, 도메인, 경로 등)에 따라 반드시 수정**해야 합니다. 가이드 내에서 `{{ ENV_... }}`로 표시된 부분은 환경별 맞춤 설정이 필요한 영역입니다.

- **LoadBalancer IP:** `{{ ENV_LB_IP }}` (기존 Ingress Controller가 사용하던 VIP 유지)
- **도메인(Host):** `{{ ENV_DOMAIN }}` (예: product.strato.co.kr)
- **인증(Auth) 파일 경로:** `{{ ENV_AUTH_PATH }}` (Secret 생성 시 htpasswd 파일이 위치한 로컬 경로)
- **네임스페이스:** `{{ ENV_NAMESPACE }}` (서비스가 배포된 K8s 네임스페이스)

---

## 2. 주요 Annotation 매핑 (Annotation Mapping)

기존 `Ingress` 리소스를 유지하면서 컨트롤러만 변경할 경우, 아래와 같이 Annotation 접두사와 키 이름을 변경해야 합니다.

| 기능 | Community Annotation (`nginx.ingress.kubernetes.io/`) | F5 NIC Annotation (`nginx.org/`) |
| :--- | :--- | :--- |
| **SSL Redirect** | `force-ssl-redirect: "true"` | `redirect-to-https: "true"` |
| **Max Body Size** | `proxy-body-size: 50m` | `client-max-body-size: 50m` |
| **Snippets** | `configuration-snippet` | `server-snippets` (또는 `location-snippets`) |
| **Custom Headers** | `more_set_headers` (Snippet 내) | `add_header ... always;` (Snippet 내) |
| **Basic Auth** | `auth-type: basic` | (삭제 - `basic-auth-secret` 존재 시 자동 활성) |
| **Auth Secret** | `auth-secret: <name>` | `basic-auth-secret: <name>` |
| **Auth Realm** | `auth-realm: <realm>` | `basic-auth-realm: <realm>` |

---

## 3. 서비스별 전환 예시 (Conversion Examples)

프로젝트 내 주요 5개 서비스에 대해 `Ingress`(어노테이션 방식)와 `VirtualServer`(CRD 방식) 두 가지 버전의 변환 예시를 제공합니다.

### 3.1 Portal Frontend (`strato-solution-install/strato-portal-front`)

#### [Option A] Ingress (Annotation 방식)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: strato-portal-frontend-ingress
  annotations:
    nginx.org/redirect-to-https: "true"
    nginx.org/client-max-body-size: "10M"
spec:
  ingressClassName: nginx
  rules:
    - host: "{{ ENV_DOMAIN }}"
      http:
        paths:
          - path: "/"
            pathType: Prefix
            backend:
              service: { name: strato-portal-frontend-svc, port: { number: 80 } }
          - path: "/oauth2"
            pathType: Prefix
            backend:
              service: { name: strato-auth-svc, port: { number: 5555 } }
```

#### [Option B] VirtualServer (CRD 방식)

```yaml
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
  name: strato-portal-frontend-vs
spec:
  ingressClassName: nginx
  host: "{{ ENV_DOMAIN }}"
  upstreams:
    - name: portal-front
      service: strato-portal-frontend-svc
      port: 80
    - name: auth-service
      service: strato-auth-svc
      port: 5555
  routes:
    - path: "/oauth2"
      action: { pass: auth-service }
    - path: "/"
      action: { pass: portal-front }
```

> **주의:** VirtualServer `routes`는 구체적인 경로(`/oauth2`)를 루트 경로(`/`)보다 먼저 정의해야 합니다.

> **Option A vs Option B 선택 권장:** Portal Frontend는 현재 Native Ingress(Option A) 형식으로 구성되어 있습니다. Native Ingress는 `path` 매칭 순서를 내부적으로 처리하므로 `/oauth2` 경로가 `/` 보다 먼저 처리된다는 보장이 없습니다. **`/oauth2` 경로 우선순위를 명시적으로 보장하려면 Option B(VirtualServer)로 전환하는 것을 권장합니다.**

### 3.2 API Gateway (`strato-solution-install/gateway`)

#### [Option A] Ingress (Annotation 방식)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway-ingress
  annotations:
    nginx.org/location-snippets: |
      client_max_body_size 20M;
      add_header 'Access-Control-Allow-Origin' '*' always;
      add_header 'Access-Control-Allow-Methods' 'PUT, GET, POST, DELETE, OPTIONS, PATCH' always;
      add_header 'Access-Control-Allow-Headers' '*' always;
      add_header 'Access-Control-Allow-Credentials' 'true' always;
spec:
  ingressClassName: nginx
  rules:
    - host: "{{ ENV_DOMAIN }}"
      http:
        paths:
          - path: "/gw"
            pathType: Prefix
            backend:
              service: { name: api-gateway-svc, port: { number: 20987 } }
```

#### [Option B] VirtualServer (CRD 방식)

```yaml
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
  name: api-gateway-vs
spec:
  ingressClassName: nginx
  host: "{{ ENV_DOMAIN }}"
  upstreams:
    - name: api-gateway
      service: api-gateway-svc
      port: 20987
  routes:
    - path: /gw
      location-snippets: |
        client_max_body_size 20M;
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'PUT, GET, POST, DELETE, OPTIONS, PATCH' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Allow-Credentials' 'true' always;
      action:
        proxy:
          upstream: api-gateway
          rewritePath: /
```

### 3.3 Grafana (`strato-solution-install/helm-chart/grafana`)

#### [Option A] Ingress (Annotation 방식)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  annotations:
    nginx.org/location-snippets: |
      sub_filter '</body>' '<style>...</style></body>';
      sub_filter_once on;
spec:
  ingressClassName: nginx
  rules:
    - host: "{{ ENV_DOMAIN }}"
      http:
        paths:
          - path: "/grafana"
            pathType: Prefix
            backend:
              service: { name: grafana-svc, port: { number: 3000 } }
```

#### [Option B] VirtualServer (CRD 방식)

```yaml
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
  name: strato-monitoring-vs
spec:
  ingressClassName: nginx
  host: "{{ ENV_DOMAIN }}"
  upstreams:
    - name: grafana
      service: grafana-svc
      port: 3000
  routes:
    - path: /grafana
      location-snippets: |
        sub_filter '</body>' '<style>...</style></body>';
        sub_filter_once on;
      action:
        proxy:
          upstream: grafana
          rewritePath: /
```

### 3.4 Prometheus & Alertmanager (Monitoring)

> **서비스명 확인:** 프로젝트 내 Prometheus 서비스명은 `prometheus-global-svc`(포트 9090)입니다.

#### [Option A] Ingress (Annotation 방식)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus-ingress
  namespace: monitoring
  annotations:
    nginx.org/basic-auth-secret: "basic-auth"
    nginx.org/basic-auth-realm: "Prometheus Access"
spec:
  ingressClassName: nginx
  rules:
    - host: "{{ ENV_DOMAIN }}"
      http:
        paths:
          - path: "/prometheus"
            pathType: Prefix
            backend:
              service: { name: prometheus-global-svc, port: { number: 9090 } }
          - path: "/alertmanager"
            pathType: Prefix
            backend:
              service: { name: alertmanager-operated, port: { number: 9093 } }
```

#### [Option B] VirtualServer (Policy 활용 방식)

```yaml
# 1. Policy 리소스 생성 (Basic Auth 정의)
apiVersion: k8s.nginx.org/v1
kind: Policy
metadata:
  name: basic-auth-policy
  namespace: monitoring
spec:
  basicAuth:
    secret: basic-auth
    realm: "Prometheus Access"
---
# 2. VirtualServer에서 Policy 참조
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
  name: prometheus-vs
  namespace: monitoring
spec:
  ingressClassName: nginx
  host: "{{ ENV_DOMAIN }}"
  policies:
    - name: basic-auth-policy
  upstreams:
    - name: prometheus
      service: prometheus-global-svc
      port: 9090
    - name: alertmanager
      service: alertmanager-operated
      port: 9093
  routes:
    - path: /prometheus
      action: { pass: prometheus }
    - path: /alertmanager
      action: { pass: alertmanager }
```

---

## 4. NIC 설치 및 주의 사항

### 4.1 Deployment 설정 (Snippet 활성화 필수)

NIC에서 `location-snippets` 등을 사용하기 위해 Helm 설치 시 `values.yaml`에 아래 옵션을 반드시 포함해야 합니다.

```yaml
# values.yaml
controller:
  enableSnippets: true
```

Helm 릴리스가 이미 설치된 경우 `helm upgrade`로 적용합니다.

```bash
helm upgrade nginx-ingress ./charts/nginx-ingress-5.3.1 \
  -n nginx-ingress \
  -f values.yaml
```

> **비 Helm(Raw Manifest) 방식:** `Deployment` 스펙에서 직접 args를 수정하는 경우 `-enable-snippets` 플래그를 컨테이너 args에 추가합니다.

### 4.2 Basic Auth용 Secret 재생성

F5 NIC는 전용 Secret 타입(`nginx.org/htpasswd`)을 요구합니다. 기존 `Opaque` 타입은 인식되지 않으므로 반드시 아래 명령어로 재생성하십시오.

```bash
kubectl delete secret basic-auth --namespace monitoring
kubectl create secret generic basic-auth \
  --namespace monitoring \
  --type=nginx.org/htpasswd \
  --from-file=htpasswd={{ ENV_AUTH_PATH }}/htpasswd
```

### 4.3 심화 아키텍처 고려 사항 (Advanced Architectural Notes)

1. **WebSocket 및 Keep-Alive**: Community 버전과 달리 F5 NIC는 WebSocket 업그레이드 설정을 명시적으로 요구할 수 있습니다. Portal Frontend나 실시간 모니터링 대시보드에서 WebSocket을 사용하는 경우, `Proxy Read Timeout` 및 `Connection/Upgrade` 헤더 유지 설정을 반드시 검증하십시오.
1. **Lua 스크립트 호환성**: 기존 Ingress에 Lua 스크립트 로직이 포함된 경우, F5 NIC는 이를 지원하지 않으므로 **njs(NGINX JavaScript)**로 재작성하거나 NGINX 네이티브 지시어로 변환해야 합니다.
1. **Snippet 보안 검증**: `enableSnippets: true` 활성화 시, 잘못된 설정 주입으로 인한 전체 인그레스 컨트롤러 정지(Crash)를 방지하기 위해 **Global Configuration Validation Webhook**이 정상 동작하는지 확인하십시오.
1. **커스텀 요청 헤더 pass-through (JWT)**: Grafana는 `X-JWT-Assertion` 헤더를 통해 자체적으로 JWT 인증을 처리합니다. NIC가 업스트림으로 요청을 전달할 때 이 헤더를 제거하거나 변조하지 않는지 반드시 확인하십시오. NIC 기본 설정에서 커스텀 헤더는 통과되지만, `proxy-set-headers` 등의 설정이 있을 경우 헤더 목록에서 누락될 수 있습니다.

### 4.4 TLS 설정

NIC에서 TLS를 처리하는 방식은 리소스 타입에 따라 다릅니다. 현재 프로젝트는 TLS Secret(`nhis-tls`, `strato-tls`)을 정의해 두었으나 비활성화 상태(`tls.enabled: false`)이므로, 운영 전환 시 아래 설정을 활성화해야 합니다.

#### VirtualServer 방식

```yaml
spec:
  host: "{{ ENV_DOMAIN }}"
  tls:
    secret: "{{ TLS_SECRET_NAME }}"   # 동일 네임스페이스에 존재하는 Secret 이름
  upstreams: ...
  routes: ...
```

#### Native Ingress 방식

```yaml
spec:
  tls:
    - hosts:
        - "{{ ENV_DOMAIN }}"
      secretName: "{{ TLS_SECRET_NAME }}"
  rules: ...
```

> `nginx.org/redirect-to-https: "true"` 어노테이션은 TLS가 활성화된 경우에만 의미가 있습니다. TLS 비활성화 상태에서는 동작하지 않습니다.

#### TLS Secret 네임스페이스 제약

F5 NIC는 **VirtualServer와 동일한 네임스페이스에 위치한 Secret만 참조**할 수 있습니다.

| 서비스 | 네임스페이스 | Secret 이름 |
| :--- | :--- | :--- |
| API Gateway | `strato-product` | `nhis-tls` |
| Portal Frontend | `strato-product` | `nhis-tls` |
| Monitoring (Grafana) | `monitoring` | `strato-tls` |

각 네임스페이스에 Secret이 존재하지 않으면 NIC가 TLS 설정을 적용할 수 없습니다. 인증서 배포 방식은 아래 두 가지 중 하나를 선택합니다.

- **방식 A — 네임스페이스별 Secret 복제**: 동일한 인증서를 각 네임스페이스에 별도로 생성
  ```bash
  kubectl get secret nhis-tls -n source-ns -o yaml \
    | sed 's/namespace: source-ns/namespace: strato-product/' \
    | kubectl apply -f -
  ```

- **방식 B — NIC 전역 기본 TLS 설정**: NIC `values.yaml`에 `controller.defaultTLS.secret`을 지정하면 모든 VirtualServer에 공통 인증서를 적용할 수 있습니다.
  ```yaml
  # NIC values.yaml
  controller:
    defaultTLS:
      secret: strato-product/nhis-tls
  ```

---

## 5. F5 NIC 구축 팀 협의 체크리스트 (Quick Checklist)

안전한 마이그레이션을 위해 인프라 및 설치 담당 팀과 확인해야 할 핵심 항목입니다.

### 5.1 설치 및 버전 (Installation & Version)

- [ ] **버전 호환성:** 도입되는 NIC 솔루션 버전과 K8s 클러스터 버전 간의 공식 호환성 확인
- [ ] **에어갭 이미지:** Harbor 레지스트리에 NIC 정식 이미지 업로드 여부
- [ ] **`sub_filter` 모듈 포함 이미지 확인:** Monitoring(Grafana)에서 `sub_filter` 지시어(HTML 주입)를 사용하므로, Harbor에 업로드된 NIC 이미지가 해당 모듈을 포함하는지 사전 검증 필요 (`nginx -V 2>&1 | grep sub_filter`)

### 5.2 권한 및 네트워크 (Access & Network)

- [ ] **IngressClass:** 컨트롤러 이름(기본 `nginx`) 및 기존 community ingress-nginx 컨트롤러와의 중복 여부 확인
- [ ] **RBAC 권한:** NIC가 타 네임스페이스의 TLS Secret을 읽을 수 있는 권한(ClusterRole) 부여 확인
- [ ] **네트워크 포트:** NIC Pod에서 각 서비스 Pod(3000, 9090, 9093, 20987 등)로의 통신 허용 여부
- [ ] **기존 community ingress-nginx 제거 시점:** F5 NIC 전환 완료 확인 후 제거 일정 협의 (동시 운영 기간 필요 여부 포함)

### 5.3 설정 및 보안 — Native Ingress 방식 (현재 적용 방향)

> Native Ingress(`networking.k8s.io/v1` + `nginx.org/` 어노테이션) 방식을 사용하는 경우의 확인 항목입니다.

#### 공통

- [ ] **TLS 인증서 배포 방식:** 네임스페이스별 Secret 복제(`nhis-tls` → `strato-product`, `strato-tls` → `monitoring`) vs NIC 전역 `defaultTLS.secret` 사용 방식 확정 (§4.4 참조)
- [ ] **TLS 활성화:** 각 서비스 Helm values의 `tls.enabled: false` → `true` 전환 시점 및 담당 확정
- [ ] **WebSocket:** `Connection/Upgrade` 헤더 처리 및 타임아웃 정책(Keep-Alive) 협의
- [ ] **JWT 헤더 pass-through 확인:** Grafana의 `X-JWT-Assertion` 헤더가 NIC를 거쳐 업스트림까지 전달되는지 검증 (§4.3 참조)

#### Native Ingress 전용

- [ ] **`nginx.org/location-snippets` 사용 가능 여부:** Gateway(CORS)와 Monitoring(sub_filter)은 `location-snippets` 어노테이션을 사용함. NIC 설치 시 `controller.enableSnippets: true` 적용 필수이며, Validation Webhook 정상 동작 여부도 함께 확인 (§4.1 참조)
- [ ] **`redirect-to-https` 동작 조건:** Portal Frontend의 `nginx.org/redirect-to-https: "true"` 어노테이션은 해당 Ingress에 TLS가 활성화된 경우에만 동작. TLS 비활성화 상태에서는 무시됨 (§4.4 참조)
- [ ] **`/oauth2` 경로 우선순위:** Native Ingress는 경로 매칭 순서를 명시적으로 보장하지 않음. `/oauth2`가 `/`보다 먼저 처리되는지 실제 동작으로 검증 필요. 보장이 안 될 경우 VirtualServer 전환 검토 (§3.1 참조)
- [ ] **Basic Auth Secret 타입:** Prometheus/Alertmanager용 Basic Auth Secret은 반드시 `nginx.org/htpasswd` 타입으로 재생성 필요. 기존 `Opaque` 타입은 NIC에서 인식하지 않음 (§4.2 참조)

### 5.4 설정 및 보안 — VirtualServer 방식 (CRD 방식으로 전환 시)

> `VirtualServer`(k8s.nginx.org/v1) 방식을 사용하는 경우의 확인 항목입니다. Native Ingress 방식으로 결정된 경우 이 섹션은 해당 없음.

#### VirtualServer 전용

- [ ] **CRD 설치:** `VirtualServer`, `VirtualServerRoute`, `Policy` 등 F5 NIC 전용 CRD가 클러스터에 배포되었는지 확인
- [ ] **`routes` 순서 보장:** VirtualServer는 `routes` 배열 순서대로 경로가 매칭됨. `/oauth2` 등 구체적인 경로를 `/`보다 반드시 먼저 정의 (§3.1 참조)
- [ ] **`rewritePath` 동작 확인:** Gateway(`/gw` → `/`), Monitoring(`/grafana` → `/`) 경로 재작성이 의도한 대로 동작하는지 검증 (§3.2, §3.3 참조)
- [ ] **Basic Auth Policy 리소스:** Prometheus/Alertmanager Basic Auth는 `Policy` 리소스(`basicAuth.secret`)로 구성. Secret 타입은 동일하게 `nginx.org/htpasswd` 필요 (§3.4, §4.2 참조)
- [ ] **TLS 인증서 배포 방식:** 네임스페이스별 Secret 복제(`nhis-tls` → `strato-product`, `strato-tls` → `monitoring`) vs NIC 전역 `defaultTLS.secret` 사용 방식 확정 (§4.4 참조)
- [ ] **TLS 활성화:** 각 서비스 Helm values의 `tls.enabled: false` → `true` 전환 시점 및 담당 확정
- [ ] **`location-snippets` in VirtualServer routes:** Gateway(CORS), Monitoring(sub_filter) VirtualServer의 `routes[].location-snippets` 사용 시 `controller.enableSnippets: true` 적용 필수 (§4.1 참조)
- [ ] **JWT 헤더 pass-through 확인:** Grafana의 `X-JWT-Assertion` 헤더가 NIC를 거쳐 업스트림까지 전달되는지 검증 (§4.3 참조)
