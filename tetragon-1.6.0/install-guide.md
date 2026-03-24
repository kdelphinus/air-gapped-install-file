# Tetragon 1.6.0 오프라인 설치 가이드

폐쇄망 환경에서 Tetragon을 Kubernetes 위에 설치하고 런타임 차단 정책을 적용하는 절차를 안내합니다.

## 사전 요건

- `kubectl` CLI 사용 가능
- `helm` v3.14.0 이상
- Harbor 레지스트리 접근 가능 (`<NODE_IP>:30002`)
- eBPF/BTF 지원 커널 (5.10+)

  ```bash
  uname -r
  ls /sys/kernel/btf/vmlinux   # 존재해야 함
  ```

## 1단계: 이미지 Harbor 업로드

```bash
# upload_images_to_harbor_v3-lite.sh 상단 Config 수정
# HARBOR_REGISTRY: <NODE_IP>:30002
# HARBOR_PROJECT : library

chmod +x images/upload_images_to_harbor_v3-lite.sh
./images/upload_images_to_harbor_v3-lite.sh
```

업로드 대상 이미지:

| 파일 | 이미지 |
| :--- | :--- |
| `tetragon-v1.6.0.tar` | `quay.io/cilium/tetragon:v1.6.0` |
| `tetragon-operator-v1.6.0.tar` | `quay.io/cilium/tetragon-operator:v1.6.0` |

## 2단계: values.yaml 수정

`values.yaml`의 `<NODE_IP>`를 실제 노드 IP로 교체합니다.

```bash
sed -i 's/<NODE_IP>/실제IP/g' values.yaml
```

## TracingPolicy 이해

Tetragon은 **기본 차단 정책이 없습니다.** 차단 동작은 전적으로 `TracingPolicy` CRD를 통해 직접 정의합니다.

### 정책 구조

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: block-sensitive-read
spec:
  kprobes:
  - call: "fd_install"       # 후킹할 커널 함수
    syscall: false
    args:
    - index: 0
      type: int              # 파일 디스크립터 번호
    - index: 1
      type: "file"           # 파일 객체 (경로 포함)
    selectors:
    - matchArgs:
      - index: 1
        operator: "Equal"
        values:
        - "/etc/shadow"      # 이 경로에 대한 접근만 차단
      matchActions:
      - action: Sigkill      # 해당 프로세스를 즉시 강제 종료
```

각 필드의 의미:

| 필드 | 설명 |
| :--- | :--- |
| `call` | 후킹할 커널 함수명. `fd_install`은 파일 열기 시 호출됨 |
| `args` | 커널 함수의 인자 타입 정의 |
| `matchArgs` | 인자 값 기준 필터 (index 1 = file 객체의 경로) |
| `operator` | `Equal` 외 `Prefix`, `Postfix`, `Regex` 등 지원 |
| `action` | `Sigkill`(즉시 종료), `Sigstop`(일시 정지), `Override`(리턴값 조작) 등 |

### 운영 환경 정책 예시

`/etc/shadow` 하나만 막는 건 테스트용입니다. 실 운영에서는 보호 범위를 확장합니다.

**민감 파일 디렉토리 전체 차단:**

```yaml
- matchArgs:
  - index: 1
    operator: "Prefix"
    values:
    - "/etc/ssl/private"
```

**특정 바이너리 실행 차단 (예: 컨테이너 내 curl):**

```yaml
kprobes:
- call: "security_bprm_check"
  syscall: false
  args:
  - index: 0
    type: "linux_binprm"
  selectors:
  - matchArgs:
    - index: 0
      operator: "Postfix"
      values:
      - "/usr/bin/curl"
    matchActions:
    - action: Sigkill
```

정책은 `kubectl apply -f`로 즉시 적용되며 재시작이 필요 없습니다.

```bash
kubectl apply -f manifests/block-sensitive-read.yaml
kubectl get tracingpolicy   # 적용 확인
kubectl delete tracingpolicy block-sensitive-read   # 정책 제거
```

## 3단계: 설치 실행

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

스크립트가 설치 후 TracingPolicy 적용 여부를 묻습니다.
적용할 정책 내용은 위의 TracingPolicy 이해 섹션을 참고하여 운영 환경에 맞게 수정한 뒤 진행하세요.

## 4단계: 설치 확인

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=tetragon
kubectl get tracingpolicy
```

