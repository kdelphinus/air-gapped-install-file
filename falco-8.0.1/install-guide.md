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
