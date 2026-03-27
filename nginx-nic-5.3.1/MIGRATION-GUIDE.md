# 🔄 Community Ingress-Nginx to F5 NGINX Ingress Controller (NIC) Migration Guide

본 문서는 Kubernetes 커뮤니티 버전(`ingress-nginx`)에서 F5 NGINX 인수를 거친 **NGINX Ingress Controller (NIC) v5.3.1**로 마이그레이션할 때 필요한 주요 변경 사항과 매핑 정보를 다룹니다.

## 1. 핵심 차이점 요약

| 항목 | Community Ingress-Nginx | F5 NGINX NIC (v5.3.1) |
| :--- | :--- | :--- |
| **관리 주체** | Kubernetes Community | NGINX (F5) |
| **Annotation 접두사** | `nginx.ingress.kubernetes.io/` | `nginx.org/` |
| **이미지 레포지토리** | `registry.k8s.io/ingress-nginx/controller` | `docker.io/nginx/nginx-ingress` |
| **IngressClass 이름** | `nginx` (기본값) | `nginx` (기본값) |
| **고급 기능 구현** | Annotation 위주 | **Custom Resources (CRD)** 위주 |
| **Snippets 허용** | 기본 비활성 | `-enable-snippets` 플래그로 활성화 |

---

## 2. 주요 Annotation 매핑 (Annotation Mapping)

기존 `Ingress` 리소스를 그대로 유지하면서 컨트롤러만 변경할 경우, 아래와 같이 Annotation 접두사와 키 이름을 변경해야 합니다.

| 기능 | Community Annotation | F5 NIC Annotation |
| :--- | :--- | :--- |
| **Rewrites** | `rewrite-target: /` | `nginx.org/rewrites: "serviceName=<svc> rewrite=<path>"` (단순 치환만 가능, regex 불가) — 복잡한 rewrite는 **VirtualServer `rewritePath`** 사용 권장 |
| **Max Body Size** | `proxy-body-size: 50m` | `nginx.org/client-max-body-size: 50m` |
| **Connect Timeout** | `proxy-connect-timeout: 60s` | `nginx.org/proxy-connect-timeout: 60s` |
| **Read Timeout** | `proxy-read-timeout: 60s` | `nginx.org/proxy-read-timeout: 60s` |
| **SSL Redirect** | `ssl-redirect: "true"` | `nginx.org/redirect-to-https: "true"` |
| **Backends Protocol** | `backend-protocol: HTTPS` | `nginx.org/server-snippets` 또는 `Policy` 사용 권장 |
| **Custom Snippets** | `configuration-snippet` | `nginx.org/location-snippets` |

---

## 3. Custom Resources (추천 방식)

F5 NIC는 표준 `Ingress` 리소스보다 전용 **Custom Resources (CRD)** 사용을 권장합니다. 이는 더 강력한 타입 검사와 복잡한 라우팅 설정을 지원합니다.

### VirtualServer 예시 (Ingress 대체)

기존 Ingress를 F5 전용 `VirtualServer`로 변환하는 예시입니다.

```yaml
# [F5 NIC 전용 VirtualServer]
apiVersion: k8s.nginx.org/v1
kind: VirtualServer
metadata:
  name: cafe
spec:
  host: cafe.example.com
  tls:
    secret: cafe-secret
  upstreams:
    - name: tea
      service: tea-svc
      port: 80
    - name: coffee
      service: coffee-svc
      port: 80
  routes:
    - path: /tea
      action:
        pass: tea
    - path: /coffee
      action:
        pass: coffee
```

---

## 4. 마이그레이션 단계별 절차

### 1단계: CRD 사전 설치
F5 NIC는 독자적인 CRD를 대거 사용합니다. 설치 전 반드시 `manifests/` 디렉토리의 CRD를 먼저 적용해야 합니다.
```bash
kubectl apply -k ./manifests/
```

### 2단계: IngressClass 확인
두 컨트롤러가 동일한 `IngressClass: nginx`를 사용할 경우 충돌이 발생할 수 있습니다.
- 마이그레이션 기간 동안은 F5 NIC의 IngressClass를 `f5-nginx` 등으로 별도 지정하여 병행 운영하는 것을 권장합니다.
- `values.yaml`에서 `controller.ingressClass.name`을 수정하여 제어할 수 있습니다.

### 3단계: Annotation 및 리소스 변환
기존 Ingress 리소스의 Annotation을 `nginx.org/` 접두사로 변경하거나, 가급적 `VirtualServer` 리소스로 재작성합니다.

### 4단계: 트래픽 전환
에어갭 환경의 경우 NodePort가 겹치지 않도록 주의해야 합니다.
- **Envoy/Community NIC:** 30080/30443 (기본값)
- **F5 NIC:** 30080/30443 (동일하게 설정된 경우 충돌)
- 전환 시 포트를 다르게 설정하거나 기존 컨트롤러를 제거한 후 설치하십시오.

---

## 5. 주의사항 (Important Notes)

1. **Snippet 활성화:** F5 NIC에서 Annotation을 통한 NGINX 설정 주입을 사용하려면 기동 인자에 `-enable-snippets`가 포함되어야 합니다. (`values.yaml`의 `enableSnippets: true` 확인)
2. **Default IngressClass:** `controller.ingressClass.setAsDefaultIngress: true` 설정 시 `ingressClassName`이 명시되지 않은 모든 Ingress를 처리하려고 시도하므로 주의가 필요합니다.
3. **App Protect:** WAF 기능(App Protect)을 사용하려면 별도의 라이선스와 이미지가 필요하며, 마이그레이션 가이드 범위를 벗어납니다. (현재 프로젝트는 OSS 전용입니다.)
