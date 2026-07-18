# syntax=docker/dockerfile:1.12
FROM rust:1.97.0-bookworm@sha256:7d0723df719e7f213b69dc7c8c595985c3f4b060cfbee4f7bc0e347a86fe3b6a AS build
WORKDIR /workspace
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates crates
COPY services services
COPY xtask xtask
COPY db db
COPY specs specs
COPY vendor vendor
RUN --mount=type=cache,id=gurine-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=gurine-cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=gurine-cargo-target,target=/cargo-target \
    CARGO_TARGET_DIR=/cargo-target cargo build --locked --release --workspace --bins \
    && mkdir -p /workspace/target \
    && cp -a /cargo-target/release /workspace/target/

FROM debian:bookworm@sha256:30482e873082e906a4908c10529180aefb6f77620aea7404b909829fadc5d168 AS parser-tools-build
ARG POPPLER_VERSION=25.06.0
ARG POPPLER_SHA256=8199532d38984fab46dbd0020ec9c40f20e928e33e9b4cc6043572603a821d83
ARG TESSERACT_VERSION=5.5.0
ARG TESSERACT_SHA256=f2fb34ca035b6d087a42875a35a7a5c4155fa9979c6132365b1e5a28ebc3fc11
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
       ca-certificates cmake curl g++ ninja-build pkg-config xz-utils \
       libfontconfig1-dev libfreetype-dev libjpeg62-turbo-dev liblcms2-dev \
       libleptonica-dev libopenjp2-7-dev libpng-dev libtiff-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl --fail --location --silent --show-error \
      "https://poppler.freedesktop.org/poppler-${POPPLER_VERSION}.tar.xz" -o poppler.tar.xz \
    && echo "${POPPLER_SHA256}  poppler.tar.xz" | sha256sum --check \
    && tar --extract --xz --file poppler.tar.xz \
    && cmake -S "poppler-${POPPLER_VERSION}" -B poppler-build -G Ninja \
       -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/parser -DCMAKE_INSTALL_LIBDIR=lib \
       -DBUILD_GTK_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF \
       -DBUILD_CPP_TESTS=OFF -DENABLE_QT5=OFF -DENABLE_QT6=OFF \
       -DENABLE_GLIB=OFF -DENABLE_CPP=OFF -DENABLE_LIBCURL=OFF \
       -DENABLE_NSS3=OFF -DENABLE_GPGME=OFF -DENABLE_BOOST=OFF \
    && cmake --build poppler-build --parallel \
    && cmake --install poppler-build \
    && curl --fail --location --silent --show-error \
      "https://github.com/tesseract-ocr/tesseract/archive/refs/tags/${TESSERACT_VERSION}.tar.gz" -o tesseract.tar.gz \
    && echo "${TESSERACT_SHA256}  tesseract.tar.gz" | sha256sum --check \
    && tar --extract --gzip --file tesseract.tar.gz \
    && cmake -S "tesseract-${TESSERACT_VERSION}" -B tesseract-build -G Ninja \
       -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/parser -DCMAKE_INSTALL_LIBDIR=lib \
       -DBUILD_TRAINING_TOOLS=OFF -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON \
    && cmake --build tesseract-build --parallel \
    && cmake --install tesseract-build

FROM debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df AS runtime
RUN groupadd --system --gid 10001 gurine \
    && useradd --system --uid 10001 --gid gurine --home-dir /nonexistent --shell /usr/sbin/nologin gurine \
    && install -d -o 10001 -g 10001 /var/lib/gurine-objects /var/lib/gurine-mail \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
USER 10001:10001
WORKDIR /app

FROM runtime AS public-api
COPY --from=build /workspace/target/release/gurine-public-api /app/gurine-public-api
ENTRYPOINT ["/app/gurine-public-api"]

FROM runtime AS control-api
COPY --from=build /workspace/target/release/gurine-control-api /app/gurine-control-api
ENTRYPOINT ["/app/gurine-control-api"]

