# Gemini Context: Air-gapped Infrastructure Deployment

This project is a repository of installation assets, scripts, and documentation for deploying a full infrastructure stack in an **air-gapped (offline)** environment.

## 🎯 Project Goals
- Provide repeatable, offline installation processes for core devops tools.
- Target Environment: **Rocky Linux 9.6** and **Kubernetes**.
- Centralized image management using **Harbor**.

## 🏗️ Project Structure
Each top-level directory represents a component of the stack:
- `docker-offline-*`: Docker engine installation for Rocky Linux.
- `k8s-*`: Kubernetes cluster setup (RPMs, binaries, images).
- `harbor-*`: Enterprise container registry setup.
- `ingress-nginx-*`: K8s Ingress controller.
- `gitlab-*`: GitLab EE v18.7 deployment (Helm based).
- `jenkins-*`: Jenkins CI/CD deployment and plugin management.
- `mariadb-*`: Database installation.
- `envoy-*`: Envoy Gateway configuration.
- `nfs-provisioner-4.0.2`: Dynamic NFS storage provisioning for K8s.

## 🛠️ Key Conventions & Tech Stack
- **OS**: Rocky Linux 9.6 (RHEL-based).
- **Scripts**: Primarily Bash (`.sh`). Many scripts handle offline image loading (`docker load`) and pushing to local Harbor.
- **Orchestration**: Kubernetes (K8s) via Helm charts and static manifests.
- **Storage**: Mixed (HostPath, NFS, Manual PVs).
- **Offline Strategy**:
    - Download all RPMs/DEBs/Binaries beforehand.
    - Export container images to `.tar` or `.tgz` files.
    - Use local Harbor (`30002` port by default) as the image registry.

## 📖 Key Documentation
- Root folders contain specific `README.md` or `guide.md` files for each component.
- Check `harbor&ingress_install_guide.md` for the core connectivity setup.

## 🤖 AI Instructions
- Always assume **no internet access**. All tools and dependencies must be sourced from within the repository or the local network.
- When generating scripts, prefer Bash and ensure they are compatible with Rocky Linux 9.6.
- For Kubernetes resources, prioritize stability and data persistence (`Retain` policy for PVs).
- Reference existing `upload_images_to_harbor_v2.sh` scripts when dealing with container images.
