# Gatekeeper v3.17.0 오프라인 설치 가이드

본 문서는 폐쇄망 Kubernetes 클러스터에 Gatekeeper v3.17.0을 설치하는 절차입니다.
모든 명령은 `gatekeeper-3.17.0/` 디렉터리에서 실행합니다.

## 0. 오프라인 설치 자산 준비

인터넷에 연결된 준비 PC에서 Helm 차트와 컨테이너 이미지를 내려받습니다.

```bash
cd gatekeeper-3.17.0
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

완료 후 다음 파일이 준비됩니다.

| 경로 | 설명 |
| :--- | :--- |
| `charts/gatekeeper/` | Gatekeeper Helm 차트 |
| `images/openpolicyagent-gatekeeper-v3.17.0.tar` | Gatekeeper controller, webhook, audit 이미지 |
| `images/openpolicyagent-gatekeeper-crds-v3.17.0.tar` | Gatekeeper CRD 설치용 이미지 |

준비된 `gatekeeper-3.17.0/` 디렉터리 전체를 폐쇄망 설치 서버로 반입합니다.

## 1. 사전 조건

- Kubernetes 클러스터가 정상 동작해야 합니다.
- `kubectl`, `helm`, `ctr` 명령을 사용할 수 있어야 합니다.
- `charts/gatekeeper/` 또는 Gatekeeper 차트 tgz가 준비되어 있어야 합니다.
- Harbor 방식을 사용할 경우 Gatekeeper 이미지가 Harbor에 업로드되어 있어야 합니다.

## 2. 이미지 준비

### 방법 A. Harbor 레지스트리 사용

폐쇄망에서 Harbor가 준비되어 있으면 이미지를 Harbor로 업로드합니다.

```bash
chmod +x ./images/upload_images_to_harbor_v3-lite.sh
sudo ./images/upload_images_to_harbor_v3-lite.sh
```

업로드 후 Harbor 프로젝트에 다음 이미지가 존재하는지 확인합니다.

- `gatekeeper:v3.17.0`
- `gatekeeper-crds:v3.17.0`

### 방법 B. 공개 레지스트리 또는 로컬 이미지 사용

인터넷 연결이 가능한 테스트 환경에서는 `images/` 디렉터리가 비어 있어도 설치를 진행할 수 있습니다.
이 경우 Gatekeeper Pod는 `openpolicyagent/gatekeeper:v3.17.0` 이미지를 공개 레지스트리에서 직접 pull합니다.

로컬 tar 파일을 직접 사용하는 방식은 다음 환경에서만 권장합니다.

- 단일 노드 클러스터
- `kind` 테스트 클러스터
- Gatekeeper Pod가 실행될 수 있는 모든 노드에 tar 파일을 직접 import한 멀티 노드 클러스터

일반 Kubernetes 멀티 노드 클러스터에서는 컨트롤 플레인에서 `ctr import`를 실행해도 워커 노드에는 이미지가 배포되지 않습니다.
폐쇄망 멀티 노드 환경에서는 Harbor 방식을 우선 사용하십시오.

수동으로 모든 대상 노드에 import하는 경우 각 노드에서 다음 명령을 실행합니다.

```bash
sudo ctr -n k8s.io images import ./images/openpolicyagent-gatekeeper-v3.17.0.tar
sudo ctr -n k8s.io images import ./images/openpolicyagent-gatekeeper-crds-v3.17.0.tar
```

`kind` 환경에서는 다음 명령을 사용합니다.

```bash
kind load image-archive ./images/openpolicyagent-gatekeeper-v3.17.0.tar --name <cluster-name>
kind load image-archive ./images/openpolicyagent-gatekeeper-crds-v3.17.0.tar --name <cluster-name>
```

## 3. 자동 설치 및 업그레이드

```bash
sudo ./scripts/install.sh
```

설치 스크립트는 다음 값을 입력받아 `install.conf`에 저장합니다.

| 항목 | 설명 |
| :--- | :--- |
| 이미지 소스 | Harbor 또는 공개 레지스트리/로컬 이미지 사용 |
| Harbor 주소 | 예: `172.30.235.20:30002` |
| Harbor 프로젝트 | 예: `library` |
| Namespace | 기본값: `gatekeeper-system` |
| replicas | controller-manager 복제 수, 기본값: `3` |
| audit interval | audit 실행 주기, 기본값: `60` |

기존 설치 또는 `install.conf`가 감지되면 다음 메뉴가 표시됩니다.

| 메뉴 | 동작 |
| :--- | :--- |
| 업그레이드 | 저장된 설정을 유지하고 Helm upgrade 수행 |
| 재설치 | 기존 Helm 릴리스를 제거한 뒤 설정을 다시 입력받아 설치 |
| 초기화 | 릴리스, 네임스페이스, `install.conf` 제거 |
| 취소 | 작업 없이 종료 |

## 4. Manual Installation & Upgrade

자동 스크립트를 사용하지 않는 경우 다음 절차로 수동 설치합니다.

### Harbor 이미지 경로 사용

`values.yaml`에서 `<NODE_IP>`와 `<PROJECT>`를 실제 Harbor 주소와 프로젝트로 변경합니다.

```bash
sed -i \
  -e 's|<NODE_IP>|172.30.235.20:30002|g' \
  -e 's|<PROJECT>|library|g' \
  ./values.yaml

helm upgrade --install gatekeeper ./charts/gatekeeper \
  -n gatekeeper-system \
  --create-namespace \
  -f ./values.yaml \
  --wait
```

### 로컬 이미지 직접 사용

```bash
helm upgrade --install gatekeeper ./charts/gatekeeper \
  -n gatekeeper-system \
  --create-namespace \
  -f ./values-local.yaml \
  --wait
```

## 5. 설치 검증

```bash
kubectl get pods -n gatekeeper-system
kubectl get validatingwebhookconfiguration | grep gatekeeper
kubectl get mutatingwebhookconfiguration | grep gatekeeper
kubectl get crd | grep gatekeeper.sh
```

정상 상태 예시는 다음과 같습니다.

```text
gatekeeper-audit-xxxxxxxxxx-xxxxx                 1/1   Running
gatekeeper-controller-manager-xxxxxxxxxx-xxxxx    1/1   Running
```

## 6. 정책 적용 테스트

다음 예시는 `gatekeeper-system` 네임스페이스에 한정된 간단한 dry-run 검증입니다.

```bash
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels
        violation[{"msg": msg}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }
EOF
```

## 7. 제거 및 초기화

자동 제거:

```bash
sudo ./scripts/uninstall.sh
```

수동 제거:

```bash
helm uninstall gatekeeper -n gatekeeper-system
kubectl delete ns gatekeeper-system --ignore-not-found=true
rm -f ./install.conf
```

CRD와 Constraint 리소스까지 제거하려면 실제 운영 정책 영향도를 확인한 뒤 별도로 삭제해야 합니다.

```bash
kubectl get crd | grep gatekeeper.sh
kubectl get crd | grep gatekeeper.sh | awk '{print $1}' | xargs -r kubectl delete crd
```
