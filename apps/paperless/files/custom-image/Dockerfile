FROM ghcr.io/paperless-ngx/paperless-ngx:latest
USER root
# Hebrew OCR is the only reason this image is built rather than pulled.
RUN apt-get update && \
    apt-get install -y --no-install-recommends tesseract-ocr-heb && \
    rm -rf /var/lib/apt/lists/*
