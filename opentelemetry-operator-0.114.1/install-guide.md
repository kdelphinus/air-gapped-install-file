# OpenTelemetry Operator v0.114.1 / v0.152.0 오프라인 설치 가이드

폐쇄망 환경에서 OpenTelemetry Operator를 Kubernetes(K8s) 위에 설치하는 절차를 안내합니다.

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Containerd(`ctr`) 또는 `docker`, `helm` CLI 설치 필수)

```bash
# 컴포넌트 스크립트 디렉토리로 이동
cd scripts/

# 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x download_assets_offline.sh
./download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `opentelemetry-operator-0.114.1.tgz` 파일이, `images/` 디렉토리에 `ghcr.io-open-telemetry-opentelemetry-operator-opentelemetry-operator-v0.152.0.tar` 이미지 파일이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 🚨 필수 사전 조건 (Prerequisites)

OpenTelemetry Operator는 내부 어드미션 웹훅의 보안 인증서 서명을 위해 **`cert-manager`**를 필수로 요구합니다.

* **동작 검증**: `install.sh` 실행 시 클러스터 내부의 `certificates.cert-manager.io` CRD 등록 상태를 자동 검사합니다.
* **배포 유무 확인**: 아직 `cert-manager`가 설치되지 않은 경우, 반드시 `cert-manager` 컴포넌트의 오프라인 패키지를 활용해 `cert-manager`를 먼저 실행(Running) 상태로 구축하십시오.

---

## 1단계: 이미지 확보 및 로드

### Case A: 로컬 환경에 직접 로드 (Harbor 미사용 시)

오프라인 워커 노드 장비로 아카이빙 된 tar 파일을 가져온 후, containerd(k8s.io) 네임스페이스 또는 도커 데몬에 이미지를 직접 로드합니다.

```bash
# containerd를 사용하는 경우 (Kubernetes 기본)
sudo ctr -n k8s.io images import images/ghcr.io-open-telemetry-opentelemetry-operator-opentelemetry-operator-v0.152.0.tar

# Docker 데몬을 사용하는 경우
sudo docker load -i images/ghcr.io-open-telemetry-opentelemetry-operator-opentelemetry-operator-v0.152.0.tar
```

### Case B: Harbor 레지스트리 업로드

Harbor 레지스트리를 이용하는 환경인 경우, 동봉된 마이그레이션 스크립트를 실행하여 Harbor에 일괄 로드 및 태깅 후 자동 푸시(Push)할 수 있습니다.

```bash
chmod +x images/upload_images_to_harbor_v3-lite.sh
sudo ./images/upload_images_to_harbor_v3-lite.sh
```

---

## 2단계: 설치 및 업그레이드

설치는 자동화 스크립트를 사용하거나, 수동으로 Helm 명령어를 직접 실행하여 진행할 수 있습니다.

### 방법 1. 자동화 스크립트 사용 (권장)

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

**스크립트 내부 기능 및 연동 지침:**
1. **사전 의존성 검사**: 시작 전 클러스터에 `cert-manager`의 작동 여부를 검사하여 미작동 시 안전하게 배포를 보류 및 경고합니다.
2. **설정 영구 보존**: 수집된 입력 정보(레지스트리, 네임스페이스)는 `install.conf` 상태 파일에 보존됩니다.
3. **업그레이드 및 롤아웃**: 기 감지 시 기존 설정을 연동 유지하며 순차 업그레이드를 수행합니다.

---

### 방법 2. 수동 설치 및 업그레이드 (Manual Fallback)

자동화 스크립트를 우회하고 명시적으로 자원을 전개해야 하는 특수 환경에서는 아래와 같이 배포합니다.

#### 1) `values.yaml` 환경 설정
`opentelemetry-operator-0.114.1/values.yaml` 파일을 에디터로 엽니다. 오프라인 이미지 정보에 맞춰 수정합니다.

* **Harbor 레지스트리 주소를 사용하는 경우:**
  ```yaml
  image:
    repository: "[Harbor 주소]/[Harbor 프로젝트]/opentelemetry-operator"
    tag: "v0.152.0"
  ```
* **로컬 이미지를 노드에 직접 임포트하여 사용하는 경우:**
  ```yaml
  image:
    repository: "ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator"
    tag: "v0.152.0"
  ```

#### 2) Helm 릴리스 배포 실행
타겟 네임스페이스(예: `opentelemetry`)를 지정하여 Helm 설치 및 업그레이드를 수행합니다.

```bash
# 컴포넌트 루트 디렉토리에서 실행
helm upgrade --install otel-operator ./charts/opentelemetry-operator-0.114.1.tgz \
  -n opentelemetry --create-namespace \
  -f ./values.yaml
```

---

## 3단계: 자동 계측 구성 및 실시간 모니터링 (Auto-Instrumentation)

배포된 오퍼레이터를 사용하여 애플리케이션 파드에 성능 수집 에이전트를 자동 주입(Auto-Injection)하는 실전 사례입니다.

### 1) Instrumentation CR 작성 및 배포
수송지 타겟을 중앙 OpenTelemetry Collector 서비스 주소(`http://otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317`)로 바인딩하여 선언합니다.

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: dynamic-instrumentation
  namespace: my-app-namespace
spec:
  exporter:
    endpoint: http://otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317
  propagators:
    - tracecontext
    - baggage
    - b3
  sampler:
    type: parentbased_always_on
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:1.32.0
```

### 2) 파드에 계측 어노테이션 주입
애플리케이션 디플로이먼트 파일의 Pod 템플릿 영역에 주입하고자 하는 타겟 언어를 선언하면 파드가 기동될 때 오퍼레이터가 라이브러리를 동적 주입해 줍니다.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spring-web-app
  namespace: my-app-namespace
spec:
  replicas: 2
  template:
    metadata:
      annotations:
        # Java 자동 계측 에이전트 주입 지시문
        instrumentation.opentelemetry.io/inject-java: "true"
```

---

## 삭제 및 초기화

### 방법 1. 스크립트 실행
```bash
chmod +x scripts/uninstall.sh
./scripts/uninstall.sh
```

### 방법 2. 수동 삭제 및 잔여 웹훅 초기화
```bash
# 헬름 릴리스 제거
helm uninstall otel-operator -n opentelemetry

# K8s API 서버 전역에 캐시된 잔존 어드미션 웹훅 수동 제거 (교착 상태 차단용)
kubectl delete mutatingwebhookconfiguration otel-operator-mutating-webhook-configuration --ignore-not-found=true
kubectl delete validatingwebhookconfiguration otel-operator-validating-webhook-configuration --ignore-not-found=true

# 네임스페이스 제거
kubectl delete ns opentelemetry --ignore-not-found=true
```
