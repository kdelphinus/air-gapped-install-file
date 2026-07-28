#!/bin/bash

set -euo pipefail

K8S_VERSION="v1.30.14"
K8S_RPM_VERSION="1.30.14"
ROLLBACK_RPM_VERSION="1.30.11"
K8S_REPO_MINOR="v1.30"
ARCH="${ARCH:-amd64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${COMPONENT_ROOT}/patches/${K8S_VERSION}}"
RPM_DIR="${OUTPUT_DIR}/rpms"
TARGET_RPM_DIR="${RPM_DIR}/target"
ROLLBACK_RPM_DIR="${RPM_DIR}/rollback"
IMAGE_DIR="${OUTPUT_DIR}/images"
BINARY_DIR="${OUTPUT_DIR}/binaries"
METADATA_DIR="${OUTPUT_DIR}/metadata"
TEMP_REPO="/etc/yum.repos.d/kubernetes-${K8S_REPO_MINOR}-patch.repo"

log() {
  printf '[INFO] %s\n' "$*"
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -f "${TEMP_REPO}"
}

download_rpms() {
  local version="$1"
  local destination="$2"

  dnf download \
    --resolve \
    --arch=x86_64 \
    --disableexcludes=all \
    --destdir="${destination}" \
    "kubeadm-${version}" \
    "kubelet-${version}" \
    "kubectl-${version}"
}

verify_rpm_version() {
  local inventory="$1"
  local version="$2"
  local purpose="$3"
  local package

  for package in kubeadm kubelet kubectl; do
    grep -q "^${package}"$'\t'"[0-9]*:${version}-" "${inventory}" \
      || fail "${purpose} ${package} ${version} RPM을 찾지 못했습니다."
  done
}

if [[ "${EUID}" -ne 0 ]]; then
  fail "Rocky Linux 인터넷 연결 호스트에서 root 권한으로 실행하십시오."
fi

command -v dnf >/dev/null 2>&1 || fail "dnf가 필요합니다."
command -v curl >/dev/null 2>&1 || fail "curl이 필요합니다."
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum이 필요합니다."

trap cleanup EXIT

mkdir -p \
  "${TARGET_RPM_DIR}" \
  "${ROLLBACK_RPM_DIR}" \
  "${IMAGE_DIR}" \
  "${BINARY_DIR}" \
  "${METADATA_DIR}"

log "다운로드 도구 확인"
dnf install -y dnf-plugins-core createrepo_c curl tar gzip

cat > "${TEMP_REPO}" <<EOF
[kubernetes-${K8S_REPO_MINOR}-patch]
name=Kubernetes ${K8S_REPO_MINOR} patch packages
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

K8S_RPM_KEY="${METADATA_DIR}/kubernetes-rpm-signing-key.asc"
curl -fL \
  "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/repodata/repomd.xml.key" \
  -o "${K8S_RPM_KEY}"
rpm --import "${K8S_RPM_KEY}"

