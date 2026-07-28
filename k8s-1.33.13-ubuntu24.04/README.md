# Kubernetes v1.33.13 보안 기준 오프라인 설치 패키지

Ubuntu 24.04 amd64 환경에 Kubernetes `v1.33.13`을 설치하는 에어갭 패키지입니다. 단순 설치가 아니라 `K8s취약점_점검_가이드.pdf`의 Master/Worker 점검 항목을 설치 기본값에 반영하는 첫 기준 구현입니다.

> Kubernetes 1.33은 업스트림 지원 종료 상태입니다. 이 패키지는 호환성 유지용 최종 패치이며,
> 설치 시 `ALLOW_EOL_INSTALL=YES` 명시 승인이 필요합니다. 신규 운영 환경에는 1.36 패키지를 사용하십시오.

## 지원 범위

- Kubernetes: `v1.33.13`
- 운영체제: Ubuntu Server 24.04 LTS amd64
- 컨테이너 런타임: containerd, `SystemdCgroup=true`
- 자동 CNI: Calico `v3.31.6`
- kubeadm API: `kubeadm.k8s.io/v1beta4`
- 설치 역할: 첫 Control Plane, 추가 Control Plane, Worker

Cilium은 Kubernetes v1.33에 대한 공식 호환 범위가 확인된 버전을 패키지에 확보하기 전까지 자동 설치 대상에서 제외합니다.

## 기본 보안 제어

- AppArmor 활성 상태 강제 및 설치 후 감사
- UFW 유지, 노드 통신 CIDR과 Pod 라우팅 CIDR만 설치기 규칙으로 관리
- kube-apiserver 익명 인증 차단 및 `Node,RBAC` 인가
- `NodeRestriction`과 Pod Security Admission 적용
- Secret/ConfigMap AES-CBC 암호화 at rest
- API 감사 정책과 로그 보존 설정
- TLS 1.2 이상 및 제한된 cipher suite
- controller-manager/scheduler 로컬 bind와 profiling 차단
- kubelet anonymous/read-only port 차단, Webhook 인증·인가
- kubelet 인증서 회전, serving CSR, seccomp 기본 활성화
- `admin.conf` 일반 사용자 홈 복사는 기본 비활성화
- 설치 자산 `SHA256SUMS` 검증 실패 시 설치 중단
- 설치 후 읽기 전용 `security_audit.sh` 자동 실행

## 디렉토리

```text
k8s-1.33.13-ubuntu24.04/
├── k8s/
│   ├── binaries/
│   ├── debs/
│   ├── images/
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

외부망 Ubuntu 24.04 호스트에서 자산을 수집합니다.

```bash
cd k8s-1.33.13-ubuntu24.04
sudo ./scripts/download_assets_offline.sh
```

전체 디렉토리를 폐쇄망 노드로 반입한 뒤 설치합니다.

```bash
cd k8s-1.33.13-ubuntu24.04
sudo env ALLOW_EOL_INSTALL=YES ./scripts/install.sh
```

설치 후 또는 정기 점검 시 실행합니다.

```bash
sudo ./scripts/security_audit.sh
```

상세 절차와 수동 복구는 [install-guide.md](install-guide.md), 통제 항목과 잔여 위험은 [security-baseline.md](security-baseline.md)를 참조하십시오.

## 중요한 제한

- 기존 클러스터에 보안 설정을 자동 덮어쓰지 않습니다. 기존 버전 보완은 별도 영향 분석과 단계적 마이그레이션이 필요합니다.
- 암호화 설정 파일과 암호화 키는 `/etc/kubernetes/security/encryption-config.yaml`에만 `0600`으로 생성되며 저장소나 `install.conf`에 기록하지 않습니다.
- kubelet serving CSR은 요청자와 SAN 검증 없이 자동 승인하지 않습니다.
- 애플리케이션별 RBAC 최소 권한, NetworkPolicy, 이미지 취약점 스캔은 별도의 운영 통제가 필요합니다.
