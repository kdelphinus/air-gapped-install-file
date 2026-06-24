#!/bin/bash

# 설정
OUTPUT_FILE="gitlab-all-images.txt"
IMAGE_DIR="images"

mkdir -p $IMAGE_DIR
rm -f $OUTPUT_FILE

echo ">>> [1/3] Helm Template 전체 렌더링 (모든 컴포넌트 포함)..."

# full-config.yaml을 사용하여 모든 기능을 켠 상태로 렌더링
helm template ./gitlab -f full-config.yaml \
  | grep 'image:' \
  | sed 's/"//g' \
  | awk '{print $2}' \
  | sort | uniq > $OUTPUT_FILE

# 리스트 생성 확인
if [ ! -s $OUTPUT_FILE ]; then
  echo "❌ 실패: 이미지 리스트 추출에 실패했습니다."
  echo "--- 에러 원인 분석을 위해 디버그 로그 출력 ---"
  helm template ./gitlab -f full-config.yaml
  exit 1
fi

echo "✅ 추출된 전체 이미지 목록:"
cat $OUTPUT_FILE
echo "----------------------------------------------------"

echo ">>> [2/3] 이미지 다운로드 및 패키징 시작..."

while read image; do
    if [[ -z "$image" ]]; then continue; fi

    echo "⬇️  Pulling: $image"
    docker pull "$image"

    if [ $? -ne 0 ]; then
        echo "⚠️  [경고] 다운로드 실패: $image (네트워크 일시적 문제일 수 있음)"
        continue
    fi

    # 파일명 변환 (/ -> _)
    filename=$(echo $image | tr '/:' '_').tar

    echo "📦 Saving to $IMAGE_DIR/$filename"
    docker save "$image" -o "$IMAGE_DIR/$filename"
done < $OUTPUT_FILE

echo ">>> [3/3] 완료! images 폴더의 용량을 확인하세요."
du -sh $IMAGE_DIR
