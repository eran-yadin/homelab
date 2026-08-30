# Transcribe — faster-whisper + Flask on the NUC
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    HF_HOME=/data/models \
    OMP_NUM_THREADS=${OMP_NUM_THREADS:-3}

WORKDIR /app

# PyAV (bundled ffmpeg) + ctranslate2 ship manylinux wheels, so no apt build deps
# are needed. ffmpeg is added only for robustness with odd container formats.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates ./templates

EXPOSE 8011
CMD ["python", "app.py"]
