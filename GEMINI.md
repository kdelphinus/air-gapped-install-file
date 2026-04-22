# Gemini Context: Air-gapped Infrastructure Deployment

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
- `ingress-nginx-*`: K8s Ingress controller.
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
- **Engineering Standards**:
  - **Markdownlint**: Always adhere to markdownlint standards (including headers, language tags for code blocks, and list spacing).
  - **Directory Structure**: All service components must follow the standard structure below:

    ```text
    <component>/
    ├── charts/          # Helm charts (folder or .tgz)
    ├── images/          # .tar files + Harbor upload script
    ├── manifests/       # K8s manifests (HTTPRoute, PV/PVC, etc.)
    ├── scripts/         # Install/Operation scripts (Root-relative execution)
    ├── values.yaml      # Production values (Harbor-based)
    ├── README.md        # Service specifications and specs
    └── install-guide.md # Phase-based installation instructions
    ```

  - **Execution Logic & Scripts**:
    - All scripts in `scripts/` must work relative to the component root using `cd "$(dirname "$0")/.."`.
    - **Installation Scripts (`install.sh`)** MUST implement the following stateful and interactive behaviors:
      - Implement a configuration persistence mechanism using an `install.conf` file to save user inputs (e.g., Image source, Storage type, Service type).
      - If an existing installation or `install.conf` is detected, the script MUST prompt the user with options to:
        1. **Upgrade**: Retain existing data/settings and perform a `helm upgrade`.
        2. **Reinstall**: Clean up existing Helm releases/resources and install from scratch.
        3. **Reset**: Completely remove all resources, namespaces, and the `install.conf` file.
      - Scripts MUST automatically sync the user's interactive choices into the actual `values.yaml` or `values-infra.yaml` files using `sed` before running `helm upgrade --install`. This ensures the `.yaml` files remain the single source of truth for manual deployments.
    - Avoid hardcoding specific Kubernetes distributions (e.g., use standard `ctr` instead of `k3s ctr`) to maintain broad compatibility.
  - **Installation Guides (`install-guide.md`)**:
    - All installation guides must instruct users to execute commands from the component root (e.g., `./scripts/install.sh`).
    - **Manual Fallback**: Guides MUST include a dedicated section for "Manual Installation & Upgrade" detailing the exact `helm upgrade --install` and `kubectl apply` commands. This serves as a fallback in case the automated `install.sh` script fails or cannot be used in a specific environment.
- Handle OS-specific package management:
  - RHEL/Rocky: `dnf localinstall` / `yum`
  - Ubuntu/Debian: `dpkg -i` / `apt install`