## 5단계: 차단 정책 테스트

> `manifests/block-sensitive-read.yaml`은 `/etc/shadow` 읽기를 차단하는
> **테스트용 예시 정책**입니다.
> 실 운영 시에는 위의 TracingPolicy 이해 섹션을 참고하여 환경에 맞는 정책으로 교체하세요.

### 시스템 바이너리 제외 (`matchBinaries`)

`/etc/shadow`는 `sudo`, `su`, `passwd` 같은 시스템 인증 바이너리도 정상적으로 읽습니다.
이 바이너리들을 제외하지 않으면 **`sudo` 실행 시 즉시 Sigkill**되어 시스템 운영에 지장이 생깁니다.

`manifests/block-sensitive-read.yaml`은 아래 바이너리를 차단 대상에서 제외합니다.

```yaml
matchBinaries:
- operator: "NotIn"
  values:
  - "/usr/bin/sudo"
  - "/bin/sudo"
  - "/usr/bin/su"
  - "/bin/su"
  - "/usr/bin/passwd"
  - "/usr/sbin/login"
  - "/usr/lib/systemd/systemd"
```

운영 환경에서 추가로 제외가 필요한 바이너리가 있으면 이 목록에 추가합니다.

TracingPolicy 적용 후 `/etc/shadow` 읽기를 시도합니다.

```bash
kubectl run test-block --image=busybox --rm -it --restart=Never -- cat /etc/shadow
# 예상: cat 프로세스가 Sigkill로 즉시 종료 → 터미널에 "Killed" 출력
```

`--rm -it` 없이 exit code로 확인하는 방법:

```bash
kubectl run test-block --image=busybox --restart=Never -- sh -c "cat /etc/shadow; echo exit:$?"
kubectl logs test-block
# 출력: Killed
#       exit:0   (cat이 죽었지만 sh는 살아서 echo까지 실행됨)
kubectl delete pod test-block
```

Tetragon 이벤트 로그 확인:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon -f
```

## 트러블슈팅

### 차단이 동작하지 않는 경우

1. 커널 함수 심볼 확인

   ```bash
   grep -w fd_install /proc/kallsyms | head -3
   grep -w security_file_open /proc/kallsyms | head -3
   ```

   `fd_install` 심볼이 없으면 `manifests/block-sensitive-read.yaml`의
   `call` 값을 `security_file_open`으로 변경 후 재적용합니다.

2. `CONFIG_BPF_KPROBE_OVERRIDE` 확인

   ```bash
   grep CONFIG_BPF_KPROBE_OVERRIDE /boot/config-$(uname -r) 2>/dev/null \
     || zcat /proc/config.gz 2>/dev/null | grep CONFIG_BPF_KPROBE_OVERRIDE
   ```

   `=y`가 아니면 Sigkill 차단이 불가합니다. WSL2의 경우 `wsl --update` 후 재시작하면 해결되는 경우가 있습니다.

### Tetragon 파드가 Pending인 경우

```bash
kubectl describe pod -n kube-system -l app.kubernetes.io/name=tetragon
```

이미지 pull 실패라면 Harbor 업로드 및 `values.yaml` 이미지 경로를 재확인합니다.

## 삭제

```bash
chmod +x scripts/uninstall.sh
./scripts/uninstall.sh
```

---

## 별첨: Grafana 연동 체크리스트

Tetragon metrics를 Prometheus + Grafana 스택에 연동할 때 확인할 항목입니다.

> Tetragon 차트에는 Grafana 대시보드가 내장돼 있지 않습니다.
> ServiceMonitor로 metrics 수집 후 커뮤니티 대시보드를 import하거나 직접 작성해야 합니다.

| 항목 | 내용 | 비고 |
| :--- | :--- | :--- |
| metrics 엔드포인트 | `tetragon:2112/metrics` | 설치 시 자동 생성 |
| operator metrics | `tetragon-operator-metrics:2113/metrics` | 설치 시 자동 생성 |
| ServiceMonitor | Prometheus scrape 설정 생성 필요 | 미생성 |
| 대시보드 | 차트 내장 없음 — 별도 준비 필요 | 없음 |

**연동 순서:**

1. ServiceMonitor 생성으로 Prometheus scrape 활성화
2. Prometheus에서 `tetragon` target이 UP 상태인지 확인
3. Grafana에서 대시보드 import 또는 직접 작성
