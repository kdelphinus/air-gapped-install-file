# Falco 8.0.1 폐쇄망 설치 가이드

## 개요

eBPF 기반 런타임 보안 도구 Falco를 폐쇄망 환경의 K8s(WSL2/K3s 포함)에 배포합니다.

## Phase 1: 에셋 준비 (인터넷 환경)

1. `scripts/download_assets_offline.sh`를 실행하여 차트와 이미지를 수집합니다.

   ```bash
   ./scripts/download_assets_offline.sh
   ```

2. 수집된 `charts/`와 `images/` 디렉토리를 폐쇄망 환경으로 복사합니다.

## Phase 2: 이미지 업로드 (폐쇄망 환경)

1. 로컬 Harbor 레지스트리에 로그인합니다.
2. `images/upload_images_to_harbor_v3-lite.sh`를 실행하여 이미지를 푸시합니다.

   ```bash
   cd images
   ./upload_images_to_harbor_v3-lite.sh
   ```

## Phase 3: 설치 및 검증

1. `values.yaml`의 `image.registry` 주소가 로컬 Harbor IP로 되어 있는지 확인합니다.
2. 설치 스크립트를 실행합니다.

   ```bash
   ./scripts/install.sh
   ```

3. Falco 로그를 확인하여 이상행위 탐지 여부를 테스트합니다.

   ```bash
   kubectl logs -n falco -l app.kubernetes.io/name=falco -f
   ```

4. 준비된 테스트 시나리오를 실행하여 탐지 알림을 확인합니다.

   ```bash
   kubectl apply -f manifests/test-scenarios.yaml
   ```

## 운영 참고: 노이즈 억제 룰

Falco는 기본 룰셋이 광범위하게 설정돼 있어, 정상 동작하는 애플리케이션도 탐지 대상이 될 수 있습니다.
이런 **알려진 노이즈**는 억제 룰로 제외해 실제 위협 신호가 묻히지 않도록 관리합니다.

### 제공 억제 룰 (`values-suppress-noise.yaml`)

| 룰 | 대상 | 이유 |
| :--- | :--- | :--- |
| `Redirect STDOUT/STDIN to Network Connection in Container` | `gitlab-gitlab-shell-*` | SSH 세션 처리 시 정상적으로 발생하는 STDIN/STDOUT 리다이렉트 |

### 적용 방법

**방법 1: install.sh 실행 시 선택**

```bash
./scripts/install.sh
# "노이즈 억제 룰을 적용하시겠습니까?" 프롬프트에서 y 입력
```

**방법 2: helm upgrade에 직접 추가**

```bash
helm upgrade falco ./charts/falco -n falco \
  -f values.yaml \
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

### 현재 적용 여부 확인

```bash
kubectl get cm -n falco falco-rules -o yaml
```

ConfigMap이 존재하고 `suppress-noise.yaml` 키가 있으면 억제 룰이 적용된 상태입니다.

---

## 운영 참고: 런타임 엔진 최적화 (Falco 8.x 기준)

Falco 8.x 차트부터는 `containerEngine`이라는 통합 설정을 사용하여 여러 런타임을 관리합니다. 실 배포 환경에서 특정 런타임만 사용하도록 고정하려면 다음 형식을 권장합니다.

**표준 K8s(containerd 전용) `values.yaml` 권장 설정:**

```yaml
driver:
  kind: modern_ebpf

collectors:
  enabled: true
  containerEngine:
    enabled: true
    engines:
      docker:
        enabled: false
      podman:
        enabled: false
      cri:
        enabled: true
        sockets: ["/run/containerd/containerd.sock"]
```

## 트러블슈팅

### 1. inotify 리소스 부족 (WSL2 필수)

Falco 구동 시 `could not initialize inotify handler` 에러가 발생하면 호스트(WSL2)의 리소스를 확장해야 합니다.

```bash
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_user_watches=1048576
```

### 2. eBPF 드라이버 실패

커널이 BTF를 지원하지 않으면 Falco 파드가 구동되지 않습니다. `values.yaml`에서 `driver.kind`를 `ebpf`로 변경하여 재설치하세요.

### 3. K3s 소켓 미인식

K3s 환경에서 파드가 생성되었으나 이벤트를 수집하지 못한다면, 소켓 경로를 확인하세요. 본 패키지의 `install.sh`는 이를 자동 감지하지만, 수동 설정 시에는 다음 형식을 따릅니다.

```bash
# 설치 시 수동 주입 예시
helm upgrade --install falco ./charts/falco \
  --set collectors.containerEngine.engines.cri.sockets='{/run/k3s/containerd/containerd.sock}'
