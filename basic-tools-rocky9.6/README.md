# Basic Tools Offline Installer for Rocky Linux 9.6

이 디렉토리는 폐쇄망(Offline) 환경의 Rocky Linux 9.6 서버에 필수적인 기본 도구들을 설치하기 위한 스크립트를 제공합니다.

## 포함된 도구 (Tools Included)
- **Networking**: `curl`, `wget`, `net-tools` (ifconfig, netstat), `bind-utils` (dig, nslookup), `telnet`, `rsync`
- **File Management**: `zip`, `unzip`, `tar`, `lsof`
- **Utilities**: `vim`, `jq`

## 사용 방법 (Usage)

### 1. 외부망(Online) 서버에서 패키지 다운로드
인터넷이 연결된 동일한 OS(Rocky Linux 9.6) 환경에서 실행하세요.

```bash
cd basic-tools-rocky9.6
./export_basic_tools.sh
```
실행이 완료되면 `basic_tools_rocky96_YYYYMMDD.tar.gz` 파일이 생성됩니다.

### 2. 폐쇄망(Offline) 서버로 이동
생성된 `tar.gz` 파일을 폐쇄망 서버로 복사합니다.

### 3. 설치 (Install)
폐쇄망 서버에서 압축을 풀고 설치 스크립트를 실행합니다.

```bash
tar -xzvf basic_tools_rocky96_YYYYMMDD.tar.gz
# (압축 해제 시 basic_tools_bundle 폴더가 생성됨을 가정하므로, install_tools.sh도 같은 위치에 있어야 함)
# 만약 스크립트가 별도라면 같이 복사해오세요.

./install_tools.sh
```

## 참고 (Notes)
- `rpm -Uvh` 명령어를 사용하여 이미 설치된 패키지는 업데이트하거나 그대로 유지합니다.
- 의존성 문제가 발생할 경우 `rpm` 명령어에 `--nodeps`를 추가해야 할 수도 있지만, 권장하지 않습니다. `export` 스크립트가 의존성까지 같이 다운로드하도록 설정되어 있습니다.
