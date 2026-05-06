# Tetragon 보안 정책 전략 가이드

## 개요

Tetragon의 TracingPolicy는 커널 레벨에서 동작하므로, 잘못 설계하면 관리자 본인이 시스템에서 잠길 수 있습니다. 이 문서는 **범위(Scope) 설계 → 정책 강도 단계적 적용 → Self-lockout 방지** 순서로 운영 환경에서 안전하게 정책을 운용하는 방법을 다룹니다.

---

## 1. 정책 범위 설계 원칙

### Cluster-wide vs Namespace-scoped

Tetragon은 두 가지 CRD를 제공합니다.

| CRD | 적용 범위 | 용도 |
| :--- | :--- | :--- |
| `TracingPolicy` | 클러스터 전체 (호스트 포함) | 시스템 전반 차단 |
| `TracingPolicyNamespaced` | 특정 K8s 네임스페이스의 파드만 | 앱 레이어 차단 |

**핵심 원칙:** 호스트 프로세스(systemd, sudo, sshd 등)에 영향을 주는 정책은 `TracingPolicy`(클러스터 전체)로 적용하고, 앱 파드에만 적용할 정책은 `TracingPolicyNamespaced`를 사용합니다.

`TracingPolicyNamespaced`를 사용하면 해당 네임스페이스의 파드 안에서 발생하는 이벤트만 잡히므로, 호스트의 sudo·PAM 인증에는 전혀 영향이 없습니다.

---

## 2. No-Sudo 강제 정책 (Hard-Lock)

### 전략

`/etc/sudoers`는 소프트웨어 설정이므로 취약점 악용 시 우회 가능합니다. Tetragon을 통해 커널 레벨에서 sudo 인증 자체를 막으면 `sudoers` 설정과 무관하게 권한 상승이 불가능해집니다.

### 구현: 애플리케이션 네임스페이스 한정

호스트 관리자에게 영향을 주지 않으면서 앱 파드에서의 sudo를 차단합니다.

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: no-sudo-in-app
  namespace: default        # 이 네임스페이스의 파드에만 적용
spec:
  kprobes:
  - call: "fd_install"
    syscall: false
    args:
    - index: 0
      type: int
    - index: 1
      type: "file"
    selectors:
    - matchArgs:
      - index: 1
        operator: "Equal"
        values:
        - "/etc/shadow"
      matchActions:
      - action: Sigkill
```

- `TracingPolicyNamespaced`는 해당 네임스페이스 파드 내부 이벤트만 처리합니다.
- 호스트의 sudo, PAM, sshd는 영향을 받지 않습니다.

### 구현: 클러스터 전체 강제 (Self-lockout 위험)

```yaml
# 주의: 아래 정책 적용 시 matchBinaries 예외 없이는 관리자도 sudo 불가
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: hard-no-sudo
spec:
  kprobes:
  - call: "fd_install"
    syscall: false
    args:
    - index: 0
      type: int
    - index: 1
      type: "file"
    selectors:
    - matchArgs:
      - index: 1
        operator: "Equal"
        values:
        - "/etc/shadow"
      matchActions:
      - action: Sigkill
```

클러스터 전체에 적용할 때는 반드시 **Break-glass 절차(5절)** 를 먼저 확보하세요.

---

## 3. Immutable Infrastructure: 위험 바이너리 실행 차단

### 전략

운영 컨테이너 이미지에 `sudo`, `su`, `bash`, `curl` 같은 도구가 포함되어 있으면 침해 시 내부에서 이 도구들이 악용됩니다. `security_bprm_check` kprobe로 **실행(exec) 단계**에서 차단합니다.

### 구현: 컨테이너 내 특정 바이너리 실행 차단

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: block-dangerous-binaries
  namespace: production
spec:
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
        - "/usr/bin/sudo"
        - "/bin/su"
        - "/usr/bin/curl"
        - "/usr/bin/wget"
        - "/bin/bash"     # 필요 시 — 영향 범위 충분히 검토 후 적용
      matchActions:
      - action: Sigkill
```

> `/bin/bash` 차단은 배포 스크립트·헬스체크 등 정상 동작에 영향을 줄 수 있습니다. 먼저 `Post` 액션으로 어떤 프로세스가 잡히는지 확인 후 차단 목록을 결정하세요.

---

## 4. 단계적 정책 강화 절차

운영 환경에 즉시 Sigkill을 걸면 예상치 못한 서비스 장애가 생길 수 있습니다. 아래 순서로 검증 후 강화합니다.

