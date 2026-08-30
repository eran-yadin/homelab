#!/usr/bin/env python3
"""
Transcribe — self-hosted MP3 -> text for phone calls & meetings.
Single-process Flask app with one background transcription worker.
Designed for the NUC (i3-7100U): one job at a time, limited CPU threads,
so it never stacks on top of Paperless OCR / Ollama.
"""

import os
import json
import time
import queue
import sqlite3
import threading
import datetime
from pathlib import Path

from flask import (
    Flask, request, redirect, url_for, render_template,
    jsonify, abort, send_from_directory, Response
)
from werkzeug.utils import secure_filename

# ----------------------------------------------------------------------------
# Config (all overridable via env — same pattern as the Paperless classifier)
# ----------------------------------------------------------------------------
DATA_DIR        = Path(os.environ.get("DATA_DIR", "/data"))
UPLOAD_DIR      = DATA_DIR / "uploads"
TRANSCRIPT_DIR  = DATA_DIR / "transcripts"
DB_PATH         = DATA_DIR / "transcribe.sqlite"

WHISPER_MODEL    = os.environ.get("WHISPER_MODEL", "ivrit-ai/whisper-large-v3-turbo-ct2")
WHISPER_COMPUTE  = os.environ.get("WHISPER_COMPUTE", "int8")          # int8 = lean on CPU
WHISPER_THREADS  = int(os.environ.get("WHISPER_THREADS", "3"))        # leave 1 thread for the system
WHISPER_LANGUAGE = os.environ.get("WHISPER_LANGUAGE", "auto")         # auto | he | en
WHISPER_BEAM     = int(os.environ.get("WHISPER_BEAM", "5"))
PORT             = int(os.environ.get("PORT", "8011"))

ALLOWED_EXT = {".mp3", ".m4a", ".wav", ".ogg", ".opus", ".flac", ".aac", ".webm"}
MAX_MB      = int(os.environ.get("MAX_UPLOAD_MB", "300"))

UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_MB * 1024 * 1024

job_queue: "queue.Queue[int]" = queue.Queue()

# ----------------------------------------------------------------------------
# Database helpers (one connection per thread; WAL so reader+worker coexist)
# ----------------------------------------------------------------------------
_local = threading.local()


