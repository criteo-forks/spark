# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

FROM filer-docker-registry.crto.in/criteo-centos-base:0.1.0-3325-gadc8d652

ARG USER_NAME
ARG USER_ID
ARG GROUP_ID

WORKDIR /root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Without the following plugin yum fails to install packages with
# Rpmdb checksum is invalid: dCDPT(pkg checksums)....
RUN yum -y install yum-plugin-ovl
RUN yum groupinstall -y 'Development Tools'
RUN yum install -y \
        ant \
        bats \
        bzip2 \
        clang \
        cmake3 \
        curl \
        doxygen \
        fuse \
        gcc-c++ \
        gcc \
        git \
        bouncycastle \
        bzip2-devel \
        libcurl-devel \
        fuse-devel \
        protobuf-devel \
        cyrus-sasl-devel \
        snappy-devel \
        openssl-devel \
        libtool \
        libzstd-devel \
        make \
        maven \
        nodejs \
        npm \
        java-1.8.0-openjdk \
        pinentry-curses \
        pkgconfig \
        python3-pip \
        python3-virtualenv \
        rsync \
        ShellCheck \
        sudo \
        valgrind \
        wget \
        zlib-devel

# we need maven 3.8.8
RUN rm -rf /usr/share/maven  \
    && wget --no-check-certificate https://downloads.apache.org/maven/maven-3/3.8.8/binaries/apache-maven-3.8.8-bin.tar.gz  \
    && tar xf apache-maven-3.8.8-bin.tar.gz -C /usr/share  \
    && ln -s /usr/share/apache-maven-3.8.8 /usr/share/maven

######
# Set env vars required to build Hadoop
######
ENV MAVEN_HOME /usr
# JAVA_HOME must be set in Maven >= 3.5.0 (MNG-6003)
ENV JAVA_HOME /etc/alternatives/java_sdk

###
# Avoid out of memory errors in builds
###
ENV MAVEN_OPTS -Xss64m -Xmx2g -XX:ReservedCodeCacheSize=1g


RUN groupadd --non-unique -g ${GROUP_ID} ${USER_NAME}
RUN useradd -l -g ${GROUP_ID} -u ${USER_ID} -k /root -m ${USER_NAME}
RUN echo "${USER_NAME} ALL=NOPASSWD: ALL" > "/etc/sudoers.d/spark-build-${USER_ID}"
ENV HOME /home/${USER_NAME}
RUN mkdir /home/${USER_NAME}/.m2 && chown ${USER_NAME}: /home/${USER_NAME}/.m2
RUN echo '<settings><mirrors><mirror><id>criteo</id><mirrorOf>*</mirrorOf><url>http://nexus.criteo.prod/content/groups/criteodev</url></mirror></mirrors><servers><server><id>criteo</id><username>${criteo.repo.username}</username><password>${criteo.repo.password}</password></server></servers></settings>' > /home/${USER_NAME}/.m2/settings.xml

# Alias python3 to python otherwise python 2 is called
RUN mv /usr/bin/python /usr/bin/python2
RUN ln -s /usr/bin/python3 /usr/bin/python

RUN rm -f /var/log/faillog /var/log/lastlog