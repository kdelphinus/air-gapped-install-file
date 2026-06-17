#!/bin/bash
# [외부망] 인터넷이 되는 Rocky/RHEL 환경에서 실행하세요.
# 1. NFS 관련 패키지(.rpm) 다운로드
# 2. Docker 설치 (없는 경우)
# 3. NFS Provisioner 이미지 다운로드 및 저장

set -e

TARGET_DIR="./nfs-packages"
IMAGE_FILE="nfs-provisioner.tar"
IMAGE_NAME="registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2"

mkdir -p "$TARGET_DIR"

# 패키지 매니저 확인
if command -v dnf &> /dev/null; then
    PKG_MGR="dnf"
else
    PKG_MGR="yum"
fi

echo "=== [Rocky/RHEL] 외부망 준비 작업 시작 ($PKG_MGR 사용) ==="

# ------------------------------------------------------------------
# 1. NFS 패키지 다운로드
# ------------------------------------------------------------------
echo ">> 1. NFS 패키지 다운로드 중..."
$PKG_MGR download --resolve --alldeps --destdir="$TARGET_DIR" nfs-utils
echo "   완료: $TARGET_DIR"

# ------------------------------------------------------------------
# 2. Docker 설치 (이미지 다운로드를 위해 필요)
# ------------------------------------------------------------------
echo ">> 2. Docker 확인 중..."
if ! command -v docker &> /dev/null; then
    echo "   Docker가 없습니다. 설치를 시작합니다..."
    
    # yum-utils 설치 (config-manager 사용 위해)
    if ! command -v yum-config-manager &> /dev/null; then
        sudo $PKG_MGR install -y yum-utils
    fi

    # Docker Repo 추가
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    
    # Docker 설치
    sudo $PKG_MGR install -y docker-ce docker-ce-cli containerd.io
    
    sudo systemctl start docker
    sudo systemctl enable docker
    echo "   Docker 설치 완료."
else
    echo "   Docker가 이미 설치되어 있습니다."
fi

# ------------------------------------------------------------------
# 3. 컨테이너 이미지 다운로드 및 저장
# ------------------------------------------------------------------
echo ">> 3. 컨테이너 이미지 다운로드 및 저장 ($IMAGE_NAME)"

download_with_docker() {
    DOCKER_BIN=$(command -v docker || true)
    if [ -z "$DOCKER_BIN" ]; then return 1; fi

    DOCKER_CMD="$DOCKER_BIN"
    if ! $DOCKER_CMD ps &> /dev/null; then
        DOCKER_CMD="sudo $DOCKER_BIN"
        if ! $DOCKER_CMD ps &> /dev/null; then return 1; fi
    fi

    echo "   [Docker] Pulling image..."
    $DOCKER_CMD pull "$IMAGE_NAME"
    echo "   [Docker] Saving image to $IMAGE_FILE..."
    $DOCKER_CMD save -o "$IMAGE_FILE" "$IMAGE_NAME"
    return 0
}

download_with_skopeo() {
    echo "   [Skopeo] Docker 데몬을 찾을 수 없어 Skopeo로 다운로드합니다..."
    
    if ! command -v skopeo &> /dev/null; then
        echo "   [Skopeo] 설치 중..."
        sudo $PKG_MGR install -y skopeo
    fi

    skopeo copy "docker://$IMAGE_NAME" "docker-archive:$IMAGE_FILE"
}

if ! download_with_docker; then
    echo "   Docker 사용 불가. 대체 도구(Skopeo)를 사용합니다."
    if ! download_with_skopeo; then
        echo "오류: Docker와 Skopeo 모두 실행 실패."
        exit 1
    fi
fi

echo "=== 모든 준비 완료 ==="

echo "=== 모든 준비 완료 ==="
echo "1. 패키지 폴더: $TARGET_DIR"
echo "2. 이미지 파일: $IMAGE_FILE"
echo ""
echo "위 항목들을 폐쇄망 내부로 반입하세요."