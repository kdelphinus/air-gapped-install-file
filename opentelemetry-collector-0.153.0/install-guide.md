# OpenTelemetry Collector v0.153.0 오프라인 설치 가이드

폐쇄망 환경에서 OpenTelemetry Collector를 Kubernetes(K8s) 위에 설치하는 절차를 안내합니다.

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 스크립트 디렉토리로 이동
cd scripts/

# 실행 권한 부여 및 다운로드 스크립트 실행
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `opentelemetry-collector-0.158.0.tgz` 파일이, `images/` 디렉토리에 `otel-opentelemetry-collector-contrib-0.153.0.tar` 이미지 파일이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

---

## 전제 조건

* Kubernetes 클러스터 구성 완료 (v1.24 이상)
* Helm v3 이상 설치 완료
* `kubectl` CLI 사용 가능
* Harbor 레지스트리 또는 로컬 이미지 로드 환경 (Containerd `ctr` 등)

---

## 1단계: 이미지 확보 및 로드

### Case A: 로컬 환경에 직접 로드 (Harbor 미사용 시)

오프라인 워커 노드 장비로 아카이빙 된 tar 파일을 가져온 후, containerd(k8s.io) 네임스페이스 또는 도커 데몬에 이미지를 직접 로드합니다.

```bash
# containerd를 사용하는 경우 (Kubernetes 기본)
sudo ctr -n k8s.io images import images/otel-opentelemetry-collector-contrib-0.153.0.tar

# Docker 데몬을 사용하는 경우
sudo docker load -i images/otel-opentelemetry-collector-contrib-0.153.0.tar
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

**스크립트 동작 및 기능 설명:**
1. **상태 관리**: 입력된 설정 값(Harbor 설정, 네임스페이스, 배포 방식 등)은 `install.conf`에 자동 기록 및 유지됩니다.
2. **업그레이드**: 기존 릴리스를 감지하면, 기존 설정을 그대로 보존하면서 Helm Upgrade를 안전하게 수행합니다.
3. **재설치**: 기존 설치 내역을 삭제하고 초기 세팅값부터 다시 입력받아 기동합니다.
4. **초기화**: 자원 뿐만 아니라 `install.conf` 상태 파일까지 일괄 완전 삭제합니다.

---

### 방법 2. 수동 설치 및 업그레이드 (Manual Fallback)

자동화 스크립트 실행이 불가능하거나 디버깅 등의 특수한 제어가 필요한 환경에서는 아래 수동 절차를 따라 배포합니다.

#### 1) `values.yaml` 환경 설정
`opentelemetry-collector-0.153.0/values.yaml` 파일을 텍스트 에디터로 엽니다. 오프라인 이미지 소스에 맞춰 수정합니다.

* **Harbor 레지스트리 주소를 사용하는 경우:**
  ```yaml
  image:
    repository: "[Harbor 주소]/[Harbor 프로젝트]/opentelemetry-collector-contrib"
    tag: "0.153.0"
  ```
* **로컬 이미지를 노드에 직접 임포트하여 사용하는 경우:**
  ```yaml
  image:
    repository: "otel/opentelemetry-collector-contrib"
    tag: "0.153.0"
  ```

기타 배포 형태(`mode: daemonset` 또는 `deployment`), 그리고 타겟 서비스 노출 방식(`service.type: ClusterIP` 등)을 기호에 맞춰 재조정합니다.

#### 2) Helm 릴리스 배포 실행
타겟 네임스페이스(예: `monitoring`)를 지정하여 Helm 업그레이드 설치를 수행합니다.

```bash
# 컴포넌트 루트 디렉토리에서 실행
helm upgrade --install otel-collector ./charts/opentelemetry-collector-0.158.0.tgz \
  -n monitoring --create-namespace \
  -f ./values.yaml
```

*참고: 압축이 해제된 디렉토리를 원천으로 설정하려면 다음과 같이 수행합니다.*
```bash
helm upgrade --install otel-collector ./charts/opentelemetry-collector \
  -n monitoring --create-namespace \
  -f ./values.yaml
```

---

## 3단계: 애플리케이션 연동 및 검증

애플리케이션(Java, Spring, Go, Python 등)에서 수집기로 OTLP 데이터를 송신할 때, 기본 노출 주소는 다음과 같이 세팅됩니다.

* **K8s 클러스터 내부에서의 수송 수신지 주소:**
  * **gRPC Endpoint**: `otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317`
  * **HTTP Endpoint**: `otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4318`

---

## 삭제 및 초기화

### 방법 1. 스크립트 실행
```bash
chmod +x scripts/uninstall.sh
./scripts/uninstall.sh
```

### 방법 2. 수동 삭제
```bash
# 헬름 릴리스 제거
helm uninstall otel-collector -n monitoring

# finalizer 교정 및 자원 수동 제거 (Terminating 교착 상태 방지)
for KIND in daemonset deployment service configmap; do
  kubectl get $KIND -n monitoring -o name 2>/dev/null | grep otel-collector | \
    xargs -r -I {} kubectl patch {} -n monitoring -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done
```
