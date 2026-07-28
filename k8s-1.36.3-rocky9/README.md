# Kubernetes v1.36.3 Rocky 9 보안 설치 패키지

Rocky Linux 9 amd64에 Kubernetes `v1.36.3`을 설치하는 에어갭 패키지입니다. `K8s취약점_점검_가이드.pdf`의 Control Plane 및 Worker 점검 항목을 신규 설치 기본값에 반영합니다.

## 지원 범위

- Kubernetes: `v1.36.3`
- 운영체제: Rocky Linux 9 최신 마이너, amd64
- 작성 시점 기준 마이너: Rocky Linux `9.8`
- 컨테이너 런타임: containerd, `SystemdCgroup=true`, SELinux 활성화
- 자동 CNI: Calico `v3.32.1`, L2/IPIP 기준
- kubeadm API: `kubeadm.k8s.io/v1beta4`
- 설치 역할: 첫 Control Plane, 추가 Control Plane, Worker

패키지명은 특정 Rocky 마이너에 고정하지 않습니다. 외부망 수집기는 Rocky 9를 최신 마이너로 업데이트한 뒤 RPM을 수집하고 `ASSET_VERSIONS.txt`에 정확한 마이너를 기록합니다. 설치기는 대상 노드의 마이너가 이 값과 다르면 설치를 중단합니다.

## 기본 보안 제어

- SELinux `Enforcing` 유지 및 containerd SELinux 지원 활성화
- firewalld 유지, 노드 및 Pod 내부 통신 CIDR만 trusted zone에 등록
- NetworkManager가 Calico 가상 인터페이스를 관리하지 않도록 설정
- RPM GPG 서명과 전체 반입 자산 SHA-256 검증
- kube-apiserver 익명 인증 차단 및 `Node,RBAC` 인가
- `NodeRestriction`과 Pod Security Admission 적용
- Secret 및 ConfigMap AES-CBC 암호화 at rest
- API 감사 정책과 로그 회전 설정
- TLS 1.2 이상 및 제한된 cipher suite
- controller-manager와 scheduler 로컬 bind 및 profiling 차단
- kubelet anonymous/read-only port 차단, Webhook 인증 및 인가
- kubelet 인증서 회전, serving CSR, seccomp 기본 활성화
- `admin.conf` 일반 사용자 홈 복사 기본 비활성화
- 설치 후 읽기 전용 `security_audit.sh` 자동 실행

## 디렉터리

```text
k8s-1.36.3-rocky9/
├── k8s/
│   ├── binaries/
│   ├── images/
│   ├── keys/
│   ├── rpms/
│   └── utils/
├── scripts/
│   ├── download_assets_offline.sh
│   ├── install.sh
│   ├── security_audit.sh
│   └── uninstall.sh
├── security/
│   ├── audit-policy.yaml
│   ├── kubeadm-config.example.yaml
│   └── pod-security-admission-config.yaml
├── install-guide.md
└── security-baseline.md
```

## 빠른 시작

인터넷 연결이 가능한 Rocky Linux 9 amd64 수집 호스트에서 실행합니다. 수집기는 호스트를 최신 Rocky 9 마이너로 업데이트합니다.

```bash
cd k8s-1.36.3-rocky9
sudo ./scripts/download_assets_offline.sh
```

`ASSET_VERSIONS.txt`의 `OS=rocky-X.Y`와 같은 마이너로 업데이트된 폐쇄망 노드에 전체 디렉터리를 반입한 뒤 설치합니다.

```bash
cd k8s-1.36.3-rocky9
sudo ./scripts/install.sh
```

설치 후 또는 정기 점검 시 실행합니다.

```bash
sudo ./scripts/security_audit.sh
```

상세 절차는 [install-guide.md](install-guide.md), 통제 항목과 잔여 위험은 [security-baseline.md](security-baseline.md)를 참조하십시오.

## 중요한 제한

- 기존 클러스터에 보안 설정을 자동 덮어쓰지 않습니다.
- SELinux Disabled 상태에서는 설치하지 않습니다.
- trusted zone에는 관리자가 입력한 노드 네트워크와 Pod CIDR이 등록됩니다. 외부망은 별도 최소 허용 규칙으로 관리해야 합니다.
- 암호화 키는 `/etc/kubernetes/security/encryption-config.yaml`에만 `0600`으로 저장합니다.
- kubelet serving CSR은 요청자와 SAN 검증 없이 자동 승인하지 않습니다.
- 애플리케이션별 RBAC, NetworkPolicy, 이미지 취약점 스캔은 별도 운영 통제가 필요합니다.
