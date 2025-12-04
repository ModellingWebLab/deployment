# Build the image:
# docker build -t weblab:test .

# Run the container in interactive mode:
# docker run --init -it weblab:test /bin/bash

FROM ubuntu:bionic

SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]

USER root

ENV DEFAULT_USER="celery" \
    DEFAULT_HOME="/home/celery" \
    CELERY_DIR="/opt/celery" \
    WEBLAB_FC_DIR="/opt/weblab-fc" \
    CHASTE_ROOT="/home/celery/eclipse/workspace/Chaste"

# Add celery user and create necessary directories
RUN useradd -r -m -d ${DEFAULT_HOME} -s /bin/bash ${DEFAULT_USER} && \
    mkdir -p ${CELERY_DIR} && \
    mkdir -p ${WEBLAB_FC_DIR} && \
    chown -R ${DEFAULT_USER}:${DEFAULT_USER} ${CELERY_DIR} && \
    chown -R ${DEFAULT_USER}:${DEFAULT_USER} ${WEBLAB_FC_DIR}

# Install dependencies
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
        apt-utils \
        build-essential \
        ca-certificates \
        curl \
        git \
        gnupg \
        gnupg1 \
        gnupg2 \
        openssh-server \
        python-dev \
        python-pip \
        python-virtualenv \
        python3.8-dev \
        python3-pip \
        python3.8-venv \
        python-psycopg2 \
        rabbitmq-server \
        software-properties-common \
        sudo \
        ufw \
        wget && \
    echo 'deb http://www.cs.ox.ac.uk/chaste/ubuntu bionic/' > /etc/apt/sources.list.d/chaste.list && \
    apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 422C4D99 && \
    apt-get update && \
    apt-get install -y chaste-dependencies && \
    python -m pip install --upgrade pip && \
    python3.8 -m pip install --upgrade pip && \
    /tmp/tmp-runner/bin/installdependencies.sh && \
    apt-get -y clean && \
    rm -rf /var/cache/apt && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/tmp/* && \
    rm -rf /tmp/*

# Clone repositories
USER ${DEFAULT_USER}:${DEFAULT_USER}
RUN git clone -b master --depth 1 https://github.com/ModellingWebLab/fc-runner.git ${CELERY_DIR}/repo && \
    git clone -b weblab --depth 1 https://github.com/Chaste/Chaste.git ${CHASTE_ROOT} && \
    git clone -b master --depth 1 https://github.com/ModellingWebLab/chaste-project-fitting-pints.git ${CHASTE_ROOT}/projects/AidanDaly && \
    git clone -b master --depth 1 https://github.com/ModellingWebLab/weblab-fc.git ${WEBLAB_FC_DIR}/repo

# Apply patches
COPY patches/fc/pyproject.toml ${WEBLAB_FC_DIR}/repo/

# Install WebLab
RUN python3.8 -m venv ${CELERY_DIR}/py3_venv && \
    source ${CELERY_DIR}/py3_venv/bin/activate && \
    ${CELERY_DIR}/py3_venv/bin/python3 -m pip install -U "pip>=20,<24.1" && \
    ${CELERY_DIR}/py3_venv/bin/python3 -m pip install -U "numpy>=1,<2" && \
    ${CELERY_DIR}/py3_venv/bin/python3 -m pip install -U "cython>=0,<3" && \
    ${CELERY_DIR}/py3_venv/bin/python3 -m pip install -r ${CELERY_DIR}/repo/requirements/base.txt && \
    ${CELERY_DIR}/py3_venv/bin/python3 -m pip install -r ${WEBLAB_FC_DIR}/repo/requirements/setup.txt && \
    ${CELERY_DIR}/py3_venv/bin/python3 -m pip install ${WEBLAB_FC_DIR}/repo && \
    deactivate

# Install Chaste
RUN python -m venv ${CELERY_DIR}/venv && \
    source ${CELERY_DIR}/venv/bin/activate && \
    cd ${CHASTE_ROOT} && \
    scons -j$(nproc) b=GccOpt co=1 cl=1 projects/FunctionalCuration && \
    scons -j$(nproc) b=GccOpt co=1 cl=1 exe=1 projects/FunctionalCuration/apps && \
    deactivate

# Run ansible workflows
USER root
RUN git clone -b docker --depth 1 --recursive https://github.com/ModellingWebLab/deployment.git ~/deployment && \
    python3.8 -m venv ~/deploy_env && \
    source ~/deploy_env/bin/activate && \
    python3.8 -m pip install --upgrade pip && \
    python3.8 -m pip install ansible && \
    cd ~/deployment && \
    ansible-playbook -i inventories/dev site.yml \
        -e 'django_git_branch=master' \
        -e 'django_superuser_email="my.email@domain"' \
        -e 'django_superuser_full_name="My Full Name"' \
        -e 'django_superuser_institution="My Institution"' && \
    deactivate && \
    rm -rf ~/deploy_env && \
    rm -rf ~/deployment

USER ${DEFAULT_USER}:${DEFAULT_USER}
WORKDIR ${DEFAULT_HOME}