### 1단계: Post 액션으로 관찰

```yaml
matchActions:
- action: Post    # Sigkill 없이 Tetragon 로그에만 기록
```

정책을 적용하고 충분한 시간 동안 로그를 수집합니다.

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon -f \
  | grep "process_kprobe"
```

### 2단계: 잡히는 프로세스 분석

로그에서 `binary` 필드를 확인해 예상치 못한 프로세스가 있는지 점검합니다.

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon \
  | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        if 'process_kprobe' in d:
            p = d['process_kprobe'].get('process', {})
            print(p.get('binary'), p.get('arguments','')[:60])
    except: pass
" | sort | uniq -c | sort -rn
```

### 3단계: 필요한 예외 추가 후 Sigkill 적용

분석 결과를 토대로 `matchBinaries` 예외를 확정하고 `action: Sigkill`로 전환합니다.

---

## 5. Self-lockout 방지 및 Break-glass 절차

### 사전 조치

1. **SSH 키 기반 접근 유지:** 비밀번호 인증을 차단해도 SSH 키로는 접근 가능
2. **네임스페이스 범위 사용:** `TracingPolicyNamespaced`로 호스트 제외
3. **정책 적용 전 dry-run:** `Post` 액션으로 충분한 사전 검증

### Break-glass: 긴급 시 정책 제거

정책이 잘못 적용돼 잠긴 경우, Tetragon DaemonSet을 내리면 모든 TracingPolicy가 즉시 비활성화됩니다.

```bash
# Tetragon DaemonSet 스케일 다운 (모든 정책 즉시 해제)
kubectl scale daemonset tetragon -n kube-system --replicas=0

# 문제 해결 후 복구
kubectl scale daemonset tetragon -n kube-system --replicas=1
```

> **비상 접근 시나리오:** 호스트에 물리 또는 콘솔 접근 가능한 계정을 항상 확보해두세요. 클라우드 환경이면 시리얼 콘솔, 온프레미스라면 IPMI/iDRAC 등을 통해 접근합니다.

### 정책 삭제로 복구

```bash
# 특정 정책만 제거
kubectl delete tracingpolicy <policy-name>
kubectl delete tracingpolicynamespaced <policy-name> -n <namespace>
```

---

## 6. 시나리오별 권장 정책 조합

### 시나리오 A: 일반 웹 애플리케이션 클러스터

```text
목표: 앱 파드에서의 권한 상승 및 외부 통신 도구 실행 차단
범위: production, staging 네임스페이스
```

| 정책 | CRD | 액션 |
| :--- | :--- | :--- |
| /etc/shadow 읽기 차단 | `TracingPolicyNamespaced` | Sigkill |
| curl/wget 실행 차단 | `TracingPolicyNamespaced` | Sigkill |
| 민감 경로 쓰기 차단 | `TracingPolicyNamespaced` | Sigkill |

호스트(`kube-system`)는 정책 대상에서 제외되므로 관리자 운영에 지장 없음.

### 시나리오 B: 고보안 금융/규정 준수 환경

```text
목표: 어떤 수단으로도 권한 상승 불가 (커널 레벨 강제)
범위: 클러스터 전체
```

| 정책 | CRD | 액션 | 비고 |
| :--- | :--- | :--- | :--- |
| /etc/shadow 읽기 차단 | `TracingPolicy` | Sigkill | unix_chkpwd 등 예외 없음 |
| sudo/su 실행 차단 | `TracingPolicy` | Sigkill | - |
| /etc/passwd 쓰기 차단 | `TracingPolicy` | Sigkill | - |

Break-glass: SSH 키 기반 root 접근 + 물리 콘솔 접근 경로 확보 필수.

### 시나리오 C: 개발/스테이징 (탐지 위주)

```text
목표: 차단 없이 이상행위 탐지 및 가시성 확보
```

모든 정책을 `action: Post`로 적용해 로그만 수집합니다. 임계치 초과 시 Alertmanager 알림으로 연결하고, 사고 발생 시에만 Sigkill로 전환합니다.

---

## 참고

- [Tetragon TracingPolicy 공식 문서](https://tetragon.io/docs/concepts/tracing-policy/)
- [TracingPolicyNamespaced](https://tetragon.io/docs/concepts/tracing-policy/namespaced/)
- [Selectors 레퍼런스](https://tetragon.io/docs/concepts/tracing-policy/selectors/)
