# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.205.2/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use hirsuite or bionic on local arm64/Apple Silicon): hirsute, focal, bionic
ARG VARIANT="focal"
FROM ptebic.azurecr.io/public/aifx/stable-nccl-ubuntu2004-cu111-py36-torch1100:latest

# [Optional] Uncomment this section to install additional OS packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#     && apt-get -y install --no-install-recommends <your-package-list-here>

RUN rm -f /usr/lib/x86_64-linux-gnu/libcuda*
RUN rm -f /usr/lib/x86_64-linux-gnu/libnvidia*
