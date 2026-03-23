# 🚀 Envoy Gateway v1.36.3 오프라인 설치 가이드

폐쇄망 환경에서 Envoy Gateway를 Kubernetes 위에 설치하는 절차를 안내합니다.

## 전제 조건

- Kubernetes 클러스터 구성 완료
- Helm v3.14.0 설치 완료
- `kubectl` CLI 사용 가능
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)

## 1단계: 이미지 Harbor 업로드

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# IMAGE_DIR      : ./images (현재 디렉터리의 이미지 폴더 지정)
# HARBOR_REGISTRY: <NODE_IP>:30002

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

## 2단계: 설치 및 운영 설정 (values.yaml)

루트 디렉토리의 설정 파일들을 환경에 맞게 수정합니다.

| 파일명 | 용도 | 비고 |
| :--- | :--- | :--- |
| **`values-controller.yaml`** | Envoy Gateway Controller 설정 | 이미지 경로 및 리소스 제한 등 |
| **`values-infra.yaml`** | Infrastructure (Gateway) 설정 | 서비스 타입(LB/NodePort), 포트 등 |
| **`manifests/policy-global.yaml`** | 전역 보안 및 트래픽 정책 | EnvoyPatchPolicy 등 |

## 3단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트 실행 중 다음 항목을 선택합니다:

1. **설치 모드**: `1` (LoadBalancer) 또는 `2` (NodePort - 권장)
2. **노드 고정**: Envoy Proxy를 배치할 특정 노드 이름 입력 (선택)
3. **전역 정책**: `manifests/policy-global.yaml` 적용 여부

## 4단계: 설치 확인

```bash
# 파드 상태 확인
kubectl get pods -n envoy-gateway-system

# Gateway 및 서비스 확인
kubectl get gateway,svc -n envoy-gateway-system
```

## 5단계: 서비스 노출 (HTTPRoute)

신규 서비스를 Envoy를 통해 노출하려면 `HTTPRoute` 리소스를 생성하여 적용합니다.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: default
spec:
  parentRefs:
    - name: cmp-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "my-app.internal"
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: my-app-service
          port: 80
```

## 💡 운영 팁

- **클라이언트 실IP 보존**: `values-infra.yaml`에서 `externalTrafficPolicy: Local` 설정을 확인하십시오.
- **NodePort 확인**: NodePort 모드 사용 시 호스트에서 `30080`(HTTP), `30443`(HTTPS) 포트가 리스닝 중인지 확인하십시오.
- **트러블슈팅**: Gateway 상태가 `false`일 경우 `kubectl describe gateway cmp-gateway` 명령어로 원인을 파악하십시오.

## 삭제

```bash
./scripts/uninstall.sh
```
