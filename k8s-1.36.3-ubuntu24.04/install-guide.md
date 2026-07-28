# Kubernetes v1.36.3 보안 기준 오프라인 설치 가이드

## 1. 적용 대상

이 가이드는 Ubuntu Server 24.04 LTS amd64 신규 노드에 Kubernetes `v1.36.3`을 설치할 때 사용합니다. 기존 클러스터에 스크립트를 덮어 실행하는 용도가 아닙니다.

필수 사전 조건은 다음과 같습니다.

- 노드별 고정 IP와 고유 hostname
- 노드 간 TCP 6443, 2379-2380, 10250 및 Calico 통신 허용
- 시간 동기화
- swap 데이터 백업 또는 비활성화 승인
- Pod CIDR과 Service CIDR이 물리 네트워크와 겹치지 않음
- 외부망 수집 호스트와 폐쇄망 설치 호스트 모두 Ubuntu 24.04 amd64
- AppArmor와 UFW가 활성화 가능하고, 입력할 노드 CIDR이 관리 접속망을 포함함

## 2. 외부망 자산 수집

외부망 전용 Ubuntu 24.04 호스트에서 실행합니다.

```bash
cd k8s-1.36.3-ubuntu24.04
sudo ./scripts/download_assets_offline.sh
```

스크립트는 다음 자산을 수집합니다.

- Kubernetes `v1.36.3` DEB와 의존 패키지
- 해당 시점에 해석된 containerd.io 정확한 버전
- Kubernetes core image
- Calico `v3.32.1` manifest와 image
- local-path-provisioner `v0.0.35` manifest와 image
- Helm 및 nerdctl 바이너리
- `ASSET_VERSIONS.txt`와 `SHA256SUMS`

수집이 끝나면 실패 이미지가 없어야 합니다. 한 이미지라도 pull/export에 실패하면 스크립트가 비정상 종료합니다.

## 3. 폐쇄망 반입과 무결성 확인

디렉토리 전체를 폐쇄망으로 반입합니다. 설치 스크립트도 같은 검사를 수행하지만, 작업 전에 수동 확인하는 것을 권장합니다.

```bash
cd k8s-1.36.3-ubuntu24.04/k8s
sha256sum -c SHA256SUMS
cat ASSET_VERSIONS.txt
```

검증 실패 파일이 있으면 설치하지 말고 외부망 수집부터 다시 수행합니다.

## 4. 첫 Control Plane 설치

```bash
cd k8s-1.36.3-ubuntu24.04
sudo ./scripts/install.sh
```

메뉴에서 `첫 Control Plane 초기화`를 선택하고 다음 값을 입력합니다.

- 노드 통신 IP
- Control Plane endpoint
- Pod CIDR
- Service CIDR
- DNS domain
- Calico 자동 또는 수동 적용
- 일반 사용자 홈에 `admin.conf`를 복사할지 여부

보안을 위해 `admin.conf` 일반 사용자 복사는 기본값이 `N`입니다. 필요할 때만 cluster-admin 자격 증명의 위험을 이해한 후 선택합니다.

설치 과정에서 다음 런타임 파일이 생성됩니다.

```text
/etc/kubernetes/security/audit-policy.yaml
/etc/kubernetes/security/pod-security-admission-config.yaml
/etc/kubernetes/security/encryption-config.yaml
/var/log/kubernetes/audit/audit.log
```

암호화 키는 `/etc/kubernetes/security/encryption-config.yaml`에만 `0600` 권한으로 저장됩니다. 노드별 설정은 `/etc/kubernetes/installer/install.conf`에 `0600`으로 저장되며 비밀정보가 없습니다. 반입 패키지 디렉토리를 여러 노드가 공유해도 역할 설정이 섞이지 않습니다.

## 5. Worker 및 추가 Control Plane Join

첫 Control Plane에서 Worker join 정보를 생성합니다.

```bash
sudo kubeadm token create --print-join-command
```

추가 Control Plane용 인증서 키는 다음 명령으로 생성합니다.

```bash
sudo kubeadm init phase upload-certs --upload-certs
```

추가 Control Plane은 첫 Control Plane과 동일한 암호화 키가 반드시 필요합니다. 첫 노드의 `/etc/kubernetes/security/encryption-config.yaml`을 보안 매체로 반입해 추가 노드의 같은 경로에 `root:root`, `0600`으로 배치하고 양쪽 SHA-256을 대조합니다. 이 파일을 일반 파일 공유나 Git에 올리지 마십시오.

```bash
sudo install -d -m 0700 /etc/kubernetes/security
sudo install -m 0600 /secure-media/encryption-config.yaml \
  /etc/kubernetes/security/encryption-config.yaml
sudo sha256sum /etc/kubernetes/security/encryption-config.yaml
```

가입할 노드에서 동일 패키지를 준비하고 실행합니다.

```bash
cd k8s-1.36.3-ubuntu24.04
sudo ./scripts/install.sh
```

`Worker 노드 Join` 또는 `추가 Control Plane Join`을 선택하고 endpoint, token, CA hash를 입력합니다. Control Plane Join은 certificate key도 입력합니다. token과 certificate key는 `install.conf`에 저장되지 않습니다.

## 6. Kubelet Serving CSR 승인

