# Antigravity Context: Air-gapped Infrastructure Deployment

This project is a repository of installation assets, scripts, and documentation
for deploying a full infrastructure stack in an **air-gapped (offline)**
environment.

## 🎯 Project Goals

- Provide repeatable, offline installation processes for core devops tools.
- Target Environments: **Rocky Linux (RHEL-based)** and **Ubuntu (Debian-based)**
  systems.
- Centralized image management using **Harbor**.

## 🏗️ Project Structure

Each top-level directory represents a component of the stack, often organized
by OS:

- `docker-offline-*`: Docker engine installation (e.g., for Rocky Linux).
- `k8s-*`: Kubernetes cluster setup (RPMs/DEBs, binaries, images).
- `harbor-*`: Enterprise container registry setup.
- `gitlab-*`: GitLab EE deployment.
- `gitea-*`: Lightweight Git service (Gitea).
- `jenkins-*`: Jenkins CI/CD deployment and plugin management.
- `tekton-*`: Kubernetes-native CI/CD framework (Tekton).
- `mariadb-*`: Database installation.
- `redis-stream-*`: Redis Stream HA configuration (Sentinel).
- `envoy-*`: Envoy Gateway configuration.
- `nginx-nic-*`: NGINX Ingress Controller.
- `metallb-*`: MetalLB LoadBalancer.
- `monitoring-*`: Prometheus + Grafana stack.
- `nexus-*`: Nexus Repository Manager.
- `velero-*`: Backup/Restore.
- `falco-*`: Runtime security detection.
- `tetragon-*`: Runtime security prevention.
- `nfs-provisioner-*`: Dynamic NFS storage provisioning for K8s.
- `basic-tools-*`: Essential utilities for specific OS versions.

## 🛠️ Key Conventions & Tech Stack

- **OS**: Multi-OS support including RHEL-based (e.g., Rocky Linux) and Debian-based (e.g., Ubuntu) systems.
- **Scripts**: Primarily Bash (`.sh`). Many scripts handle offline image
  loading (`docker load`) and pushing to local Harbor. Scripts should handle
  OS-specific differences (e.g., `dnf` vs `apt`).
- **Orchestration**: Kubernetes (K8s) via Helm charts and static manifests.
- **Storage**: Mixed (HostPath, NFS, Manual PVs).
- **Offline Strategy**:
  - Download all RPMs/DEBs/Binaries beforehand.
  - Export container images to `.tar` or `.tgz` files.
  - Use local Harbor (Default Port 30002 or Domain-based) as the image registry.

## 📖 Key Documentation

- Root folders contain specific `README.md` or `guide.md` files for each
  component.
- Check `harbor&ingress_install_guide.md` for the core connectivity setup.

## 🤖 AI Instructions

- Always assume **no internet access**. All tools and dependencies must be
  sourced from within the repository or the local network.
- When generating scripts, prefer Bash and ensure they are compatible with
  the target OS versions.
- For Kubernetes resources, prioritize stability and data persistence
  (`Retain` policy for PVs).
- Reference existing `upload_images_to_harbor_v3-lite.sh` scripts when
  dealing with container images.
- **Commit Strategy**: When performing multiple independent tasks, always
  separate them into multiple logical commits instead of a single monolithic
  commit. **All git commit messages must be written in Korean.**
  Every commit message must strictly adhere to the following format:
  ```text
  <type>: <title>

  - <detail description line 1>
  - <detail description line 2>

  Co-Authored-By: Antigravity <noreply@google.com>
  ```
  Example:
  ```text
  fix: MetalLB v0.16.1 설치 스크립트 내 \$@ 변수 확장 방지를 위한 이스케이프 추가

  - install.sh 내 sed 치환 명령에서 @ 구분자를 도입하면서 \$@ 형태로 쉘 특수 변수가 구성되어 빈 인자로 자동 확장 및 삭제되던 버그 수정
  - 정규식의 끝을 타겟팅하는 \$ 문자 앞에 역슬래시(\\\$) 이스케이프를 추가하여 온전한 문자열로 해석되도록 조치

  Co-Authored-By: Antigravity <noreply@google.com>
  ```
- **Engineering Standards**: All infrastructure component creation, script development, and documentation MUST strictly adhere to the project standards defined in [INFRA_STANDARD_GUIDE.md](INFRA_STANDARD_GUIDE.md). This includes:
  - **Directory Structure**: Standardized folder layout for all services.
  - **Scripting Standards**: Stateful `install.sh` logic with `install.conf` and `sed`-based sync.
  - **Documentation Standards**: Mandatory manual installation procedures in `install-guide.md`.
- Handle OS-specific package management:
  - RHEL/Rocky: `dnf localinstall` / `yum`
  - Ubuntu/Debian: `dpkg -i` / `apt install`
- **Markdown Standards**: All markdown files created or modified MUST comply with markdownlint rules:
  - Headers must be ATX style (`#`), and levels must increment sequentially (h1 → h2 → h3).
  - List indentation must be 2 spaces; ordered lists can use `1.` consistently.
  - Code blocks must specify their language (e.g., ` ```bash `, ` ```yaml `).
  - Blank lines: 1 blank line before and after headers, lists, and code blocks.
  - No trailing spaces at the end of lines, and exactly 1 newline at the end of the file.
  - Raw HTML tags are prohibited.
