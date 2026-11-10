# Runtime base and Ubuntu package snapshot are deliberately pinned.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac AS base
# Bootstrap TLS from a pinned NVIDIA image; copy certificates only, no drivers.
COPY --from=nvidia/cuda:13.3.1-base-ubuntu26.04@sha256:30f7a2345973fbb584f4c8bc9a7c16c7bae6d0ec08883df4e030387d74756292 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN sed -i 's|^URIs:.*|URIs: https://snapshot.ubuntu.com/ubuntu/20261024T000000Z/|' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends ca-certificates libstdc++6 libgcc-s1 ocl-icd-libopencl1 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/OpenCL/vendors \
    && printf 'libnvidia-opencl.so.1\n' > /etc/OpenCL/vendors/nvidia.icd
FROM base AS probe-build
RUN apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends gcc libc6-dev
COPY cuda-probe.c /tmp/cuda-probe.c
RUN gcc -O2 -Wall -Wextra -Werror -o /tmp/cuda-probe /tmp/cuda-probe.c -ldl
FROM base AS runtime
ARG WILDRIG_VERSION
ARG WILDRIG_SHA256
LABEL io.pearlpilot.app="wildrig" org.opencontainers.image.source="https://github.com/andru-kun/wildrig-multi" \
      io.pearlpilot.version=$WILDRIG_VERSION io.pearlpilot.sha256=$WILDRIG_SHA256 io.pearlpilot.security-revision="2"
COPY --from=probe-build /tmp/cuda-probe /opt/pearlpilot/cuda-probe
COPY --chmod=0555 supervisor.sh /opt/pearlpilot/supervisor.sh
# The installer verifies the official archive, safely extracts every companion
# file, validates ELF architecture and stages only this directory into the build.
COPY --chown=0:0 distribution/ /opt/wildrig/
# Never execute distribution code during a build (including via ldd).
# Version/help checks run later without networking under the runtime sandbox.
RUN chmod -R a-w /opt/wildrig && chmod 0555 /opt/wildrig/wildrig-multi
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility HOME=/tmp
USER 65532:65532
WORKDIR /tmp
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/pearlpilot/supervisor.sh"]
