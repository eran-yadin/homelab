# The card contract

A **card** is a compact, structured summary of one item — a recording, a
document, later a photo — written once by a small local model at ingest, so a
large model can search the whole server without reading it.

That is the entire point, so it is worth stating as a budget rather than a
feeling:

> A card must stay under **~200 tokens**. Five hundred cards is then ~100k
> tokens — one context, cheap. Five hundred transcripts is millions.

A card is therefore not a summary for a human to enjoy. It is an index entry
dense enough for a model to decide *which two items to actually open*.

## The shape

Flat, predictable keys. No nesting beyond the lists, so an adapter is twenty
lines and not a parser.

```json
{
  "source":    "transcribe",
  "id":        "41",
  "url":       "http://transcribe.nuc/transcript/41",
  "title":     "פגישת צוות — יום ראשון.m4a",
  "kind":      "meeting",
  "date":      "2026-10-19",
  "lang":      "he",
  "langs":     ["he", "en"],
  "tldr":      "חלוקת משימות לשבוע, דחיית השחרור ליום רביעי, ואישור התקציב לדיסק.",
  "topics":    ["release", "budget", "storage"],
  "people":    ["Dana", "Yossi"],
  "orgs":      ["Ivory"],
  "mentioned": ["2026-10-21", "2026-11-01"],
  "actions":   ["Send the signed quote before Thursday"],
  "numbers":   ["4200 ILS"],
  "extent":    "42:18",
  "confidence": "high",
  "generated": {"model": "qwen2.5:7b", "at": "2026-10-25T18:04:11", "prompt": 1}
}
```

### Fields

| field | required | meaning |
|---|---|---|
| `source` | yes | the app that owns the item: `transcribe`, `paperless`, … |
| `id` | yes | that app's own id, as a string |
| `url` | yes | where a human opens it. The big model cites this |
| `title` | yes | the human name — filename, document title |
| `kind` | yes | app vocabulary: `call`, `meeting`, `voice-note`, `invoice`, `letter`, … |
| `date` | yes | ISO date the content is *about*, falling back to created-at |
| `lang` | yes | dominant language |
| `langs` | no | every language present, when mixed |
| `tldr` | yes | one to three sentences, **in the source language** |
| `topics` | no | ≤ 6 short tags |
| `people` | no | ≤ 8 names actually named in the content |
| `orgs` | no | ≤ 6 organisations |
| `mentioned` | no | ISO dates referred to inside the content, not its own date |
| `actions` | no | ≤ 5 commitments or next steps, each one line |
| `numbers` | no | ≤ 6 figures that carry meaning — amounts, quantities |
| `extent` | yes | the item's natural size: `42:18` for audio, `6 pages` for a document |
| `confidence` | yes | `high` / `medium` / `low` — the small model's own read |
| `generated` | yes | `{model, at, prompt}` so a model change is detectable |

## Rules

1. **A card is derived, never authoritative.** It can be thrown away and
   regenerated from the item at any time. Nothing may be edited into a card by
   hand, because the next backfill would silently discard it.

2. **The `tldr` stays in the source language.** A Hebrew call gets a Hebrew
   `tldr`. Translating costs tokens and loses fidelity, and the consumer is a
   multilingual model that does not keyword-match — it reads. This is also why
   `topics` may be English while `tldr` is Hebrew: tags are for filtering,
   prose is for reading.

3. **Empty beats invented.** An omitted `people` is a fact; a hallucinated name
   in a search index is a trap that outlives the query. A small model asked for
   structure will happily fill every field, so the prompt must license silence
   and the adapter must accept it.

4. **`generated.prompt` is a version, and it matters.** Change the prompt and
   every existing card was produced by a different instrument. Bump it, and a
   backfill can find the stale ones with one query instead of regenerating
   everything.

5. **Cards are cheap to make and cheap to lose.** Generation is a batch job that
   must yield to anything interactive — on a 2-core box, OCR and a transcription
   both outrank it. Resumable, idempotent, and interruptible at any item.

6. **One item, one card.** No cards that summarise several items; that is the
   big model's job at query time, and a merged card cannot be invalidated when
   one of its items changes.

## Where generation lives, and why it is not in the apps

The obvious design is for each app to write its own cards at ingest. It cannot
work here, for a reason that has nothing to do with taste: **we did not write
most of the sources.** paperless-ngx, immich, jellyfin and navidrome are other
people's images. There is no change to a compose file that adds a card route to
paperless. `transcribe` is the only source in this catalog we author.

paperless makes the point twice over, because on nucserver it is not even
catalog-managed: its containers were created from
`~/paperless/docker-compose.yml`, so the engine can watch them but must not
recreate them. Adopting it into the catalog later would change none of this --
which is the sign the boundary is in the right place.

So generation is **pull-based, from outside the sources**: one `cards` app in
the catalog owns the model, the prompt, the queue and the policy, and reads each
source through a small adapter. Nothing in a source changes -- no schema, no
routes, no restart, no fork of someone else's image.

```
  transcribe        paperless         immich            <- sources, unmodified
      |                 |                |
      +--------- apps/<name>/card.py ----+              <- ~20 lines each
                        |
                        v
                 cards service  --------->  ollama      <- one model, one prompt,
                  (own sqlite)                             one contention policy
                        |
          GET /api/cards | GET /api/card/<source>/<id>
                        |
                        v
                   MCP server  ---->  Claude
                        |
                        +-- drills down into the SOURCE's own item route
```

### What a source must provide

Two functions, and they may only use what the source already exposes. A source
with any read API satisfies this without being touched.

```python
# apps/transcribe/card.py
def list(since=None):
    # [{id, title, date, kind, lang, extent, url}, ...] - cheap, carries no text
    ...

def text(item_id):
    # the plain text to summarise, fetched one item at a time, never in bulk
    ...
```

transcribe answers both already: `/api/status` for the list,
`/api/transcript/<id>` for the text. paperless answers both from its own API
with a token. Neither needs a line changed.

### What the cards service owns

Everything expensive or opinionated, so it exists once instead of per app:

- **The prompt**, as one versioned file. One prompt across every source, with
  `source` and `kind` passed in as context -- that is what makes a document card
  and a call card comparable in one index.
- **The model choice** and its ollama endpoint. Changing model is one config
  edit and one backfill, not an edit per app.
- **The queue**: resumable, idempotent, one item at a time.
- **The contention policy.** Card generation is the lowest-priority work on the
  box and must yield to a transcription or an OCR run. One place to get that
  right; N places to get it wrong.
- **The cards**, in its own SQLite keyed by `(source, id)`. This is what keeps a
  source untouched, and it is why a third-party app can participate at all.

### The endpoints

| endpoint | served by | returns |
|---|---|---|
| `GET /api/cards` | cards service | every card, newest first; `?since=`, `?source=` |
| `GET /api/card/<source>/<id>` | cards service | one card |
| the item's own route | the source app | the full transcript or document |

**The card index is what gets searched; the item is what gets opened.** The big
model reads cards from one service, then drills into a source directly -- which
is why adding a source never touches the query side.

Tokens live in `/var/lib/homelab-hub/search/<app>.token`, 0600, as in
`pro - home server - HOMELAB_HUB - unified search`.

## Who implements it

- **transcribe** first, as the proving source: its two read routes already
  satisfy the adapter contract, so the first adapter really is ~20 lines.
- **paperless** second, because it is the one that proves the design. It is
  where the real volume is, it is someone else's image, and it is not even
  catalog-managed here. If the pipeline works for paperless it works for
  anything with a read API.
- Anything else joins by adding `apps/<name>/card.py`. No change to the cards
  service, the MCP server, or the query side.
