# 🚀 F5 NGINX Ingress Controller v5.3.1 오프라인 설치 가이드

폐쇄망 환경에서 F5 NGINX Ingress Controller (NIC) v5.3.1 OSS 버전을
Kubernetes 위에 매니페스트 직접 적용 방식으로 설치하는 절차를 안내합니다.

> **OSS 전용 가이드입니다.** `nginx/nginx-ingress` 이미지만 사용하며,
> NGINX Plus 및 유료 기능은 다루지 않습니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료 (master + worker)
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 구축 완료 (`<NODE_IP>:30002`)
- 인터넷 연결 환경에서 이미지 및 매니페스트 사전 준비 완료

---

## 1단계: 인터넷 연결 환경에서 — 이미지 및 매니페스트 준비

> 이 단계는 **인터넷 연결 환경**(준비 서버)에서 수행합니다.

### 소스 레포 클론 및 매니페스트 추출

```bash
git clone https://github.com/nginx/kubernetes-ingress.git
cd kubernetes-ingress
git checkout v5.3.1

# 배포에 필요한 매니페스트 디렉토리 확인
ls deployments/
# common/  rbac/  deployment/  service/
```

### 필요 컨테이너 이미지 목록

| 이미지 | 태그 | 용도 |
| :--- | :--- | :--- |
| `nginx/nginx-ingress` | `5.3.1` | 컨트롤러 메인 (OSS) |
| `nginx/kube-webhook-certgen` | `v1.4.4` | Admission Webhook 인증서 생성 |

> 실제 certgen 이미지 태그는 `deployments/deployment/nginx-ingress.yaml` 내
> `initContainers` 또는 `kube-webhook-certgen` Job 정의에서 확인합니다.

### 이미지 Pull 및 Save

```bash
docker pull nginx/nginx-ingress:5.3.1
docker pull nginx/kube-webhook-certgen:v1.4.4

mkdir -p /transfer/nginx-nic-5.3.1/images

docker save nginx/nginx-ingress:5.3.1 \
  -o /transfer/nginx-nic-5.3.1/images/nginx-ingress-5.3.1.tar

docker save nginx/kube-webhook-certgen:v1.4.4 \
  -o /transfer/nginx-nic-5.3.1/images/kube-webhook-certgen-v1.4.4.tar
```

### 매니페스트 복사

```bash
cp -r deployments/ /transfer/nginx-nic-5.3.1/manifests/
```

### 에어갭 환경으로 파일 이관

USB, SCP, 내부 파일 서버 등 허용된 방법으로
`/transfer/nginx-nic-5.3.1/` 전체를 에어갭 서버로 복사합니다.

---

## 2단계: 에어갭 환경에서 — 이미지 로드 및 Harbor 푸시

> 이 단계부터는 **에어갭(폐쇄망) 환경**에서 수행합니다.

### 설정 변수

아래 값을 환경에 맞게 수정합니다.

| 변수 | 설명 | 예시 |
| :--- | :--- | :--- |
| `NODE_IP` | Harbor가 운영 중인 노드 IP | `192.168.1.100` |
| `HARBOR_REGISTRY` | Harbor 레지스트리 주소 | `192.168.1.100:30002` |
| `HARBOR_PROJECT` | Harbor 프로젝트 이름 | `library` |
| `HARBOR_USER` | Harbor 계정 | `admin` |
| `HARBOR_PASSWORD` | Harbor 비밀번호 | `Harbor12345` |

### 이미지 로드 (containerd)

```bash
cd /path/to/nginx-nic-5.3.1/images

sudo ctr -n k8s.io images import nginx-ingress-5.3.1.tar
sudo ctr -n k8s.io images import kube-webhook-certgen-v1.4.4.tar

# 로드 확인
sudo ctr -n k8s.io images list | grep nginx
```

### Harbor 프로젝트 생성 (미리 생성되지 않은 경우)

```bash
HARBOR_REGISTRY="<NODE_IP>:30002"
HARBOR_USER="admin"
HARBOR_PASSWORD="Harbor12345"

curl -k -u "${HARBOR_USER}:${HARBOR_PASSWORD}" \
  -X POST "https://${HARBOR_REGISTRY}/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"library","public":true}'
```

### Harbor 로그인 및 이미지 푸시

