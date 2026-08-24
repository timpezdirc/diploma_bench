FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG PAPI_VERSION=7.2.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    hwloc \
    numactl \
    linux-tools-common \
    linux-tools-generic \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# za PAPI 7.2.0
RUN cd /tmp && \
    wget https://icl.utk.edu/projects/papi/downloads/papi-${PAPI_VERSION}.tar.gz && \
    echo "fc7f90ef8686d15261831fd35dfdbb1b  papi-${PAPI_VERSION}.tar.gz" | md5sum -c - && \
    tar -xzf papi-${PAPI_VERSION}.tar.gz && \
    cd papi-${PAPI_VERSION}/src && \
    ./configure --prefix=/usr/local && \
    make -j"$(nproc)" && \
    make install-all && \
    ldconfig && \
    rm -rf /tmp/papi-${PAPI_VERSION} /tmp/papi-${PAPI_VERSION}.tar.gz

ENV PATH="/usr/local/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH}"

WORKDIR /workspace