def db() -> sqlite3.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect(DB_PATH, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        _local.conn = conn
    return conn


def init_db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS recordings (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            original_name TEXT NOT NULL,
            stored_name   TEXT NOT NULL,
            status        TEXT NOT NULL DEFAULT 'pending',  -- pending|processing|done|error
            language      TEXT,
            duration      REAL,
            error         TEXT,
            created_at    TEXT NOT NULL,
            completed_at  TEXT,
            transcript    TEXT
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS search
        USING fts5(transcript, name, content='');
        """
    )
    # Any job left mid-flight by a crash/restart goes back in the queue.
    conn.execute("UPDATE recordings SET status='pending' WHERE status='processing';")
    conn.commit()
    conn.close()


def requeue_pending():
    for row in db().execute(
        "SELECT id FROM recordings WHERE status='pending' ORDER BY id ASC"
    ).fetchall():
        job_queue.put(row["id"])


def now_iso() -> str:
    return datetime.datetime.now().isoformat(timespec="seconds")


# ----------------------------------------------------------------------------
# Transcription worker — loads the model lazily on first job, stays resident.
# ----------------------------------------------------------------------------
class Worker(threading.Thread):
    daemon = True

    def __init__(self):
        super().__init__(name="transcribe-worker")
        self.model = None

    def load_model(self):
        if self.model is not None:
            return
        # Imported here so the web process starts instantly and only pulls
        # ctranslate2 + the ~1.6GB model into RAM when there's actual work.
        from faster_whisper import WhisperModel
        app.logger.info("Loading model %s (%s, %d threads)...",
                         WHISPER_MODEL, WHISPER_COMPUTE, WHISPER_THREADS)
        self.model = WhisperModel(
            WHISPER_MODEL,
            device="cpu",
            compute_type=WHISPER_COMPUTE,
            cpu_threads=WHISPER_THREADS,
        )
        app.logger.info("Model loaded.")

    def run(self):
        while True:
            rec_id = job_queue.get()
            try:
                self.process(rec_id)
            except Exception as e:  # noqa: BLE001 — never let the worker die
                app.logger.exception("Job %s failed", rec_id)
                conn = db()
                conn.execute(
                    "UPDATE recordings SET status='error', error=? WHERE id=?",
                    (str(e), rec_id),
                )
                conn.commit()
            finally:
                job_queue.task_done()

    def process(self, rec_id: int):
        conn = db()
        row = conn.execute(
            "SELECT * FROM recordings WHERE id=?", (rec_id,)
        ).fetchone()
        if row is None or row["status"] == "done":
            return

        conn.execute("UPDATE recordings SET status='processing' WHERE id=?", (rec_id,))
        conn.commit()

        self.load_model()
        audio_path = str(UPLOAD_DIR / row["stored_name"])
        lang = None if WHISPER_LANGUAGE == "auto" else WHISPER_LANGUAGE

        segments, info = self.model.transcribe(
            audio_path,
            language=lang,
            beam_size=WHISPER_BEAM,
            vad_filter=True,                 # trims silence — big help on phone calls
            vad_parameters={"min_silence_duration_ms": 500},
        )

        seg_list = []
        text_parts = []
        for seg in segments:                 # generator: this is where the work happens
            seg_list.append({
                "start": round(seg.start, 2),
                "end": round(seg.end, 2),
                "text": seg.text.strip(),
            })
            text_parts.append(seg.text.strip())

        full_text = "\n".join(text_parts).strip()

        # Persist the rich version (timestamps) to disk, plain text to the DB.
        with open(TRANSCRIPT_DIR / f"{rec_id}.json", "w", encoding="utf-8") as f:
            json.dump(
                {
                    "id": rec_id,
                    "original_name": row["original_name"],
                    "language": info.language,
                    "duration": info.duration,
                    "segments": seg_list,
                },
                f, ensure_ascii=False, indent=2,
            )

        conn.execute(
            """UPDATE recordings
                  SET status='done', language=?, duration=?,
                      transcript=?, completed_at=?, error=NULL
                WHERE id=?""",
            (info.language, info.duration, full_text, now_iso(), rec_id),
        )
        conn.execute("DELETE FROM search WHERE rowid=?", (rec_id,))
        conn.execute(
            "INSERT INTO search(rowid, transcript, name) VALUES (?,?,?)",
            (rec_id, full_text, row["original_name"]),
        )
        conn.commit()
        app.logger.info("Job %s done — %s, %.0fs of audio",
                        rec_id, info.language, info.duration or 0)


# ----------------------------------------------------------------------------
# Routes
# ----------------------------------------------------------------------------
@app.route("/")
def index():
    rows = db().execute(
        "SELECT id, original_name, status, language, duration, created_at "
        "FROM recordings ORDER BY id DESC"
    ).fetchall()
    return render_template("index.html", rows=rows, model=WHISPER_MODEL)


@app.route("/upload", methods=["POST"])
def upload():
    files = request.files.getlist("audio")
    accepted = 0
    for f in files:
        if not f or not f.filename:
            continue
        ext = Path(f.filename).suffix.lower()
        if ext not in ALLOWED_EXT:
            continue
        safe = secure_filename(f.filename) or f"recording{ext}"
        stored = f"{int(time.time()*1000)}_{safe}"
        f.save(UPLOAD_DIR / stored)
        conn = db()
        cur = conn.execute(
            "INSERT INTO recordings(original_name, stored_name, created_at) "
            "VALUES (?,?,?)",
            (f.filename, stored, now_iso()),
        )
        conn.commit()
        job_queue.put(cur.lastrowid)
        accepted += 1
    return redirect(url_for("index"))


@app.route("/transcript/<int:rec_id>")
def transcript(rec_id):
    row = db().execute("SELECT * FROM recordings WHERE id=?", (rec_id,)).fetchone()
    if row is None:
        abort(404)
    segments = []
    jpath = TRANSCRIPT_DIR / f"{rec_id}.json"
    if jpath.exists():
        with open(jpath, encoding="utf-8") as f:
            segments = json.load(f).get("segments", [])
    return render_template("transcript.html", row=row, segments=segments)


@app.route("/search")
def search():
    q = (request.args.get("q") or "").strip()
    results = []
    if q:
        # FTS5 MATCH; wrap the term so partial words still hit.
        try:
            rows = db().execute(
                """SELECT r.id, r.original_name, r.created_at,
                          snippet(search, 0, '[', ']', ' … ', 12) AS snip
                     FROM search s JOIN recordings r ON r.id = s.rowid
                    WHERE search MATCH ?
                    ORDER BY rank""",
                (q + "*",),
            ).fetchall()
            results = rows
        except sqlite3.OperationalError:
            results = []
    return render_template("search.html", q=q, results=results)


@app.route("/audio/<int:rec_id>")
def audio(rec_id):
    row = db().execute(
        "SELECT stored_name FROM recordings WHERE id=?", (rec_id,)
    ).fetchone()
    if row is None:
        abort(404)
    return send_from_directory(UPLOAD_DIR, row["stored_name"])


@app.route("/api/status")
def api_status():
    rows = db().execute(
        "SELECT id, status, language, duration FROM recordings"
    ).fetchall()
    qlen = job_queue.qsize()
    return jsonify({
        "queue": qlen,
        "items": {r["id"]: {
            "status": r["status"],
            "language": r["language"],
            "duration": r["duration"],
        } for r in rows},
    })


@app.route("/api/transcript/<int:rec_id>")
def api_transcript(rec_id):
    """Plain JSON — the future AI search/Q&A layer will read from here."""
    row = db().execute("SELECT * FROM recordings WHERE id=?", (rec_id,)).fetchone()
    if row is None:
        abort(404)
    return jsonify({
        "id": row["id"],
        "name": row["original_name"],
        "status": row["status"],
        "language": row["language"],
        "duration": row["duration"],
        "transcript": row["transcript"],
    })


# ----------------------------------------------------------------------------
# Boot
# ----------------------------------------------------------------------------
if __name__ == "__main__":
    init_db()
    requeue_pending()
    Worker().start()
    # use_reloader=False so the worker thread isn't duplicated.
    app.run(host="0.0.0.0", port=PORT, threaded=True, use_reloader=False)