```bash
HARBOR_REGISTRY="<NODE_IP>:30002"
HARBOR_PROJECT="library"

# Harbor 로그인
docker login "${HARBOR_REGISTRY}" -u admin -p Harbor12345

# nginx-ingress 푸시
docker load -i images/nginx-ingress-5.3.1.tar
docker tag nginx/nginx-ingress:5.3.1 \
  "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/nginx-ingress:5.3.1"
docker push "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/nginx-ingress:5.3.1"

# kube-webhook-certgen 푸시
docker load -i images/kube-webhook-certgen-v1.4.4.tar
docker tag nginx/kube-webhook-certgen:v1.4.4 \
  "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/kube-webhook-certgen:v1.4.4"
docker push "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/kube-webhook-certgen:v1.4.4"
```

> `upload_images_to_harbor_v3-lite.sh` 스크립트가 준비된 경우, 스크립트 상단
> Config 블록을 수정한 뒤 `bash images/upload_images_to_harbor_v3-lite.sh`로
> 일괄 업로드할 수 있습니다.

---

## 3단계: 매니페스트 수정 — 이미지 경로 및 옵션 변경

### Deployment 이미지 경로 변경

`manifests/deployment/nginx-ingress.yaml`에서 이미지 주소를 Harbor 경로로 교체합니다.

```bash
# 변경 전
# image: nginx/nginx-ingress:5.3.1

# sed로 일괄 치환
HARBOR_REGISTRY="<NODE_IP>:30002"
HARBOR_PROJECT="library"

sed -i \
  "s|nginx/nginx-ingress:5.3.1|${HARBOR_REGISTRY}/${HARBOR_PROJECT}/nginx-ingress:5.3.1|g" \
  manifests/deployment/nginx-ingress.yaml

sed -i \
  "s|nginx/kube-webhook-certgen:v1.4.4|${HARBOR_REGISTRY}/${HARBOR_PROJECT}/kube-webhook-certgen:v1.4.4|g" \
  manifests/deployment/nginx-ingress.yaml
```

### `-enable-snippets` 옵션 추가

`manifests/deployment/nginx-ingress.yaml`의 `args` 블록에 다음 항목을 추가합니다.

```yaml
args:
  - -ingress-class=nginx
  - -health-status
  - -ready-status
  - -enable-snippets        # location-snippets, server-snippets Annotation 허용
  - -enable-custom-resources=true
```

### Service NodePort 포트 고정

`manifests/service/nodeport.yaml`에서 nodePort 값을 명시적으로 지정합니다.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-ingress
  namespace: nginx-ingress
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
      name: http
      nodePort: 30080
    - port: 443
      targetPort: 443
      protocol: TCP
      name: https
      nodePort: 30443
  selector:
    app: nginx-ingress
```

---

## 4단계: 리소스 적용

반드시 아래 순서대로 적용합니다. CRD가 먼저 등록되어야 이후 리소스가 정상 생성됩니다.

```bash
cd /path/to/nginx-nic-5.3.1

# 1. CRD 등록
kubectl apply -f manifests/common/crds/

# 2. Namespace 및 ServiceAccount
kubectl apply -f manifests/common/ns-and-sa.yaml

# 3. RBAC (ClusterRole, ClusterRoleBinding)
kubectl apply -f manifests/rbac/rbac.yaml

# 4. ConfigMap (nginx-config)
kubectl apply -f manifests/common/nginx-config.yaml

# 5. 기본 TLS 시크릿
kubectl apply -f manifests/common/default-server-secret.yaml

# 6. IngressClass
kubectl apply -f manifests/common/ingress-class.yaml

# 7. Deployment (이미지 경로 및 args 수정 완료 후)
kubectl apply -f manifests/deployment/nginx-ingress.yaml

# 8. Service (NodePort 포트 수정 완료 후)
kubectl apply -f manifests/service/nodeport.yaml
```

---

## 5단계: 설치 확인

```bash
# Pod 상태 확인
kubectl get pods -n nginx-ingress

# Service NodePort 확인
kubectl get svc -n nginx-ingress

# CRD 등록 확인
kubectl get crd | grep nginx
```

### 포트 확인

| 프로토콜 | NodePort | 용도 |
| :--- | :--- | :--- |
| **HTTP** | **30080** | 일반 웹 트래픽 |
| **HTTPS** | **30443** | 보안 웹 트래픽 |

### 동작 확인 (Ingress 리소스 예시)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example
  namespace: default
  annotations:
    nginx.org/proxy-connect-timeout: "60s"
spec:
  ingressClassName: nginx
  rules:
    - host: example.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: example-svc
                port:
                  number: 80
```

