# Docker Engine 29.1.5 오프라인 설치 가이드

폐쇄망 환경에서 Docker Engine 29.1.5를 설치하는 절차를 안내합니다.

## Phase 0: 인터넷 연결 호스트에서 에셋 다운로드

폐쇄망 환경에 반입하기 전에, 인터넷이 연결된 외부망 호스트(Rocky Linux 또는 Ubuntu)에서 아래 스크립트를 구동하여 필요한 패키지와 바이너리를 사전에 다운로드합니다.

```bash
# 1. 컴포넌트 루트 디렉토리에서 스크립트 실행
sudo ./scripts/download_assets_offline.sh
```

- Rocky Linux/RHEL 환경에서 실행할 경우 `rpm/` 폴더로 RPM 패키지가 다운로드됩니다.
- Ubuntu/Debian 환경에서 실행할 경우 `deb/` 폴더로 DEB 패키지가 다운로드됩니다.
- Static Binary 다운로드 옵션을 함께 지정하면 `static/` 폴더에 `.tgz` 파일이 저장됩니다.

다운로드가 완료되면 폴더를 압축하여 폐쇄망 내부 서버로 이관합니다.

## 전제 조건

- Rocky Linux (RHEL 계열) 또는 Ubuntu (Debian 계열) 서버 (폐쇄망)
- `rpm/`, `deb/` 또는 `static/` 디렉토리 내 설치 파일이 준비되어 있을 것

## Phase 1: RPM 패키지로 설치 (Rocky/RHEL)

가장 안정적인 방법입니다. 의존성 문제가 없다면 이 방법을 사용하세요.

```bash
# 1. rpm 파일이 있는 폴더로 이동
cd ~/docker-offline/rpm

# 2. 폴더 내 모든 rpm 일괄 설치 (의존성 포함)
sudo dnf localinstall -y --disablerepo='*' ./*.rpm

# 3. Docker 실행 및 자동 시작 등록
sudo systemctl enable --now docker

# 4. 상태 확인 (Active: running 확인)
sudo systemctl status docker
```

## Phase 2: DEB 패키지로 설치 (Ubuntu/Debian)

Ubuntu/Debian 환경에서는 `deb/` 디렉토리의 패키지를 로컬에서 설치합니다.

```bash
# 1. deb 파일이 있는 폴더로 이동
cd ~/docker-offline/deb

# 2. 폴더 내 모든 deb 일괄 설치
sudo dpkg -i ./*.deb

# 3. 의존성 오류가 남은 경우, 반입된 deb만으로 재시도
sudo apt install -y --no-index ./*.deb

# 4. Docker 실행 및 자동 시작 등록
sudo systemctl enable --now docker

# 5. 상태 확인
sudo systemctl status docker
```

## Phase 3: Static Binary로 설치 (비상용)

RPM/DEB 설치가 실패했을 때만 사용합니다.

```bash
# 1. 파일이 있는 폴더로 이동 및 압축 해제
cd ~/docker-offline/static
tar -xzvf docker-*.tgz

# 2. 실행 파일을 시스템 경로로 복사
sudo cp docker/* /usr/bin/

# 3. Docker 데몬 실행 (백그라운드)
# 주의: 정식 운영 시에는 docker.service 파일 등록이 필요합니다
sudo dockerd > /var/log/dockerd.log 2>&1 &

# 4. 버전 확인
docker --version
```

## Phase 4: 설치 확인

```bash
# Docker 버전 및 정보 확인
sudo docker info

# 이미지 로드 테스트 (tar 파일이 있는 경우)
sudo docker load -i <이미지파일>.tar
```
