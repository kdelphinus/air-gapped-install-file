#!/bin/bash
# ================================================================
# 🐧 [Ubuntu/K8s] 이미지 일괄 Pull & Export(Tar) 스크립트
# ================================================================

# [설정 1] Harbor 주소
REGISTRY_DOMAIN="harbor-product.strato.co.kr:8443"
PROJECT_NAME="goe"

REGISTRY_URL="${REGISTRY_DOMAIN}/${PROJECT_NAME}"


# [설정 2] Harbor 계정
CREDENTIALS="id:password"

# [설정 3] 쿠버네티스 네임스페이스
NAMESPACE="k8s.io"

# [설정 4] 아키텍처 고정
PLATFORM="linux/amd64"

# [설정 5] TLS 검증 여부 (사설 인증서 환경)
USE_TLS=true
SKIP_VERIFY=false  # 인증서 검증 무시

# [설정 6] 입력 파일 및 저장 경로
INPUT_FILE="image_list.conf"  # (.conf 확장자 권장)
OUTPUT_DIR="saved_tars"

# ================================================================

# 0. 초기화
mkdir -p "$OUTPUT_DIR"
FAILED_IMAGES=()
SUCCESS_COUNT=0

echo "========================================================"
echo "❓ 초기화 확인"
echo "   대상 네임스페이스: [$NAMESPACE]"
read -p "   작업 시작 전, 로컬($NAMESPACE)에 있는 이미지를 모두 삭제하시겠습니까? (y/n): " CLEANUP_YN

if [[ "$CLEANUP_YN" =~ ^[Yy]$ ]]; then
    echo ""
    echo "🧹 기존 이미지 일괄 삭제 중..."
    # 이미지가 하나도 없을 때 에러가 나지 않도록 xargs에 -r 옵션 사용
    sudo ctr -n "$NAMESPACE" images ls -q | xargs -r sudo ctr -n "$NAMESPACE" images rm
    echo "✨ 삭제 완료! 깨끗한 상태에서 시작합니다."
else
    echo ""
    echo "➡️  기존 이미지를 유지한 채로 작업을 시작합니다."
fi

# 입력 파일 존재 확인
if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ [Error] '$INPUT_FILE' 파일이 없습니다."
    echo "   먼저 이미지 목록 파일을 생성해주세요."
    exit 1
fi

# TLS 옵션 설정
CTR_OPTS=""
if [ "$USE_TLS" = false ]; then
    CTR_OPTS="--plain-http"
elif [ "$SKIP_VERIFY" = true ]; then
    CTR_OPTS="--skip-verify"
fi

echo "========================================================"
echo "🚀 이미지 다운로드 및 Tar 백업을 시작합니다."
echo "📂 저장 경로: ./$OUTPUT_DIR"
echo "📄 목록 파일: $INPUT_FILE"
echo "========================================================"
echo ""

# 1. 파일 읽기 및 반복 작업
while IFS= read -r LINE || [ -n "$LINE" ]; do
    
    # 1-1. 공백 제거 (Trim)
    IMAGE_PATH=$(echo "$LINE" | xargs)

    # 1-2. 주석(#)이거나 빈 줄이면 건너뛰기
    # (앞에 공백이 있어도 #으로 시작하면 주석으로 처리함)
    if [[ "$IMAGE_PATH" =~ ^# ]] || [[ -z "$IMAGE_PATH" ]]; then
        continue
    fi

    FULL_IMAGE="${REGISTRY_URL}/${IMAGE_PATH}"
    
    # 파일명을 위해 슬래시(/)와 콜론(:)을 언더바(_)로 변경
    SAFE_NAME=$(echo "$IMAGE_PATH" | tr '/:' '__')
    TAR_FILE="${OUTPUT_DIR}/${SAFE_NAME}.tar"

    echo "--------------------------------------------------------"
    echo "🎯 Target: ${IMAGE_PATH}"

    # 1-3. 이미지 Pull (다운로드)
    echo "⬇️  [1/2] Pulling..."
    sudo ctr -n "$NAMESPACE" images pull \
        $CTR_OPTS \
        --user "$CREDENTIALS" \
        --all-platforms \
        "$FULL_IMAGE" > /dev/null

    if [ $? -eq 0 ]; then
        echo "✅ Pull 성공"

        # 1-4. 이미지 Export (Tar 저장)
        echo "📦 [2/2] Exporting to .tar..."
        sudo ctr -n "$NAMESPACE" images export \
            --platform "$PLATFORM" \
            "$TAR_FILE" \
            "$FULL_IMAGE"

        if [ $? -eq 0 ]; then
            echo "✅ Export 성공: $TAR_FILE"
            ((SUCCESS_COUNT++))
        else
            echo "❌ Export 실패"
            FAILED_IMAGES+=("$IMAGE_PATH (Export 실패)")
        fi
    else
        echo "❌ Pull 실패 (이미지명 또는 권한 확인 필요)"
        FAILED_IMAGES+=("$IMAGE_PATH (Pull 실패)")
    fi
    echo "--------------------------------------------------------"

done < "$INPUT_FILE"

# 2. 최종 리포트
echo ""
echo "========================================================"
echo "📊 작업 완료 리포트"
echo "========================================================"
echo "✅ 성공: ${SUCCESS_COUNT}개"

if [ ${#FAILED_IMAGES[@]} -gt 0 ]; then
    echo "⚠️  실패: ${#FAILED_IMAGES[@]}개"
    echo ""
    echo "❌ [실패한 이미지 목록]"
    for FAILED in "${FAILED_IMAGES[@]}"; do
        echo " - ${FAILED}"
    done
    exit 1
else
    echo "🎉 모든 이미지가 정상적으로 저장되었습니다!"
    echo "📂 확인: ls -lh $OUTPUT_DIR"
fi
