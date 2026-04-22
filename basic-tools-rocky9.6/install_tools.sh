#!/bin/bash

# 패키지 디렉토리 (export 스크립트에서 생성된 디렉토리 이름과 일치해야 함)
RPM_DIR="./basic_tools_bundle"

if [ ! -d "$RPM_DIR" ]; then
    echo "❌ 오류: $RPM_DIR 디렉토리를 찾을 수 없습니다."
    echo "   압축을 푼 디렉토리 안에서 실행하고 있는지 확인하세요."
    exit 1
fi

echo "📦 기본 도구 설치를 시작합니다..."

# 설치
# --replacepkgs: 이미 설치되어 있어도 다시 설치 (손상 복구 등)
# --no-best: 최적의 버전이 아니어도 설치 (의존성 문제 완화)
sudo rpm -Uvh --replacepkgs --no-best $RPM_DIR/*.rpm

if [ $? -eq 0 ]; then
    echo "------------------------------------------------"
    echo "✅ 설치가 완료되었습니다."
    echo "   설치된 도구 확인:"
    echo "   - curl: $(rpm -q curl)"
    echo "   - wget: $(rpm -q wget)"
    echo "   - vim:  $(rpm -q vim-enhanced)"
    echo "------------------------------------------------"
else
    echo "❌ 설치 중 오류가 발생했습니다."
fi