FROM runtime AS identity-api
COPY --from=build /workspace/target/release/gurine-identity-api /app/gurine-identity-api
ENTRYPOINT ["/app/gurine-identity-api"]

FROM runtime AS submission-api
COPY --from=build /workspace/target/release/gurine-submission-api /app/gurine-submission-api
ENTRYPOINT ["/app/gurine-submission-api"]

FROM runtime AS ingest-worker
COPY --from=build /workspace/target/release/gurine-ingest-worker /app/gurine-ingest-worker
ENTRYPOINT ["/app/gurine-ingest-worker"]

FROM runtime AS analysis-worker
COPY --from=build /workspace/target/release/gurine-analysis-worker /app/gurine-analysis-worker
ENTRYPOINT ["/app/gurine-analysis-worker"]

FROM runtime AS projection-worker
COPY --from=build /workspace/target/release/gurine-projection-worker /app/gurine-projection-worker
ENTRYPOINT ["/app/gurine-projection-worker"]

FROM runtime AS notification-worker
COPY --from=build /workspace/target/release/gurine-notification-worker /app/gurine-notification-worker
ENTRYPOINT ["/app/gurine-notification-worker"]

FROM runtime AS workflow-worker
COPY --from=build /workspace/target/release/gurine-workflow-worker /app/gurine-workflow-worker
ENTRYPOINT ["/app/gurine-workflow-worker"]

FROM runtime AS scheduler
COPY --from=build /workspace/target/release/gurine-scheduler /app/gurine-scheduler
ENTRYPOINT ["/app/gurine-scheduler"]

FROM runtime AS migrator
COPY --from=build /workspace/target/release/gurine-migrator /app/gurine-migrator
ENTRYPOINT ["/app/gurine-migrator"]

FROM runtime AS egress-gateway
COPY --from=build /workspace/target/release/gurine-egress-gateway /app/gurine-egress-gateway
ENTRYPOINT ["/app/gurine-egress-gateway"]

FROM runtime AS oidc-test-provider
COPY --from=build /workspace/target/release/gurine-oidc-test-provider /app/gurine-oidc-test-provider
ENTRYPOINT ["/app/gurine-oidc-test-provider"]

FROM runtime AS document-extractor
USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
       libfontconfig1 libfreetype6 libjpeg62-turbo liblcms2-2 liblept5 \
       libopenjp2-7 libpng16-16 libtiff6 tesseract-ocr-eng=1:4.1.0-2 tesseract-ocr-kor=1:4.1.0-2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=parser-tools-build /opt/parser /opt/parser
RUN cp /usr/share/tesseract-ocr/5/tessdata/eng.traineddata /opt/parser/share/tessdata/ \
    && cp /usr/share/tesseract-ocr/5/tessdata/kor.traineddata /opt/parser/share/tessdata/
COPY --from=build /workspace/target/release/gurine-document-extractor /app/gurine-document-extractor
ENV PATH="/opt/parser/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/parser/lib" \
    TESSDATA_PREFIX="/opt/parser/share/tessdata"
USER 10001:10001
ENTRYPOINT ["/app/gurine-document-extractor"]

FROM rust:1.97.0-bookworm@sha256:7d0723df719e7f213b69dc7c8c595985c3f4b060cfbee4f7bc0e347a86fe3b6a AS document-extractor-test
WORKDIR /workspace
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates crates
COPY services services
COPY xtask xtask
COPY specs specs
COPY db db
COPY vendor vendor
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
       libfontconfig1 libfreetype6 libjpeg62-turbo liblcms2-2 liblept5 \
       libopenjp2-7 libpng16-16 libtiff6 tesseract-ocr-eng=1:4.1.0-2 tesseract-ocr-kor=1:4.1.0-2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=parser-tools-build /opt/parser /opt/parser
ENV PATH="/opt/parser/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/parser/lib" \
    TESSDATA_PREFIX="/opt/parser/share/tessdata"
