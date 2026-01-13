FROM jenkins/jenkins:2.528.3

USER root

# 1. 기본 유틸리티 설치
RUN apt-get update && \
    apt-get install -y curl unzip jq ca-certificates bash && \
    update-ca-certificates && \
    apt-get clean

# 2. 플러그인 주입 (호스트의 downloaded_plugins 폴더 복사)
COPY downloaded_plugins/ /usr/share/jenkins/ref/plugins/

# 3. OpenTofu 설치
ARG TOFU_VERSION=1.6.0
RUN curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" -o tofu.zip \
    && unzip tofu.zip \
    && mv tofu /usr/local/bin/tofu \
    && chmod +x /usr/local/bin/tofu \
    && rm tofu.zip

# 4. 툴 설치 스크립트 복사 및 실행
# (참고: 각 스크립트의 unzip 명령어에 -oq 옵션이 있어야 함)
COPY bundle-*.sh /tmp/
RUN chmod +x /tmp/bundle-*.sh && \
    sed -i 's/\r$//' /tmp/bundle-*.sh && \
    /bin/bash /tmp/bundle-aws-provider.sh && \
    /bin/bash /tmp/bundle-azure-provider.sh && \
    /bin/bash /tmp/bundle-vmware-provider.sh && \
    /bin/bash /tmp/bundle-openstack-provider.sh && \
    /bin/bash /tmp/bundle-kubectl.sh && \
    /bin/bash /tmp/bundle-helm.sh

# ---------------------------------------------------------
# [핵심 수정] OpenTofu 폐쇄망 설정 (.tofurc) - 위치 변경
# ---------------------------------------------------------
# /var/jenkins_home은 볼륨이라 파일이 사라질 수 있으므로
# 안전한 시스템 경로인 /etc/tofurc 에 생성합니다.
RUN echo 'provider_installation {' > /etc/tofurc && \
    echo '  filesystem_mirror {' >> /etc/tofurc && \
    echo '    path    = "/usr/local/share/tofu-providers"' >> /etc/tofurc && \
    echo '    include = ["registry.opentofu.org/*/*"]' >> /etc/tofurc && \
    echo '  }' >> /etc/tofurc && \
    echo '}' >> /etc/tofurc

# 5. 환경 변수 및 권한 설정
# Tofu가 실행될 때 /etc/tofurc를 바라보도록 설정
ENV TF_CLI_CONFIG_FILE="/etc/tofurc"
ENV TOFU_PLUGIN_CACHE_DIR="/usr/local/share/tofu-providers"

# 설정 파일 권한 부여 (jenkins 유저가 읽을 수 있도록)
RUN chmod 644 /etc/tofurc

# 폴더 소유권 변경
RUN chown -R jenkins:jenkins /usr/share/jenkins/ref \
    && chown -R jenkins:jenkins /usr/local/share/tofu-providers

USER jenkins
