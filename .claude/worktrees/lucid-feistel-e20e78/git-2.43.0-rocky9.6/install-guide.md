# Git v2.43.0 오프라인 설치 가이드

Rocky Linux 9.6 폐쇄망 환경에서 Git 2.43.0을 설치하는 절차를 안내합니다.

## 전제 조건

- Rocky Linux 9.6 서버 (폐쇄망)
- `git_bundle_rocky96_*.tar.gz` 파일이 서버에 반입되어 있을 것

## Phase 1: 외부망 서버에서 번들 준비

인터넷이 연결된 동일 OS(Rocky Linux 9.6) 환경에서 실행합니다.

```bash
# 스크립트 실행하여 RPM 번들 생성
./export_git_rpms.sh

# 생성된 번들 파일을 USB 또는 반입 솔루션으로 폐쇄망 서버에 복사
scp git_bundle_rocky96_*.tar.gz user@air-gapped-server:/tmp/
```

## Phase 2: 폐쇄망 서버에서 설치

```bash
# 1. 압축 해제
tar -xzf git_bundle_rocky96_*.tar.gz
cd ./git_offline_bundle

# 2. 로컬 RPM 설치 (외부 레포지토리 차단, 현재 디렉토리 파일만 사용)
sudo dnf localinstall -y --disablerepo='*' *.rpm
```

## Phase 3: 설치 확인

```bash
git --version
# 예상 결과: git version 2.43.0

curl --version
nmcli device  # net-tools 확인
```
