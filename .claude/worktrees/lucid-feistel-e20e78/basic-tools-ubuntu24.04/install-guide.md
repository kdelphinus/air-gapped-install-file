# Basic Tools 오프라인 설치 가이드 (Ubuntu 24.04)

Ubuntu 24.04 폐쇄망 환경에 기본 도구를 설치하는 절차를 안내합니다.

## 전제 조건

- Ubuntu 24.04 서버 (폐쇄망)
- `basic_tools_ubuntu2404_YYYYMMDD.tar.gz` 또는 `basic_tools_bundle_ubuntu/` 디렉토리가 서버에 반입되어 있을 것

## Phase 1: 외부망 서버에서 패키지 다운로드

인터넷이 연결된 동일 OS(Ubuntu 24.04) 환경에서 실행합니다.

```bash
cd basic-tools-ubuntu24.04
./export_basic_tools.sh
```

실행 완료 후 `basic_tools_ubuntu2404_YYYYMMDD.tar.gz` 파일이 생성됩니다.

## Phase 2: 폐쇄망 서버로 파일 이동

생성된 `tar.gz` 파일과 `install_tools.sh` 스크립트를 폐쇄망 서버로 복사합니다.

## Phase 3: 폐쇄망 서버에서 설치

```bash
# 1. 압축 해제
tar -xzvf basic_tools_ubuntu2404_YYYYMMDD.tar.gz

# 2. 설치 스크립트 실행
./install_tools.sh
```

또는 직접 dpkg로 설치합니다.

```bash
sudo dpkg -i basic_tools_bundle_ubuntu/*.deb
```

## Phase 4: 설치 확인

```bash
curl --version
jq --version
vim --version | head -1
ifconfig --version
```
