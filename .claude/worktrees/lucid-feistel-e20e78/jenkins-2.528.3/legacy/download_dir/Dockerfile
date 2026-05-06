FROM jenkins/jenkins:2.528.3
USER root
# 다운받은 호환 플러그인들을 이미지 안으로 복사
COPY downloaded_plugins/ /usr/share/jenkins/ref/plugins/
USER jenkins