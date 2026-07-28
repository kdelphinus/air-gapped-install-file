# Kubernetes v1.33.13 Rocky 9 보안 기준과 잔여 위험

## 1. 기준

이 문서는 `K8s취약점_점검_가이드.pdf`의 Control Plane 17개 및 Worker 7개 점검 영역을 신규 설치 기본값에 반영한 결과를 설명합니다. 제품 버전은 Kubernetes `v1.33.13`, kubeadm 설정 API는 `v1beta4`입니다.

운영체제는 Rocky Linux 9 최신 마이너를 기준으로 합니다. 작성 시점에는 Rocky Linux `9.8`이며, 수집 시점의 정확한 마이너를 `ASSET_VERSIONS.txt`에 고정합니다.

## 2. 점검 항목 대응

| 영역 | 설치 기본값 | 검증 위치 |
| --- | --- | --- |
| OS 패치 정렬 | 최신 Rocky 9에서 수집, 대상 마이너 일치 강제 | `ASSET_VERSIONS.txt`, `/etc/os-release` |
| RPM 신뢰 | Kubernetes 및 Docker GPG 키 import, `rpm --checksig` | 설치 로그, RPM 서명 |
| SELinux | `Enforcing`, containerd `enable_selinux=true` | `getenforce`, containerd config |
| 호스트 방화벽 | firewalld 유지, 내부 노드/Pod CIDR만 trusted source | firewalld zone |
| API 익명 접근 | `anonymous-auth=false` | kube-apiserver manifest |
| API 인가 | `authorization-mode=Node,RBAC` | kube-apiserver manifest |
| Admission | `NodeRestriction`, Pod Security Admission | API 인자와 PSA 설정 |
| ServiceAccount 검증 | `service-account-lookup=true` | kube-apiserver manifest |
| API profiling | `profiling=false` | kube-apiserver manifest |
| API TLS | TLS 1.2 이상, 제한된 cipher suite | kube-apiserver manifest |
| 감사 로그 | 정책, 로그 경로, 30일/10개/100MiB 회전 | API 인자와 로그 경로 |
| etcd 저장 암호화 | Secret/ConfigMap AES-CBC, identity fallback | EncryptionConfiguration |
| etcd 인증 | client/peer certificate auth | etcd manifest |
| controller-manager | localhost bind, profiling 차단, SA credential | static Pod manifest |
| scheduler | localhost bind, profiling 차단 | static Pod manifest |
| kubelet 익명 접근 | 비활성화 | kubelet config |
| kubelet 인증 및 인가 | X.509/Webhook, Webhook authorization | kubelet config |
| kubelet read-only port | `0` | kubelet config |
| kubelet kernel 보호 | `protectKernelDefaults=true`와 선행 sysctl | kubelet config, host |
| kubelet 인증서 | client rotation과 serving bootstrap | kubelet config, CSR |
| kubelet TLS | TLS 1.2 이상, 제한된 cipher suite | kubelet config |
| seccomp | kubelet 기본 seccomp 활성화 | kubelet config |
| kubeconfig 권한 | root 소유 `0600` | 파일 권한 |
| cluster-admin 배포 | 사용자 홈 복사 기본 거부 | 설치 입력과 marker |
| 자산 무결성 | SHA-256 불일치 및 미등록 파일 시 설치 중단 | `SHA256SUMS` |

## 3. Rocky 9 호스트 통제

### 3.1 SELinux

SELinux Disabled 노드는 설치를 거부합니다. Permissive는 설치 중 Enforcing으로 전환하며 `/etc/selinux/config`에도 영구 반영합니다. 설치 후 정책 거부가 발생하면 SELinux를 끄지 말고 AVC 로그를 분석해 필요한 정책만 추가합니다.

### 3.2 firewalld

firewalld 서비스는 끄지 않습니다. 설치 시 입력한 노드 네트워크 CIDR과 Pod CIDR을 trusted zone source로 추가합니다. 이 범위의 모든 트래픽을 신뢰하므로 관리 네트워크를 넓게 입력하지 않아야 합니다. 외부 API 접근, NodePort, LoadBalancer 접근은 별도 zone과 최소 포트 규칙으로 관리합니다.

### 3.3 NetworkManager

Calico가 만드는 `cali*`, `tunl*`, `vxlan.calico` 인터페이스는 NetworkManager 관리 대상에서 제외합니다. reset은 설치기가 만든 설정 파일만 제거합니다.

## 4. 의도적으로 자동화하지 않은 항목

### 4.1 Kubelet Serving CSR 승인

CSR 일괄 승인은 위조 노드가 serving certificate를 얻는 위험이 있습니다. 노드 identity와 SAN을 확인한 후 개별 승인해야 합니다.

### 4.2 기존 클러스터 보안 설정 덮어쓰기

기존 API server에 암호화 provider를 즉시 적용하거나 키를 바꾸면 읽기 불능 또는 롤백 불능 상황이 생길 수 있습니다. 새 설치만 자동 구성하고 기존 클러스터는 감지 즉시 중단합니다.

### 4.3 호스트 방화벽 전체 초기화

다른 서비스의 방화벽까지 제거할 수 있으므로 reset은 설치기가 추가한 trusted source만 삭제하고 firewalld와 iptables 전체 상태는 보존합니다.

## 5. 남아 있는 운영 위험

### 5.1 버전과 CVE

`v1.33.13`과 Rocky 9 최신 마이너는 패키지 작성 시점 기준입니다. 이후 Kubernetes patch release, Rocky errata 또는 보안 공지가 나오면 외부망에서 자산을 다시 수집하고 단계적으로 업그레이드해야 합니다.

### 5.2 RBAC 최소 권한

배포되는 각 서비스의 ClusterRole과 binding 최소화는 별도 검토가 필요합니다. `cluster-admin` binding을 정기 점검해야 합니다.

### 5.3 NetworkPolicy

Calico 설치만으로 workload 간 통신이 자동 차단되지는 않습니다. Namespace별 default-deny와 필요한 DNS, ingress, egress 허용 정책을 추가해야 합니다.

### 5.4 이미지 공급망

`SHA256SUMS`는 반입 중 변조를 탐지하지만 upstream publisher 신뢰와 이미지 취약점까지 증명하지 않습니다. 수집 구역에서 SBOM, signature, CVE scan 결과를 함께 승인해야 합니다.

### 5.5 EncryptionConfiguration 백업

`encryption-config.yaml`을 잃으면 etcd의 암호화된 Secret과 ConfigMap을 복호화하지 못합니다. 일반 백업과 분리된 보안 저장소에 백업하고 접근을 감사해야 합니다.

### 5.6 Pod Security Standards

기본 enforce는 `baseline`, audit와 warn은 `restricted`입니다. 업무 Namespace는 검증 후 `restricted` enforce로 단계적으로 올려야 합니다.

## 6. 정기 점검

```bash
sudo ./scripts/security_audit.sh
sudo getenforce
sudo firewall-cmd --permanent --zone=trusted --list-sources
sudo kubeadm certs check-expiration
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl auth can-i --list
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get cs
```

`WARN`은 자동 승인 대상이 아니며 운영 증적과 함께 판단합니다.
