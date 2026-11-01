# Builds the pinned source (see pin.env) the same way the compile probe does.
# The base image is pinned by its multi-arch index digest (debian:bookworm-slim).
FROM debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG SOURCE_FILE
COPY ${SOURCE_FILE} /src/source.tar.gz
RUN mkdir /src/tree \
 && tar -xzf /src/source.tar.gz -C /src/tree --strip-components=1 \
 && make -C /src/tree -j"$(nproc)"
