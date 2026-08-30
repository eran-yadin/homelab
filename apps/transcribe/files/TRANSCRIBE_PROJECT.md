# Transcribe — Self-Hosted Audio → Text
### NUC7i3BNHX1 | Debian | Docker | faster-whisper

Upload phone calls & meetings (mostly Hebrew + English), get searchable transcripts.
AI Q&A over the transcripts is a planned Phase 2 — the storage is already built for it.

---

## Pipeline

```
MP3 upload (web UI)
      ↓
Flask saves file → row in SQLite (status=pending) → job queue
      ↓
Worker (1 at a time) → faster-whisper (ivrit-ai turbo, int8, CPU)
      ↓
Transcript text → SQLite (+ FTS5 index)   |   segments+timestamps → /data/transcripts/<id>.json
      ↓
Browse · play-along · search · copy · JSON export
      ↓
[Phase 2] Ollama reads transcripts → answers questions
```

**Core rule (same as Paperless):** the i3 has 4 threads contested by Paperless OCR,
Ollama, and now Whisper. The worker runs **one job at a time** and is capped at 3 CPU
threads. Heavy backlogs are an overnight job.

---

## Why this model

- **`ivrit-ai/whisper-large-v3-turbo-ct2`** — the Hebrew ASR community's current
  best, already published in faster-whisper / CTranslate2 format (drop-in, no conversion).
- **turbo** = few decoder layers → actually runs on a CPU-only i3. Full `large-v3`
  would be painfully slow.
- Base is multilingual, so English mixed into Hebrew recordings still transcribes well.
- **Escape hatch:** set `WHISPER_MODEL=large-v3-turbo` for an English-dominant clip.

---

## File Locations

| What | Path |
|---|---|
| App directory | `/opt/transcribe/` |
| Flask app | `/opt/transcribe/app.py` |
| Templates | `/opt/transcribe/templates/` |
| Compose file | `/opt/transcribe/docker-compose.yml` |
| Data (volume) | `/opt/transcribe/data/` |
| → uploaded audio | `data/uploads/` |
| → transcripts (json) | `data/transcripts/` |
| → database | `data/transcribe.sqlite` |
| → model cache (~1.6GB) | `data/models/` |
| Web UI | `http://<server-ip>:8011` |

---

## Phase 1 — Deploy (do this when home)

- [ ] **Copy the folder to the NUC**
  ```bash
  # from wherever you unzip it:
  sudo mkdir -p /opt/transcribe
  sudo cp -r transcribe-app/* /opt/transcribe/
  sudo chown -R $USER:$USER /opt/transcribe
  cd /opt/transcribe
  ```

- [ ] **Build + start** (model downloads on the *first* transcription, not at build)
  ```bash
  docker compose up -d --build
  docker compose logs -f          # watch it come up; Ctrl-C to stop watching
  ```

- [ ] **Open the UI** → `http://<server-ip>:8011`

- [ ] **First transcription test** — upload a short clip. First run pulls the model
  (~1.6GB, needs internet once); subsequent runs are offline & cached.
  ```bash
  docker compose logs -f          # you'll see "Loading model..." then "Job N done"
  ```

- [ ] **Add to Homelab Hub** — append to the `SERVICES` list in
  `/opt/homelab-hub/server.py`:
  ```python
  {
      "id": "transcribe", "name": "Transcribe", "desc": "Audio → Text",
      "url": "http://<server-ip>:8011", "port": 8011,
      "type": "compose", "group": "productivity",
  },
  ```
  then `sudo systemctl restart homelab-hub`.
  > Note: `type` is `compose` (like Paperless), not `docker` — it's a compose stack.
  > The hub will need the compose dir; if its control assumes `~/paperless`, point it
  > at `/opt/transcribe` for this service.

---

## Phase 2 — AI Q&A (planned, not built)

Storage is ready: every transcript is plain text in SQLite + FTS5, plus timestamped
JSON on disk. The Q&A layer is a clean add-on:

- [ ] Add `/ask?q=...` route
- [ ] Retrieve candidate transcripts (FTS5 first; embeddings later for meaning-match)
- [ ] Feed transcript chunks + question to **Ollama** (`qwen2.5:3b` now → `llama3.1:8b`
      once the GPU node is live)
- [ ] Return answer + which recording / timestamp it came from
- [ ] Reuse the overnight-scheduling discipline — don't let Q&A and OCR collide

> This is the same Ollama handoff pattern as the Paperless classifier, so it'll feel
> familiar. Semantic embeddings (Phase 2.5) fix the Hebrew keyword-search limitation below.

---

## Usage

