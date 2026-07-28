# Kubernetes v1.30.14 Rocky 9 보안 설치 가이드

## 1. 적용 대상
> [주의] 이 Kubernetes 마이너는 업스트림 지원 종료 상태입니다. 호환성 유지가 필요한 경우에만
> 최종 패치 버전을 사용하고, 설치 시 `ALLOW_EOL_INSTALL=YES`로 잔여 위험을 명시적으로 승인하십시오.

이 가이드는 Rocky Linux 9 amd64 신규 노드에 Kubernetes `v1.30.14`를 설치할 때 사용합니다. 작성 시점의 최신 Rocky 9 마이너는 `9.8`이며, 수집 스크립트는 실행 시점의 최신 Rocky 9 마이너로 호스트를 업데이트합니다.

필수 조건은 다음과 같습니다.

- 노드별 고정 IP와 고유 hostname
- 노드 간 Kubernetes 및 Calico 통신 허용
- Pod CIDR과 Service CIDR이 물리 네트워크와 겹치지 않음
- 시간 동기화
- swap 비활성화 승인
- SELinux `Enforcing` 또는 `Permissive`; Disabled는 지원하지 않음
- 외부망 수집 호스트와 폐쇄망 설치 노드가 동일한 Rocky 9 마이너와 amd64 아키텍처

## 2. 외부망 자산 수집

인터넷 연결이 가능한 Rocky Linux 9 amd64 전용 호스트에서 실행합니다. 스크립트가 `dnf upgrade --refresh`를 수행하므로 수집 전에 시스템 스냅샷 또는 변경 승인을 준비합니다.

```bash
cd k8s-1.30.14-rocky9
sudo ./scripts/download_assets_offline.sh
```

수집 대상은 다음과 같습니다.

- Kubernetes `v1.30.14` RPM 및 전체 의존 RPM
- containerd.io, SELinux, firewalld, NetworkManager, versionlock 관련 RPM
- Kubernetes core image
- Calico `v3.29.7` manifest와 image
- local-path-provisioner `v0.0.35` manifest와 image
- Helm 및 nerdctl 바이너리
- Kubernetes 및 Docker RPM 서명 키
- `ASSET_VERSIONS.txt`와 `SHA256SUMS`

한 이미지라도 pull 또는 export에 실패하면 수집은 실패합니다. 완료 후 `ASSET_VERSIONS.txt`에서 `OS=rocky-X.Y`를 확인합니다.

## 3. 폐쇄망 반입과 OS 정렬

폐쇄망 노드를 수집 기준과 같은 Rocky 마이너로 먼저 업데이트합니다. 내부 Rocky 미러, ISO 또는 별도 승인된 오프라인 RPM 저장소를 사용하십시오.

```bash
cd k8s-1.30.14-rocky9/k8s
cat ASSET_VERSIONS.txt
sha256sum -c SHA256SUMS
cat /etc/os-release
```

예를 들어 수집 정보가 `OS=rocky-9.8`이면 대상 노드의 `VERSION_ID`도 `9.8`이어야 합니다. 설치기는 불일치 시 중단합니다.

## 4. 첫 Control Plane 설치

```bash
cd k8s-1.30.14-rocky9
sudo env ALLOW_EOL_INSTALL=YES ./scripts/install.sh
```

메뉴에서 `첫 Control Plane 초기화`를 선택하고 다음 값을 입력합니다.

- 노드 통신 IP
- 노드 간 통신을 허용할 내부 네트워크 CIDR
- Control Plane endpoint
- Pod CIDR과 Service CIDR
- DNS domain
- Calico 자동 또는 수동 적용
- 일반 사용자 홈에 `admin.conf`를 복사할지 여부

설치기는 SELinux를 `Enforcing`으로 유지하고 containerd SELinux 지원을 활성화합니다. firewalld는 끄지 않으며 입력한 노드 내부 CIDR과 Pod CIDR만 trusted zone source로 등록합니다.

암호화 키는 `/etc/kubernetes/security/encryption-config.yaml`에 `0600`으로 생성됩니다. 노드 설정은 `/etc/kubernetes/installer/install.conf`에 `0600`으로 저장하며 token, certificate key 또는 암호화 키는 기록하지 않습니다.

## 5. Worker 및 추가 Control Plane Join

첫 Control Plane에서 Worker join 정보를 생성합니다.

```bash
sudo kubeadm token create --print-join-command
```

추가 Control Plane용 인증서 키를 생성합니다.

```bash
sudo kubeadm init phase upload-certs --upload-certs
```

추가 Control Plane에는 첫 노드의 암호화 설정이 반드시 필요합니다. 보안 매체로 같은 경로에 배치하고 SHA-256을 대조합니다.

