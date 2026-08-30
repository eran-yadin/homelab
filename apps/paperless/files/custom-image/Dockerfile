# Pinned, not :latest. The version matters twice over:
#
#  - a document_exporter archive does not import into an arbitrary version.
#    An export from 2.20.13 fails on 3.1.0 with "ApplicationConfiguration has
#    no field named 'skip_archive_file'", because the field was removed. To
#    migrate, restore onto the version the export came from, then upgrade.
#  - :latest means an unattended `homelab update` could jump a major version
#    under a database it then has to migrate. Not something to discover later.
ARG PAPERLESS_VERSION=2.20.13
FROM ghcr.io/paperless-ngx/paperless-ngx:${PAPERLESS_VERSION}
USER root
# Hebrew OCR is the only reason this image is built rather than pulled.
RUN apt-get update && \
    apt-get install -y --no-install-recommends tesseract-ocr-heb && \
    rm -rf /var/lib/apt/lists/*
