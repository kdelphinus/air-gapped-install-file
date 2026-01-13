# 📦 Git v2.43.0 Offline Installation Specification

본 문서는 **Rocky Linux 9.6** 폐쇄망 환경을 위한 Git 패키지 추출 및 설치 명세를 정의합니다.

## 1. 패키지 정보 (Package Detail)

* **OS**: Rocky Linux 9.6 (Blue Onyx)
* **Git Version**: **2.43.0** (Standard Stable)
* **Bundle Name**: `git_bundle_rocky96_202XMMDD.tar.gz`
* **추가 유틸리티**: `zip`, `unzip`, `tar`, `net-tools`, `curl`, `wget` 포함

## 2. 오프라인 설치 프로세스 (Offline Flow)

### 단계 1: 외부망 서버 (추출)

작성하신 스크립트를 실행하여 모든 의존성(`.rpm`)을 확보합니다.

```bash
# 스크립트 실행 후 생성된 tar.gz 파일을 USB 또는 폐쇄망 전송 솔루션으로 복사
scp git_bundle_rocky96_*.tar.gz user@air-gapped-server:/tmp/

```

### 단계 2: 폐쇄망 서버 (설치)

인터넷이 되지 않는 서버에서 아래 명령어로 로컬 설치를 진행합니다.

```bash
# 1. 압축 해제
tar -xzf git_bundle_rocky96_*.tar.gz
cd ./git_offline_bundle

# 2. 로컬 RPM 설치 (의존성 자동 해결)
# --disablerepo='*' 를 통해 외부 레포지토리 조회를 차단하고 현재 디렉토리 파일만 사용
sudo dnf localinstall -y --disablerepo='*' *.rpm

```

## 3. 설치 확인 (Verification)

설치 후 정상 동작 여부를 다음 명령어로 확인합니다.

```bash
git --version
# 예상 결과: git version 2.43.0

nmcli device  # net-tools/network-scripts 확인
curl --version

```
