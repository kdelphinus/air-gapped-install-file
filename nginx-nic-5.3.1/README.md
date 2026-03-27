# 📝 F5 NGINX Ingress Controller Specification (NodePort Mode)

본 문서는 **F5 NGINX Ingress Controller (NIC) v5.3.1** OSS 버전
(`nginx/nginx-ingress`)을 기반으로, NodePort 방식으로 서비스를 노출하는
폐쇄망 전용 명세를 정의합니다.

> **OSS 전용:** NGINX Plus 라이선스 없이 동작하는 `nginx/nginx-ingress` 이미지만
> 사용합니다. `nginx-plus-ingress` 이미지는 포함하지 않습니다.

## 1. 시스템 개요 (System Overview)

| 항목 | 사양 | 비고 |
| :--- | :--- | :--- |
| **컴포넌트** | F5 NGINX Ingress Controller | community ingress-nginx와 별도 프로젝트 |
| **버전** | v5.3.1 (OSS) | `nginx/nginx-ingress` 이미지 |
| **소스 레포** | github.com/nginx/kubernetes-ingress | 에어갭 환경에서는 사전 클론 후 이관 |
| **네트워크 모드** | **NodePort** | 에어갭 환경, 외부 LB 없음 |
| **진입점 포트** | **30080 (HTTP), 30443 (HTTPS)** | NodePort 고정 지정 |
| **Annotation 접두사** | `nginx.org/` | community `nginx.ingress.kubernetes.io/`와 상이 |
| **IngressClass** | `nginx` | `ingressClassName: nginx` |

---

## 2. 워크로드 및 네트워크 명세 (Workloads)

### 🚀 컨트롤러 구성

- **Deployment**: `nginx-ingress` (네임스페이스: `nginx-ingress`)
- **ServiceAccount**: `nginx-ingress`
- **IngressClass**: `nginx` — `ingressClassName: nginx`으로 Ingress 리소스에서 참조
- **Admission Webhook**: `nginx-ingress-admission` ClusterIP 서비스로 리소스 유효성 검사
- **CRD**: `VirtualServer`, `VirtualServerRoute`, `TransportServer`, `Policy`,
  `GlobalConfiguration`

### 🌐 포트 매핑

| 프로토콜 | NodePort | 컨테이너 포트 | 용도 |
| :--- | :--- | :--- | :--- |
| **HTTP** | **30080** | 80 | 일반 웹 트래픽 진입점 |
| **HTTPS** | **30443** | 443 | 보안 웹 트래픽 (TLS 종료) |

---

## 3. 컨테이너 이미지

| 이미지 | 태그 | 용도 |
| :--- | :--- | :--- |
| `nginx/nginx-ingress` | `5.3.1` | 컨트롤러 메인 이미지 (OSS) |
| `nginx/kube-webhook-certgen` | `v1.4.4` | Admission Webhook 인증서 자동 생성 |

> 실제 사용 이미지 및 태그는 `git checkout v5.3.1` 후 `deployments/` 매니페스트와
> Helm chart `values.yaml`에서 반드시 확인합니다.
>
> Harbor 등록 후 이미지 주소 형식: `<NODE_IP>:30002/library/<image>:<tag>`

---

## 4. 핵심 설정 및 보안 (Security & Config)

### 🔐 보안 정보 (Secrets)

- **nginx-ingress-admission**: Admission Webhook TLS 인증서.
  `kube-webhook-certgen` Job이 배포 시 자동 생성합니다.
- **default-server-secret**: 기본 TLS 인증서.
  `deployments/common/default-server-secret.yaml`에서 자가 서명 인증서를 적용합니다.

### ⚙️ 컨트롤러 주요 기동 옵션 (args)

| 옵션 | 기본값 | 설명 |
| :--- | :--- | :--- |
| `-enable-snippets` | 비활성 | `nginx.org/location-snippets` 등 Snippet Annotation 허용 |
| `-ingress-class=nginx` | `nginx` | 처리할 IngressClass 이름 |
| `-enable-custom-resources` | `true` | VirtualServer 등 CRD 활성화 |
| `-watch-namespace` | 전체 | 특정 네임스페이스만 감시할 때 지정 |
| `-default-server-tls-secret` | - | 기본 TLS 시크릿 (`<ns>/<name>`) |

---

## 5. 폐쇄망 운영 가이드 (NodePort 전용)

### ✅ community ingress-nginx와의 주요 차이

| 항목 | community ingress-nginx | F5 NIC v5.3.1 (OSS) |
| :--- | :--- | :--- |
| 이미지 레포 | `registry.k8s.io/ingress-nginx/controller` | `docker.io/nginx/nginx-ingress` |
| Annotation 접두사 | `nginx.ingress.kubernetes.io/` | `nginx.org/` |
| 고급 라우팅 | Ingress 리소스만 | VirtualServer, Policy CRD 지원 |
| Snippets 기본 | 비활성 | `-enable-snippets` 플래그로 활성화 |
| IngressClass 이름 | `nginx` | `nginx` (동일) |

### ✅ NodePort 접근 방식

외부 LB가 없는 에어갭 환경에서는 `http://<NODE_IP>:30080`,
`https://<NODE_IP>:30443`으로 진입합니다.
Ingress 리소스에 반드시 `ingressClassName: nginx`를 명시해야 NIC가 처리합니다.

### ✅ 포트 충돌 주의

NodePort 30080, 30443은 기본 배포에서 Envoy Gateway와 동일한 포트를 사용합니다.
두 Ingress 솔루션을 동시에 운영하지 않거나, 포트를 사전에 조율하여 충돌을 방지합니다.
