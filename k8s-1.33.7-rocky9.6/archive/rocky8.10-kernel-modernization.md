# [Archive] Rocky Linux 8.10 커널 현대화 절차

> 본 문서는 본래 `k8s-1.33.7-rocky8.10/install-guide-online.md` 에 포함되어 있던
> Rocky Linux 8 전용 커널 업그레이드 + Cgroup v2 강제 활성화 절차의 보존본입니다.
>
> **Rocky Linux 9.6 이상에서는 불필요합니다** — 기본 커널(5.14+)이 K8s v1.33 의 eBPF / Cgroup v2 요구사항을
> 이미 충족하며, systemd 가 기본적으로 unified cgroup hierarchy(v2)로 부팅합니다.
>
> Rocky 8 환경으로 다시 운영해야 할 경우에만 참조하세요.

## 배경

Kubernetes v1.33+ 의 요구사항을 충족하기 위해 OS 커널을 메인라인(7.x)으로 업그레이드하고,
리소스 격리를 위한 Cgroup v2 설정을 강제 적용하는 절차입니다.

## 커널 업데이트 및 Cgroup v2 설정 명령어

```bash
# 1. ELRepo 저장소 등록 및 커널 설치
sudo rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
sudo dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm
sudo dnf --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel

# 2. GRUB 설정 수정 (Cgroup v2 활성화 파라미터 추가)
# GRUB_CMDLINE_LINUX 줄의 끝에 추가: systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all
sudo sed -i 's/GRUB_CMDLINE_LINUX="/&systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all /' /etc/default/grub

# 3. GRUB 설정 파일 재생성 (Legacy 및 UEFI 경로 모두 적용)
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg

# 4. 기본 부팅 커널 변경 (최신 설치된 커널로 설정)
sudo grubby --set-default /boot/vmlinuz-$(dnf list installed kernel-ml | grep kernel-ml | awk '{print $2}').x86_64

# 5. 재부팅
sudo reboot

# 6. 커널 및 Cgroup v2 적용 확인
uname -r
mount | grep cgroup2
```

## 기술적 근거

- **kernel-ml:** 최신 Kubernetes 의 eBPF 기반 네트워킹 및 리소스 관리 기능을 지원하기 위한 최소 요구
  커널 버전을 확보합니다.
- **`cgroup_no_v1=all`:** Rocky 8 의 systemd 가 Cgroup v1 컨트롤러를 점유하는 것을 방지하고,
  모든 컨트롤러를 v2 계층으로 강제 이동시켜 `cpuset` 누락 문제를 해결합니다.

## 주의 사항

- **Boot Path:** `grub2-mkconfig` 실행 시 `/boot/efi` 경로가 없는 시스템(Legacy BIOS)은 해당 명령에서
  오류가 날 수 있으나 무시해도 무방합니다.
- **Kernel ABI:** 최신 커널 사용 시 기존의 구형 커널 전용 드라이버(NVIDIA, 특정 스토리지 HBA 등)가
  로드되지 않을 수 있습니다.

## containerd 설치 (Rocky 8 전용 — glibc 2.28 우회)

Rocky 8 의 glibc 는 2.28 이고, containerd 공식 바이너리 v2.1.x 이상은 GLIBC_2.34 를 요구합니다.
또한 docker-ce el8 저장소는 `containerd.io` 가 1.6.32 에서 갱신이 멈춰 K8s 1.33 매트릭스
(`1.6.36+ / 1.7.24+`) 에 미달합니다. 따라서 Rocky 8 에서는 containerd 공식 GitHub 릴리스의
v1.7.x 바이너리 tarball 을 직접 설치해야 했습니다.

| 컴포넌트 | 버전 | 설치 경로 | 비고 |
| --- | --- | --- | --- |
| containerd | v1.7.31 | `/usr/local/bin` | GLIBC_2.4 요구 — Rocky 8 호환 |
| runc | v1.4.2 | `/usr/local/sbin/runc` | 정적 바이너리 |
| CNI plugins | v1.9.1 | `/opt/cni/bin` | |

```bash
# 1. containerd 본체 설치 (/usr/local 하위로 압축 해제)
CONTAINERD_VER=1.7.31
curl -fsSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz" \
    -o /tmp/containerd.tar.gz
sudo tar Cxzf /usr/local /tmp/containerd.tar.gz

# 2. systemd 유닛 설치
sudo curl -fsSL "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VER}/containerd.service" \
    -o /etc/systemd/system/containerd.service
sudo systemctl daemon-reload

# 3. runc 설치
RUNC_VER=1.4.2
curl -fsSL "https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64" \
    -o /tmp/runc
sudo install -m 755 /tmp/runc /usr/local/sbin/runc

# 4. CNI plugins 설치
CNI_VER=1.9.1
sudo mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz" \
    -o /tmp/cni.tgz
sudo tar Cxzf /opt/cni/bin /tmp/cni.tgz
```

> Rocky 8 에서는 `ctr` 이 `/usr/local/bin/ctr` 에 설치되고 `sudo` 의 `secure_path` 에는 `/usr/local/bin` 이
> 없으므로 `sudo ctr ...` 호출 시 "command not found" 가 발생합니다. 전체 경로(`sudo /usr/local/bin/ctr`),
> `visudo` 의 `secure_path` 끝에 `:/usr/local/bin` 추가, 또는 `sudo ln -sf /usr/local/bin/ctr /usr/bin/ctr`
> 중 하나로 해결합니다.
