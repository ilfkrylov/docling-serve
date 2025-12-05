ARG BASE_IMAGE=quay.io/sclorg/python-312-c9s:c9s

ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.8.19

ARG UV_SYNC_EXTRA_ARGS=""

FROM ${BASE_IMAGE} AS docling-base

###################################################################################################
# OS Layer                                                                                        #
###################################################################################################

USER 0

# Message for readers about below changes: official docling-serve 1.9.0 use old tesseract and it works badly on multilanguage documents. This changes needed for update tesseract and dependency packages.

# Установка базовых утилит и зависимостей
RUN --mount=type=bind,source=os-packages.txt,target=/tmp/os-packages.txt \
    dnf -y install --best --nodocs --setopt=install_weak_deps=False dnf-plugins-core && \
    dnf config-manager --best --nodocs --setopt=install_weak_deps=False --save && \
    dnf config-manager --enable crb && \
    dnf -y update && \
    # Удаляем пакеты tesseract, если они уже установлены в базовом образе
    (dnf remove -y --nodocs 'tesseract*' 2>/dev/null || true) && \
    # Установим все пакеты из os-packages.txt, кроме тех, которые начинаются с 'tesseract'
    # curl не устанавливаем, чтобы избежать конфликта с curl-minimal, который уже есть в образе
    dnf install -y $(grep -v '^tesseract' /tmp/os-packages.txt) \
        # Дополнительные зависимости для сборки tesseract
        autoconf \
        automake \
        libtool \
        pkgconfig \
        gcc \
        gcc-c++ \
        make \
        cmake \
        git \
        wget \
        which \
        libarchive \
        zlib-devel \
        libjpeg-turbo-devel \
        libpng-devel \
        libtiff-devel \
        libwebp-devel \
        && \
    dnf -y clean all && \
    rm -rf /var/cache/dnf

# Удаление leptonica чтобы потом установить правильную версию, совместимую с tesseract
RUN dnf remove -y leptonica leptonica-devel || true
RUN dnf -y install \
    autoconf automake libtool pkgconfig \
    gcc gcc-c++ make \
    libjpeg-turbo-devel libpng-devel libtiff-devel zlib-devel libwebp-devel \
    git wget which \
    && dnf clean all

# Сборка и установка tesseract и leptonica из исходников
WORKDIR /tmp

RUN wget -q https://github.com/DanBloomberg/leptonica/releases/download/1.85.0/leptonica-1.85.0.tar.gz && \
    tar -xzf leptonica-1.85.0.tar.gz && \
    cd leptonica-1.85.0 && \
    ./autogen.sh && \
    ./configure --prefix=/usr && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig && \
    cd /tmp && rm -rf leptonica-1.85.0*

RUN wget -q https://github.com/tesseract-ocr/tesseract/archive/refs/tags/5.5.0.tar.gz && \
    tar -xzf 5.5.0.tar.gz && \
    cd tesseract-5.5.0 && \
    ./autogen.sh && \
    ./configure --prefix=/usr --disable-openmp && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig && \
    cd /tmp && rm -rf tesseract-5.5.0 5.5.0.tar.gz

# Установка языковых данных для tesseract (можно поиграться с best и fast, но я выбрал те, которые были на эталонном ПК)
RUN mkdir -p /usr/share/tessdata && \
    cd /usr/share/tessdata && \
    wget -q https://github.com/tesseract-ocr/tessdata_best/raw/main/eng.traineddata && \
    wget -q https://github.com/tesseract-ocr/tessdata_fast/raw/main/rus.traineddata && \
    wget -q https://github.com/tesseract-ocr/tessdata_best/raw/main/osd.traineddata

RUN /usr/bin/fix-permissions /opt/app-root/src/.cache

ENV TESSDATA_PREFIX=/usr/share/tessdata/

FROM ${UV_IMAGE} AS uv_stage

###################################################################################################
# Docling layer                                                                                   #
###################################################################################################

FROM docling-base

USER 1001

WORKDIR /opt/app-root/src

ENV \
    OMP_NUM_THREADS=4 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PYTHONIOENCODING=utf-8 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/app-root \
    DOCLING_SERVE_ARTIFACTS_PATH=/opt/app-root/src/.cache/docling/models

ARG UV_SYNC_EXTRA_ARGS

RUN --mount=from=uv_stage,source=/uv,target=/bin/uv \
    --mount=type=cache,target=/opt/app-root/src/.cache/uv,uid=1001 \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    umask 002 && \
    UV_SYNC_ARGS="--frozen --no-install-project --no-dev --all-extras" && \
    uv sync ${UV_SYNC_ARGS} ${UV_SYNC_EXTRA_ARGS} --no-extra flash-attn && \
    FLASH_ATTENTION_SKIP_CUDA_BUILD=TRUE uv sync ${UV_SYNC_ARGS} ${UV_SYNC_EXTRA_ARGS} --no-build-isolation-package=flash-attn

ARG MODELS_LIST="layout tableformer picture_classifier rapidocr easyocr"

RUN echo "Downloading models..." && \
    HF_HUB_DOWNLOAD_TIMEOUT="90" \
    HF_HUB_ETAG_TIMEOUT="90" \
    docling-tools models download -o "${DOCLING_SERVE_ARTIFACTS_PATH}" ${MODELS_LIST} && \
    chown -R 1001:0 ${DOCLING_SERVE_ARTIFACTS_PATH} && \
    chmod -R g=u ${DOCLING_SERVE_ARTIFACTS_PATH}

COPY --chown=1001:0 ./docling_serve ./docling_serve

RUN --mount=from=uv_stage,source=/uv,target=/bin/uv \
    --mount=type=cache,target=/opt/app-root/src/.cache/uv,uid=1001 \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    umask 002 && uv sync --frozen --no-dev --all-extras ${UV_SYNC_EXTRA_ARGS}

EXPOSE 5001

CMD ["docling-serve", "run"]
