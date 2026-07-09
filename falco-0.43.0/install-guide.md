# 🚀 Falco 폐쇄망 설치 가이드 (v0.43.0 / Chart v8.0.1)

eBPF 기반 런타임 보안 도구 Falco를 폐쇄망 환경의 Kubernetes(WSL2/K3s 및 표준 K8s)에 배포하는 절차입니다.

---

## 0. 오프라인 설치 자산 준비 (인터넷 환경)

폐쇄망에 반입할 Helm 차트와 컨테이너 이미지(.tar)가 `charts/` 및 `images/` 디렉토리에 없는 경우, **인터넷이 연결된 외부 PC(리눅스)**에서 아래 스크립트를 실행하여 자산을 다운로드해야 합니다.

> **주의**: 이 작업은 폐쇄망 내부가 아닌, 외부망에서 사전에 수행되어야 합니다. (Docker 또는 containerd(`ctr`), `helm` CLI 설치 필수)

```bash
# 컴포넌트 루트 디렉토리에서 스크립트 실행 권한 부여 및 자산 다운로드
chmod +x ./scripts/download_assets_offline.sh
sudo ./scripts/download_assets_offline.sh
```

스크립트 실행이 완료되면 `charts/` 디렉토리에 `.tgz` 차트 파일이, `images/` 디렉토리에 `.tar` 이미지 파일들이 생성됩니다. 전체 프로젝트 폴더를 압축하여 폐쇄망 내부로 반입하십시오.

> **에어갭 완결성 보완**: `download_assets_offline.sh`는 `falco`, `falcosidekick` 외에 Helm Connection Test Hook에 필요한 `appropriate/curl:latest` 이미지까지 자동으로 수집합니다.

---

## 1. 1단계: 이미지 Harbor 업로드 (폐쇄망 환경)

모든 작업은 컴포넌트 루트 디렉토리(`falco-0.43.0/`)에서 실행합니다.

```bash
# 1. 수집된 모든 이미지 로컬 containerd(k8s.io)에 import
for f in images/*.tar; do sudo ctr -n k8s.io images import "$f"; done

# 2. 이미지 마이그레이션 및 Harbor 푸시 실행
chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

---

## 2. 2단계: 설치 실행 (대화형)

모든 작업은 컴포넌트 루트 디렉토리에서 실행합니다.

```bash
# 헬름 설치 (values-infra.yaml 자동 생성 및 base values.yaml 병합)
chmod +x scripts/install.sh
./scripts/install.sh
```

### 주요 입력 정보 및 처리 방식
* **이미지 소스**:
  * Harbor 방식은 `<HARBOR_REGISTRY>/<HARBOR_PROJECT>/...` 이미지를 사용합니다.
  * 로컬 방식은 각 노드에 사전 로드된 기본 컨테이너 이미지를 활용합니다.
* **설정 동기화**:
  * 입력된 설정은 base인 `values.yaml`을 수정하지 않고, 가변 인프라 설정 전용 파일인 `values-infra.yaml`을 생성하여 병합 배포하므로 **Single Source of Truth**가 보장됩니다.
  * 생성된 `values-infra.yaml` 및 `install.conf`는 일반 삭제 시에도 디렉토리에 보존되어 재설치 및 업그레이드 시 멱등 배포를 보장하며, 오직 `--reset` 초기화 명령 시에만 소거됩니다.

---

## 3. 3단계: 설치 및 검증

1. Falco 로그를 확인하여 이상행위 탐지 여부를 테스트합니다.
   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco -f
   ```

2. 준비된 테스트 시나리오를 실행하여 탐지 알림을 확인합니다.
   ```bash
   kubectl apply -f manifests/test-pod.yaml
   ```

---

## 4. 운영 참고: 노이즈 억제 룰

Falco는 기본 룰셋이 광범위하게 설정돼 있어, 정상 동작하는 애플리케이션도 탐지 대상이 될 수 있습니다. 이런 **알려진 노이즈**는 억제 룰로 제외해 실제 위협 신호가 묻히지 않도록 관리합니다.

### 제공 억제 룰 (`values-suppress-noise.yaml`)

| 룰 | 대상 | 이유 |
| :--- | :--- | :--- |
| `Redirect STDOUT/STDIN...` | `gitlab-shell-*` | SSH 세션 정상 STDIN/STDOUT 리다이렉트 |

### 적용 방법

#### 방법 1: install.sh 실행 시 선택
```bash
./scripts/install.sh
# "노이즈 억제 룰을 적용하시겠습니까?" 프롬프트에서 y 입력
```

#### 방법 2: helm upgrade에 직접 추가
```bash
helm upgrade falco ./charts/falco -n falco \
  -f values.yaml \
  -f values-infra.yaml \
  -f values-suppress-noise.yaml
```

### 억제 룰 추가 방법
`values-suppress-noise.yaml`의 `customRules` 블록에 항목을 추가합니다.

```yaml
customRules:
  suppress-noise.yaml: |-
    # 기존 룰에 조건 추가 (append)
    - rule: <룰 이름>
      condition: and not <제외 조건>
      override:
        condition: append
```