rm -f "${TARGET_RPM_DIR}"/*.rpm "${ROLLBACK_RPM_DIR}"/*.rpm

log "Kubernetes ${K8S_RPM_VERSION} RPM 및 의존성 다운로드"
download_rpms "${K8S_RPM_VERSION}" "${TARGET_RPM_DIR}"

log "롤백용 Kubernetes ${ROLLBACK_RPM_VERSION} RPM 및 의존성 다운로드"
download_rpms "${ROLLBACK_RPM_VERSION}" "${ROLLBACK_RPM_DIR}"

find "${RPM_DIR}" -type f -name '*.rpm' -print0 \
  | sort -z \
  | xargs -0 -r rpm -K

find "${TARGET_RPM_DIR}" -maxdepth 1 -type f -name '*.rpm' -print0 \
  | sort -z \
  | xargs -0 -r rpm -qp \
    --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
  > "${METADATA_DIR}/target-rpm-inventory.tsv"

find "${ROLLBACK_RPM_DIR}" -maxdepth 1 -type f -name '*.rpm' -print0 \
  | sort -z \
  | xargs -0 -r rpm -qp \
    --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
  > "${METADATA_DIR}/rollback-rpm-inventory.tsv"

verify_rpm_version \
  "${METADATA_DIR}/target-rpm-inventory.tsv" \
  "${K8S_RPM_VERSION}" \
  "대상"
verify_rpm_version \
  "${METADATA_DIR}/rollback-rpm-inventory.tsv" \
  "${ROLLBACK_RPM_VERSION}" \
  "롤백용"

createrepo_c "${TARGET_RPM_DIR}"
createrepo_c "${ROLLBACK_RPM_DIR}"

KUBEADM_BINARY="${BINARY_DIR}/kubeadm-${K8S_VERSION}-linux-${ARCH}"
KUBEADM_CHECKSUM="${KUBEADM_BINARY}.sha256"

log "공식 kubeadm 바이너리와 체크섬 다운로드"
curl -fL \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubeadm" \
  -o "${KUBEADM_BINARY}"
curl -fL \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubeadm.sha256" \
  -o "${KUBEADM_CHECKSUM}"

printf '%s  %s\n' \
  "$(cat "${KUBEADM_CHECKSUM}")" \
  "${KUBEADM_BINARY}" \
  | sha256sum -c -
chmod 0755 "${KUBEADM_BINARY}"

"${KUBEADM_BINARY}" config images list \
  --kubernetes-version "${K8S_VERSION}" \
  > "${METADATA_DIR}/image-list.txt"

pull_with_ctr() {
  local image="$1"
  local archive="$2"

  ctr images pull --platform "linux/${ARCH}" "${image}"
  ctr images export --platform "linux/${ARCH}" "${archive}" "${image}"
}

pull_with_docker() {
  local image="$1"
  local archive="$2"

  docker pull --platform "linux/${ARCH}" "${image}"
  docker save -o "${archive}" "${image}"
}

if command -v ctr >/dev/null 2>&1; then
  IMAGE_TOOL="ctr"
elif command -v docker >/dev/null 2>&1; then
  IMAGE_TOOL="docker"
else
  fail "이미지 반입 파일 생성에는 ctr 또는 docker가 필요합니다."
fi

log "필수 이미지 7종 다운로드 및 tar 저장"
while IFS= read -r image; do
  [[ -n "${image}" ]] || continue
  archive_name="$(printf '%s' "${image}" | sed 's|[/:]|_|g').tar"
  archive_path="${IMAGE_DIR}/${archive_name}"

  if [[ "${IMAGE_TOOL}" == "ctr" ]]; then
    pull_with_ctr "${image}" "${archive_path}"
  else
    pull_with_docker "${image}" "${archive_path}"
  fi
done < "${METADATA_DIR}/image-list.txt"

cat > "${METADATA_DIR}/bundle-info.txt" <<EOF
Kubernetes target version: ${K8S_VERSION}
Kubernetes rollback RPM version: ${ROLLBACK_RPM_VERSION}
Architecture: linux/${ARCH}
RPM repository: https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/
Image list source: kubeadm ${K8S_VERSION} config images list
Generated at: $(date --iso-8601=seconds)
EOF

find "${OUTPUT_DIR}" -type f -exec chmod 0644 {} +
chmod 0755 "${KUBEADM_BINARY}"

log "파일 체크섬 생성"
(
  cd "${OUTPUT_DIR}"
  find binaries images metadata rpms \
    -type f \
    ! -name 'sha256sums.txt' \
    -print0 \
    | sort -z \
    | xargs -0 sha256sum > sha256sums.txt
)

BUNDLE_NAME="k8s-${K8S_VERSION}-rocky9-${ARCH}-patch-bundle.tar.gz"
BUNDLE_PATH="$(dirname "${OUTPUT_DIR}")/${BUNDLE_NAME}"

log "폐쇄망 반입용 묶음 파일 생성"
tar -C "${OUTPUT_DIR}" -czf "${BUNDLE_PATH}" \
  binaries images metadata rpms sha256sums.txt

(
  cd "$(dirname "${BUNDLE_PATH}")"
  sha256sum "$(basename "${BUNDLE_PATH}")" \
    > "$(basename "${BUNDLE_PATH}").sha256"
)

log "완료: ${BUNDLE_PATH}"
log "체크섬: ${BUNDLE_PATH}.sha256"