```bash
sudo install -d -m 0700 /etc/kubernetes/security
sudo install -m 0600 /secure-media/encryption-config.yaml \
  /etc/kubernetes/security/encryption-config.yaml
sudo sha256sum /etc/kubernetes/security/encryption-config.yaml
```

가입할 노드에서 같은 패키지를 실행하고 Worker 또는 추가 Control Plane을 선택합니다. bootstrap token과 certificate key는 `install.conf`에 저장되지 않습니다.

## 6. Kubelet Serving CSR 승인

serving certificate 요청은 자동 승인하지 않습니다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get cs
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get csr <csr-name> -o yaml
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl certificate approve <csr-name>
```

사용자 `system:node:<node>`와 요청 IP 및 DNS SAN이 실제 노드와 일치할 때만 승인합니다.

## 7. 설치 후 점검

```bash
sudo ./scripts/security_audit.sh
sudo getenforce
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --permanent --zone=trusted --list-sources
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A
sudo kubeadm certs check-expiration
```

`security_audit.sh`의 `FAIL`은 설치 완료 조건을 충족하지 못한 것입니다. `WARN`은 CSR이나 Namespace 정책처럼 운영자 확인이 필요한 항목입니다.

## 8. 수동 설치와 복구

자동 설치기를 사용할 수 없는 경우에만 수행합니다.

### 8.1 RPM과 이미지 설치

```bash
sudo rpm --import ./k8s/keys/kubernetes-rpm-signing-key.asc
sudo rpm --import ./k8s/keys/docker-rpm-signing-key.asc
for package in ./k8s/rpms/*.rpm; do
  sudo rpm --checksig "$package"
done
sudo dnf install -y --disablerepo='*' ./k8s/rpms/*.rpm
sudo dnf versionlock add kubelet kubeadm kubectl containerd.io

for image in ./k8s/images/*.tar; do
  sudo ctr -n k8s.io images import "$image"
done
```

### 8.2 호스트 보안 설정

```bash
sudo setenforce 1
sudo swapoff -a
sudo modprobe overlay
sudo modprobe br_netfilter
sudo sysctl --system
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --zone=trusted --add-source=192.168.10.0/24
sudo firewall-cmd --permanent --zone=trusted --add-source=192.168.0.0/16
sudo firewall-cmd --reload
```

`/etc/containerd/config.toml`에는 `SystemdCgroup = true`와 `enable_selinux = true`가 필요합니다. `/etc/modules-load.d/k8s.conf`, `/etc/sysctl.d/99-kubernetes-security.conf`, NetworkManager의 Calico unmanaged 설정은 `scripts/install.sh`의 `configure_host`와 동일하게 적용합니다.

### 8.3 보안 정책과 암호화 키 생성

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

### 8.4 kubeadm 설정 렌더링과 초기화

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
  sudo tee /run/kubeadm-v1.30.14.yaml >/dev/null
sudo chmod 600 /run/kubeadm-v1.30.14.yaml
sudo kubeadm config validate --config /run/kubeadm-v1.30.14.yaml
sudo kubeadm init --config /run/kubeadm-v1.30.14.yaml --upload-certs
sudo rm -f /run/kubeadm-v1.30.14.yaml
```

### 8.5 Calico 적용

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl apply -f ./k8s/utils/calico.yaml
```

다른 Pod CIDR이면 원본 파일을 수정하지 말고 메모리에서 치환합니다.

```bash
sed 's|192.168.0.0/16|10.244.0.0/16|g' ./k8s/utils/calico.yaml | \
  sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f -
```

## 9. 초기화

Kubernetes reset은 etcd와 노드 상태를 영구 삭제합니다.

```bash
sudo ./scripts/uninstall.sh --reset
```

RPM까지 제거하려면 다음 옵션을 함께 사용합니다.

```bash
sudo ./scripts/uninstall.sh --reset --purge-packages
```

두 단계 확인을 통과해야 합니다. 설치기가 추가한 trusted source만 제거하고 SELinux Enforcing 및 firewalld 서비스는 유지합니다. 다른 서비스 보호를 위해 iptables 전체 flush와 containerd 이미지 삭제는 수행하지 않습니다.

## 10. 기존 클러스터 보완 원칙

이 패키지를 기존 클러스터에 덮어 실행하지 마십시오. 기존 Secret 암호화 전환은 etcd 백업, 암호화 provider 배포, API server 순차 재시작, 기존 리소스 재기록과 복구 검증이 필요합니다. 기존 버전은 버전별 영향 분석 후 별도 절차로 보완합니다.