```bash
curl -H "Host: example.internal" http://<NODE_IP>:30080/
```

---

## 기존 ingress-nginx 마이그레이션 — Annotation 변경 요약

community ingress-nginx에서 F5 NIC로 전환 시 Annotation 접두사와 일부 키 이름을
변경해야 합니다.

| 기능 | community (nginx.ingress.kubernetes.io/) | F5 NIC (nginx.org/) | 비고 |
| :--- | :--- | :--- | :--- |
| Proxy 연결 타임아웃 | `proxy-connect-timeout: "60"` | `proxy-connect-timeout: "60s"` | 단위(`s`) 명시 필요 |
| Proxy 읽기 타임아웃 | `proxy-read-timeout: "60"` | `proxy-read-timeout: "60s"` | 단위(`s`) 명시 필요 |
| Proxy 전송 타임아웃 | `proxy-send-timeout: "60"` | `proxy-send-timeout: "60s"` | 단위(`s`) 명시 필요 |
| 최대 요청 바디 크기 | `proxy-body-size: "10m"` | `client-max-body-size: "10m"` | 키 이름 상이 |
| HTTPS 리다이렉트 | `ssl-redirect: "true"` | `redirect-to-https: "true"` | 키 이름 상이 |
| Location Snippet | `configuration-snippet: \|` | `location-snippets: \|` | `-enable-snippets` 필수 |
| Server Snippet | `server-snippet: \|` | `server-snippets: \|` | `-enable-snippets` 필수 |
| URL Rewrite | `rewrite-target: /` | VirtualServer CRD 사용 권장 | 값 형식 완전히 상이 |
| 세션 어피니티 | `affinity: cookie` | VirtualServer CRD 사용 권장 | Annotation 미지원 |
| Rate Limiting | `limit-rps: "10"` | Policy CRD 사용 | Annotation 미지원 |
| Canary 배포 | `canary: "true"` | VirtualServer CRD 사용 | Annotation 미지원 |

> Annotation으로 처리하기 어려운 고급 기능은 `VirtualServer` 및 `Policy` CRD로
> 대체하는 것을 권장합니다.

---

## 💡 주의 사항

- **OSS 이미지 확인**: `nginx/nginx-ingress` 이미지를 사용합니다.
  `nginx-plus-ingress` 이미지는 NGINX Plus 라이선스가 필요하므로 사용하지 않습니다.
- **IngressClass 명시**: Ingress 리소스에 `ingressClassName: nginx`를 반드시
  지정해야 F5 NIC가 처리합니다. 미지정 시 무시됩니다.
- **Snippets 보안**: `-enable-snippets`는 임의의 nginx 설정 주입을 허용하므로,
  신뢰된 네임스페이스의 리소스만 적용받도록 RBAC을 제한하는 것을 권장합니다.
- **포트 충돌**: NodePort 30080, 30443은 Envoy Gateway 기본 포트와 동일합니다.
  두 컨트롤러를 동시에 운영하는 경우 포트를 사전에 조율합니다.
- **CRD 선적용 필수**: CRD를 Deployment보다 먼저 적용하지 않으면 컨트롤러가
  기동 시 CRD를 인식하지 못해 오류가 발생합니다.
- **Webhook 인증서**: `kube-webhook-certgen` Job이 정상 완료되어야 Admission
  Webhook이 활성화됩니다. Job 상태를 `kubectl get jobs -n nginx-ingress`로 확인합니다.
- **트러블슈팅**: 문제 발생 시 `kubectl logs -n nginx-ingress <pod-name>`으로
  컨트롤러 로그를 확인합니다.

---

## 삭제

```bash
kubectl delete -f manifests/service/nodeport.yaml
kubectl delete -f manifests/deployment/nginx-ingress.yaml
kubectl delete -f manifests/common/ingress-class.yaml
kubectl delete -f manifests/common/default-server-secret.yaml
kubectl delete -f manifests/common/nginx-config.yaml
kubectl delete -f manifests/rbac/rbac.yaml
kubectl delete -f manifests/common/ns-and-sa.yaml
kubectl delete -f manifests/common/crds/
```