`serverTLSBootstrap=true`이므로 kubelet serving certificate 요청이 생성될 수 있습니다. 요청자와 SAN을 확인하지 않은 일괄 자동 승인은 금지합니다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get csr
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get csr <csr-name> -o yaml
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl certificate approve <csr-name>
```

노드 이름, 사용자 `system:node:<node>`, 요청 IP/DNS SAN이 실제 노드와 일치할 때만 승인합니다.

## 7. 설치 후 점검

```bash
sudo ./scripts/security_audit.sh
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A
sudo kubeadm certs check-expiration
```

점검기는 설정을 변경하지 않습니다. `FAIL`은 설치 완료 조건을 충족하지 못한 것이며 원인을 해결해야 합니다. `WARN`은 CSR, Namespace 레이블처럼 운영자 판단이 필요한 항목입니다.

감사 로그 생성 여부도 확인합니다.

```bash
sudo test -s /var/log/kubernetes/audit/audit.log
sudo stat -c '%a %U:%G %n' /var/log/kubernetes/audit /var/log/kubernetes/audit/audit.log
```

암호화 신규 쓰기 검증은 테스트 Secret을 생성하고 etcd raw 데이터에 평문이 없는지 확인하는 방식으로 수행합니다. 운영 Secret을 출력하거나 복호화된 값을 로그에 남기지 마십시오.

## 8. 수동 설치와 복구

자동 스크립트를 실행할 수 없는 경우에만 사용합니다. 아래 예시는 단일 Control Plane 기준입니다.

### 8.1 패키지와 이미지 설치

```bash
# AppArmor와 UFW를 끄지 않습니다.
sudo aa-status --enabled
sudo ufw allow from 192.168.10.0/24 comment 'k8s-node-network'
sudo ufw route allow from 192.168.0.0/16 comment 'k8s-pod-network'
sudo ufw --force enable
sudo dpkg -i ./k8s/debs/*.deb || sudo apt-get install -f -y --no-download
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now containerd

for image in ./k8s/images/*.tar; do
  sudo ctr -n k8s.io images import "$image"
done
```

### 8.2 보안 정책과 암호화 키 생성

```bash
sudo install -d -m 0700 /etc/kubernetes/security /var/log/kubernetes/audit
sudo install -m 0600 ./security/audit-policy.yaml \
  /etc/kubernetes/security/audit-policy.yaml
sudo install -m 0600 ./security/pod-security-admission-config.yaml \
  /etc/kubernetes/security/pod-security-admission-config.yaml

ENCRYPTION_KEY=$(openssl rand -base64 32)
sudo install -m 0600 /dev/null /etc/kubernetes/security/encryption-config.yaml
cat <<EOF | sudo tee /etc/kubernetes/security/encryption-config.yaml >/dev/null
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
unset ENCRYPTION_KEY
```

### 8.3 kubeadm 설정 렌더링과 초기화

예시 값은 실제 환경 값으로 바꿉니다.

```bash
NODE_IP=192.168.10.10
CONTROL_PLANE_ENDPOINT=192.168.10.10:6443
ENDPOINT_HOST=${CONTROL_PLANE_ENDPOINT%:*}
POD_CIDR=192.168.0.0/16
SERVICE_CIDR=10.96.0.0/12
DNS_DOMAIN=cluster.local

sed \
  -e "s|__NODE_IP__|${NODE_IP}|g" \
  -e "s|__CONTROL_PLANE_ENDPOINT__|${CONTROL_PLANE_ENDPOINT}|g" \
  -e "s|__ENDPOINT_HOST__|${ENDPOINT_HOST}|g" \
  -e "s|__POD_CIDR__|${POD_CIDR}|g" \
  -e "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" \
  -e "s|__DNS_DOMAIN__|${DNS_DOMAIN}|g" \
  ./security/kubeadm-config.example.yaml | \
  sudo tee /run/kubeadm-v1.36.3.yaml >/dev/null
sudo chmod 600 /run/kubeadm-v1.36.3.yaml
sudo kubeadm init --config /run/kubeadm-v1.36.3.yaml --upload-certs
sudo rm -f /run/kubeadm-v1.36.3.yaml
```

수동 설치 전에는 `scripts/install.sh`의 `configure_host`와 같은 swap, kernel module, sysctl, containerd 설정이 선행되어야 합니다. 일부만 생략하면 `protectKernelDefaults=true` preflight가 실패할 수 있습니다.

### 8.4 Calico 수동 적용

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl apply -f ./k8s/utils/calico.yaml
```

기본값과 다른 Pod CIDR을 사용하면 원본 파일을 수정하지 말고 메모리 치환으로 적용합니다.

```bash
sed 's|192.168.0.0/16|10.244.0.0/16|g' ./k8s/utils/calico.yaml | \
  sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f -
```

## 9. 초기화

Kubernetes reset은 etcd와 노드 상태를 영구 삭제합니다. 일반 uninstall은 제공하지 않습니다.

```bash
sudo ./scripts/uninstall.sh --reset
```

패키지까지 제거하려면 다음 옵션을 함께 사용합니다.

```bash
sudo ./scripts/uninstall.sh --reset --purge-packages
```

두 단계 확인을 통과해야 실행됩니다. 다른 호스트 서비스 보호를 위해 iptables 전체 flush와 containerd 이미지 삭제는 자동 수행하지 않습니다.

## 10. 기존 클러스터 보완 원칙

이 신규 패키지를 기존 v1.30/v1.33 클러스터에 그대로 실행하지 마십시오. 기존 Secret 암호화 전환은 암호화 provider 배포, API server 순차 재시작, 기존 리소스 재기록, etcd 백업 검증이 필요합니다. 기존 버전 보완은 버전별 영향 분석 후 별도 절차로 진행합니다.
