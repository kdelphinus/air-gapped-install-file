# Keycloak 26.2.5 설치 가이드

## 1. 사전 조건

- Kubernetes, Helm, `ctr` 명령을 사용할 수 있어야 합니다.
- Envoy Gateway의 `cluster-gateway`와 HTTPS 리스너가 준비되어 있어야 합니다.
- `keycloak.devops.internal` 또는 설치 시 지정할 FQDN이 Envoy Gateway 주소로 DNS 해석되어야 합니다.
- `images/keycloak-26.2.5.tar`, `images/postgres-16.9.tar`가 준비되어 있어야 합니다.

## 2. 인터넷 연결 준비 서버에서 에셋 수집

```bash
cd keycloak-26.2.5
sudo ./scripts/download_assets_offline.sh
```

생성된 `images/*.tar`를 폐쇄망 환경의 동일한 경로로 복사합니다.

## 3. Harbor 업로드 또는 로컬 이미지 준비

Harbor를 사용할 경우 다음 명령으로 두 이미지를 업로드합니다.

```bash
cd keycloak-26.2.5
sudo ./images/upload_images_to_harbor_v3-lite.sh
```

Harbor를 사용하지 않으면 설치 스크립트에서 로컬 tar import를 선택합니다.

## 4. 자동 설치

```bash
cd keycloak-26.2.5
./scripts/install.sh
```

설치 중 입력하는 Keycloak FQDN은 HTTPRoute 호스트명, OIDC issuer, 각 OSS 클라이언트 설정에 공통으로 사용됩니다. 설치 후 다음 상태를 확인합니다.

```bash
kubectl get pods,svc,pvc -n keycloak
kubectl get httproute keycloak-route -n keycloak
curl -kI https://<KEYCLOAK_FQDN>/realms/master/.well-known/openid-configuration
```

## 5. 관리 콘솔과 Realm 준비

`https://<KEYCLOAK_FQDN>/admin/`에 설치 시 만든 관리자 계정으로 로그인합니다.

1. `oss` Realm을 생성합니다.
2. `gitlab`, `nexus`, `jenkins` Client를 각각 생성합니다.
3. Client type은 `OpenID Connect`, Client authentication은 활성화합니다.
4. 각 제품의 callback URL만 Valid redirect URIs에 등록합니다.

OIDC issuer는 다음 형식입니다.

```text
https://<KEYCLOAK_FQDN>/realms/oss
```

## 6. Manual Installation & Upgrade

Secret은 최초 1회 생성합니다. 비밀번호는 명령 이력에 남지 않도록 대화형 입력 또는 별도 보안 도구를 사용하십시오.

```bash
cd keycloak-26.2.5
kubectl create namespace keycloak
kubectl create secret generic keycloak-credentials -n keycloak \
  --from-literal=keycloak-admin-password='<ADMIN_PASSWORD>' \
  --from-literal=postgres-password='<POSTGRES_PASSWORD>'
helm upgrade --install keycloak ./charts/keycloak -n keycloak -f values.yaml --wait
kubectl apply -f manifests/httproute.yaml
```

Harbor 경로, FQDN, StorageClass는 먼저 `values.yaml`과 `manifests/httproute.yaml`에서 변경한 뒤 실행합니다.

## 7. 제거

```bash
cd keycloak-26.2.5
./scripts/uninstall.sh
```

이 명령은 데이터 보호를 위해 PostgreSQL PVC와 Secret을 보존합니다. 완전 삭제는 `./scripts/install.sh`의 초기화 메뉴에서 선택합니다.