RUN cp /usr/share/tesseract-ocr/5/tessdata/eng.traineddata /opt/parser/share/tessdata/ \
    && cp /usr/share/tesseract-ocr/5/tessdata/kor.traineddata /opt/parser/share/tessdata/ \
    && pdftotext -v 2>&1 | grep --fixed-strings 'pdftotext version 25.06.0' \
    && pdftoppm -v 2>&1 | grep --fixed-strings 'pdftoppm version 25.06.0' \
    && tesseract --version | head -1 | grep --fixed-strings 'tesseract 5.5.0' \
    && echo '7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2  /opt/parser/share/tessdata/eng.traineddata' | sha256sum --check \
    && echo '6b85e11d9bbf07863b97b3523b1b112844c43e713df8b66418a081fd1060b3b2  /opt/parser/share/tessdata/kor.traineddata' | sha256sum --check
RUN cargo test --locked -p gurine-document-extractor --lib --no-run
RUN cargo test --locked -p gurine-document-extractor --lib

FROM document-extractor-test AS rust-workspace-test
COPY verification verification
RUN rustup component add rustfmt clippy
ARG CARGO_NEXTEST_VERSION=0.9.140
RUN --mount=type=cache,id=gurine-nextest-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=gurine-nextest-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=gurine-nextest-target,target=/tmp/cargo-nextest-target \
    CARGO_TARGET_DIR=/tmp/cargo-nextest-target \
    cargo install cargo-nextest --version "${CARGO_NEXTEST_VERSION}" --locked \
    && cargo nextest --version | grep --fixed-strings "cargo-nextest ${CARGO_NEXTEST_VERSION}"
RUN cargo fmt --all -- --check
RUN cargo clippy --locked --workspace --all-targets -- -D warnings
RUN cargo test --locked --workspace --all-targets --no-run
RUN cargo test --locked --workspace --all-targets

FROM rust-workspace-test AS sqlx-prepare-test
RUN cargo install sqlx-cli --version 0.9.0 --locked --no-default-features --features rustls,postgres
ARG SQLX_PREPARE_NONCE
RUN --mount=type=secret,id=database_url,required=true \
    test -n "$SQLX_PREPARE_NONCE" \
    && DATABASE_URL="$(cat /run/secrets/database_url)" cargo sqlx prepare --workspace --check

FROM python:3.13.5-slim-bookworm@sha256:4c2cf9917bd1cbacc5e9b07320025bdb7cdf2df7b0ceaccb55e9dd7e30987419 AS authority-validator
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
       libfontconfig1 libfreetype6 libjpeg62-turbo liblcms2-2 liblept5 \
       libopenjp2-7 libpng16-16 libtiff6 tesseract-ocr-eng=1:4.1.0-2 \
       tesseract-ocr-kor=1:4.1.0-2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=parser-tools-build /opt/parser /opt/parser
RUN cp /usr/share/tesseract-ocr/5/tessdata/eng.traineddata /opt/parser/share/tessdata/ \
    && cp /usr/share/tesseract-ocr/5/tessdata/kor.traineddata /opt/parser/share/tessdata/
COPY requirements-spec.txt /tmp/requirements-spec.txt
RUN python -m pip install --no-cache-dir --require-hashes -r /tmp/requirements-spec.txt
ENV PATH="/opt/parser/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/parser/lib" \
    TESSDATA_PREFIX="/opt/parser/share/tessdata" \
    PYTHONDONTWRITEBYTECODE=1
RUN python --version | grep --fixed-strings 'Python 3.13.5' \
    && pdftotext -v 2>&1 | grep --fixed-strings 'pdftotext version 25.06.0' \
    && pdftoppm -v 2>&1 | grep --fixed-strings 'pdftoppm version 25.06.0' \
    && tesseract --version | head -1 | grep --fixed-strings 'tesseract 5.5.0'
WORKDIR /workspace