- `rule`: 억제할 기존 룰 이름 (정확히 일치해야 함)
- `condition`: 기존 조건에 추가할 제외 조건
- `override.condition: append`: 기존 룰을 덮어쓰지 않고 조건만 추가

적용 후 Falco 파드를 재시작하지 않아도 됩니다 (ConfigMap 변경은 자동 반영).

---

## 5. 수동 설치 및 업그레이드 가이드 (Manual Installation & Upgrade)

자동화 스크립트 장애 대처용 수동 반영 가이드라인입니다.

### 5.1. 수동 설치 진행
1. `values.yaml` 을 수정하지 않고 그대로 두고, `values-infra.yaml` 파일을 작성하여 로컬 사양(이미지 레지스트리 경로, 컨테이너 런타임 소켓 경로)을 오버라이드합니다.
   * **소켓 표준 가이드**: Falco 8.x 차트 권장 스펙에 따라 `collectors.containerEngine` 옵션을 기재하여 Docker/Podman 감지를 배제하고 containerd CRI 소켓을 지정합니다.
   ```yaml
   image:
     registry: "192.168.1.10:30002"
     repository: "library/falco"
   falcosidekick:
     image:
       registry: "192.168.1.10:30002"
       repository: "library/falcosidekick"
   collectors:
     containerEngine:
       enabled: true
       engines:
         docker:
           enabled: false
         podman:
           enabled: false
         containerd:
           enabled: false
         cri:
           enabled: true
           sockets:
             - "/run/containerd/containerd.sock"
   ```
2. Helm 배포를 직접 적용합니다.
   ```bash
   # 1. 네임스페이스 생성
   kubectl create namespace falco --dry-run=client -o yaml | kubectl apply -f -

   # 2. Helm 배포 (멱등 배포)
   helm upgrade --install falco ./charts/falco \
     -n falco \
     -f ./values.yaml \
     -f ./values-infra.yaml
   ```

---

## 6. 서비스 삭제 및 초기화

Falco 스택을 완전히 제거하려면 다음 명령을 사용합니다.

```bash
# 리소스 삭제 (설정 파일 보존)
sudo ./scripts/uninstall.sh

# 완전 초기화 (설정 파일 완전 제거)
sudo ./scripts/uninstall.sh --reset
```

---

## 7. 트러블슈팅

### 1. inotify 리소스 부족 (WSL2 필수)
Falco 구동 시 `could not initialize inotify handler` 에러가 발생하면 호스트(WSL2)의 리소스를 확장해야 합니다.
```bash
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=1048576
```

### 2. eBPF 드라이버 실패
커널이 BTF를 지원하지 않으면 Falco 파드가 구동되지 않습니다. `values.yaml`에서 `driver.kind`를 `ebpf`로 변경하여 재설치하세요.

---

## 별첨: Grafana 연동

FalcoSidekick metrics를 Prometheus + Grafana 스택에 연동하는 절차입니다.

> 대시보드 JSON은 공식 falcosecurity 차트에 기본 내장돼 있습니다 (`charts/falco/charts/falcosidekick/dashboards/`). `helm pull` 시 자동으로 포함된 파일이며 별도로 준비할 필요가 없습니다.

### 체크리스트

| 항목 | 내용 | 비고 |
| :--- | :--- | :--- |
| metrics 엔드포인트 | `falco-falcosidekick:2810/metrics` | 설치 시 자동 생성 |
| ServiceMonitor | `manifests/servicemonitor-falcosidekick.yaml` | 별도 apply 필요 |
| 대시보드 JSON | 차트 내장 (`falcosidekick-grafana-dashboard.json`) | 존재 |
| 대시보드 자동 배포 | `values.yaml`에 `grafana.dashboards.enabled: true` + namespace 지정 | values에 포함됨 |

### 연동 절차

#### 1단계: ServiceMonitor 적용
`manifests/servicemonitor-falcosidekick.yaml`을 적용합니다. Prometheus Operator가 이 리소스를 읽어 FalcoSidekick metrics 수집을 시작합니다.
```bash
kubectl apply -f manifests/servicemonitor-falcosidekick.yaml
```

> `release: prometheus` 라벨이 반드시 있어야 합니다. 이 라벨이 없으면 Prometheus가 ServiceMonitor를 무시합니다.

#### 2단계: Grafana 대시보드 자동 배포 활성화
`values.yaml`(또는 `values-infra.yaml`)에 아래 설정이 포함돼 있습니다. `helm upgrade` 시 `monitoring` 네임스페이스에 ConfigMap이 자동으로 생성됩니다.
```yaml
falcosidekick:
  grafana:
    dashboards:
      enabled: true
      configMaps:
        falcosidekick:
          namespace: monitoring
```

#### 3단계: Grafana에서 확인
아래 항목을 순서대로 확인합니다.
```bash
# ConfigMap이 생성됐는지 확인
kubectl get cm -n monitoring | grep falcosidekick

# ServiceMonitor가 등록됐는지 확인
kubectl get servicemonitor -n monitoring falcosidekick
```

Grafana 대시보드 확인:
1. Grafana 접속
2. Dashboards → Browse
3. `falcosidekick` 검색 → 대시보드 진입
4. 이벤트 그래프 및 우선순위별 통계 확인