- **Upload:** drag MP3s onto the box (multiple at once is fine). They queue; one
  transcribes at a time.
- **View:** click a finished recording. Segments are timestamped — click a timestamp
  to jump the audio player there. "Copy text" / "Toggle raw" / "JSON" buttons up top.
- **Search:** box on the home page searches across *all* transcripts (Hebrew + English).

---

## Search behavior & the Hebrew caveat

FTS5 with prefix matching is fast and dependency-free, but it matches **surface forms**,
not meaning. Hebrew is morphologically rich (prefixes ב/ל/ה/ו/מ/ש, construct forms,
suffixes), so:

- Searching the **stem** works best: `פגיש` finds both `פגישה` and `פגישת`.
- Searching a full inflected form (`פגישה`) will **miss** other forms (`פגישת`, `לפגישה`).
- English is unaffected — `meeting` matches fine.

**Fix path:** the Phase 2 embedding layer matches by meaning and makes this moot.
For now, search by stems.

---

## Risks & Gotchas

- **CPU contention** — Whisper maxes the i3 like OCR/Ollama do. The worker is capped
  at 3 threads and runs serially, but a big batch alongside a Paperless OCR run will
  still feel slow. Drop `WHISPER_THREADS=2` if you want OCR to stay responsive, or run
  batches overnight.
- **First-run download** — needs internet once to pull the model into `data/models/`.
  After that it's fully offline. Don't delete `data/models/`.
- **Single process only** — the worker is an in-process thread. Do **not** run this under
  gunicorn with multiple workers (would load the model N times and run N transcriptions
  at once → RAM blowup). The included `app.run()` is correct; if hardening later, use
  `waitress` or gunicorn **`--workers 1`**.
- **Phone-call hallucination** — long silences can make Whisper loop/repeat. `vad_filter`
  is on to trim silence; if you still see repetition on a noisy call, try
  `WHISPER_BEAM=1` or add `condition_on_previous_text=False` in `app.py`.
- **RAM** — model resident ≈ 1.6–2 GB. Fine in 16 GB *unless* Paperless + Ollama +
  this are all loaded hot at once. Watch with `htop` if things feel tight.
- **IP** — UI binds `0.0.0.0:8011`, reachable at the NUC's LAN IP. Docs use
  `<server-ip>` placeholder per convention (actual NUC IP is the static one on `eno1`).
- **Don't expose publicly** — no auth, LAN only. Keep it off Cloudflare Tunnel, same as
  the Homelab Hub.

---

## Reference

### Ports
| Service | Port |
|---|---|
| Transcribe UI | 8011 |

### Environment variables (in `docker-compose.yml`)
| Var | Default | Notes |
|---|---|---|
| `WHISPER_MODEL` | `ivrit-ai/whisper-large-v3-turbo-ct2` | swap to `large-v3-turbo` for English-heavy |
| `WHISPER_COMPUTE` | `int8` | `int8_float32` for slightly better accuracy, more RAM |
| `WHISPER_LANGUAGE` | `auto` | `auto` / `he` / `en` |
| `WHISPER_THREADS` | `3` | of 4; drop to 2 to protect OCR |
| `WHISPER_BEAM` | `5` | lower = faster, slightly less accurate |
| `MAX_UPLOAD_MB` | `300` | upload size cap |

### Commands
```bash
cd /opt/transcribe

docker compose up -d --build      # build & start
docker compose restart            # restart after editing app.py / templates
docker compose down               # stop
docker compose logs -f            # live logs (model load, job progress)
docker compose ps                 # status

# pre-pull the model without uploading (optional warm-up)
docker compose exec transcribe python -c \
  "from faster_whisper import WhisperModel; WhisperModel('ivrit-ai/whisper-large-v3-turbo-ct2', device='cpu', compute_type='int8')"
```

### API (for Phase 2 / scripting)
| Endpoint | Returns |
|---|---|
| `GET /api/status` | queue length + status of every recording |
| `GET /api/transcript/<id>` | plain JSON: text, language, duration, status |
| `GET /audio/<id>` | the original audio file |

---

## Open Questions

- [ ] Speaker labels (diarization)? ivrit.ai lists pyannote Hebrew diarization models —
      possible add-on, but heavier on the i3. Worth it for meetings, maybe skip for calls.
- [ ] Auto-ingest folder (drop files via Syncthing/scp instead of the web UI)?
- [ ] Retention — auto-delete original audio after N days, keep only transcripts?
- [ ] Move ML to the GPU node when it's live (then `large-v3` full quality becomes viable).

---

*Transcribe — homelab project doc · phase 1 build*