```

---

## 별첨: Grafana 연동

FalcoSidekick metrics를 Prometheus + Grafana 스택에 연동하는 절차입니다.

> 대시보드 JSON은 공식 falcosecurity 차트에 기본 내장돼 있습니다 (`charts/falco/charts/falcosidekick/dashboards/`).
> `helm pull` 시 자동으로 포함된 파일이며 별도로 준비할 필요가 없습니다.

### 체크리스트

| 항목 | 내용 | 비고 |
| :--- | :--- | :--- |
| metrics 엔드포인트 | `falco-falcosidekick:2810/metrics` | 설치 시 자동 생성 |
| ServiceMonitor | `manifests/servicemonitor-falcosidekick.yaml` | 별도 apply 필요 |
| 대시보드 JSON | 차트 내장 (`falcosidekick-grafana-dashboard.json`) | 존재 |
| 대시보드 자동 배포 | `values.yaml`에 `grafana.dashboards.enabled: true` + namespace 지정 | values에 포함됨 |
| Grafana sidecar | `NAMESPACE = ALL` 설정으로 모든 네임스페이스 자동 감지 | 별도 설정 불필요 |

### 연동 절차

**1단계: ServiceMonitor 적용**

`manifests/servicemonitor-falcosidekick.yaml`을 적용합니다.
Prometheus Operator가 이 리소스를 읽어 FalcoSidekick metrics 수집을 시작합니다.

```bash
kubectl apply -f manifests/servicemonitor-falcosidekick.yaml
```

> `release: prometheus` 라벨이 반드시 있어야 합니다.
> 이 라벨이 없으면 Prometheus가 ServiceMonitor를 무시합니다.
> 라벨 값은 Prometheus 인스턴스의 `serviceMonitorSelector`에 따라 다를 수 있으니 확인하세요.
>
> ```bash
> kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec.serviceMonitorSelector}'
> ```

**2단계: Grafana 대시보드 자동 배포 활성화**

`values.yaml`(또는 `values-local.yaml`)에 아래 설정이 포함돼 있습니다.
`helm upgrade` 시 `monitoring` 네임스페이스에 ConfigMap이 자동으로 생성됩니다.

```yaml
falcosidekick:
  grafana:
    dashboards:
      enabled: true
      configMaps:
        falcosidekick:
          namespace: monitoring
```

> `namespace` 값은 Grafana가 배포된 네임스페이스로 맞춰야 합니다.
> Grafana sidecar가 해당 네임스페이스의 `grafana_dashboard: "1"` 라벨 ConfigMap을 감지해 자동 등록합니다.

**3단계: Grafana에서 확인**

아래 항목을 순서대로 확인합니다.

```bash
# ConfigMap이 생성됐는지 확인
kubectl get cm -n monitoring | grep falcosidekick

# ServiceMonitor가 등록됐는지 확인
kubectl get servicemonitor -n monitoring falcosidekick

# Prometheus target 확인 (UP 상태여야 함)
# Grafana → Explore → Prometheus → Targets 또는
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090 &
# 브라우저: http://localhost:9090/targets → falcosidekick 검색
```

Grafana 대시보드 확인:

1. Grafana 접속
2. Dashboards → Browse
3. `falcosidekick` 검색 → 대시보드 진입
4. 이벤트 그래프 및 우선순위별 통계 확인

> Grafana가 우리 스택이 아닌 경우, ConfigMap의 `grafana_dashboard: "1"` 라벨을 감지하는
> sidecar가 설정돼 있는지 확인하세요. sidecar가 없으면 대시보드 JSON을
> Grafana UI에서 직접 import 해야 합니다 (Import → JSON 파일 업로드).
