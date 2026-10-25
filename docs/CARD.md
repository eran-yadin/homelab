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

## How an app serves them

Two endpoints, mirroring how the hub already fans out for search:

| endpoint | returns |
|---|---|
| `GET /api/cards` | every card, newest first. `?since=<iso>` for the tail |
| `GET /api/card/<id>` | one card |

The full item stays behind the app's existing routes — `/api/transcript/<id>`
for transcribe. **The card index is what gets searched; the item is what gets
opened.** An adapter that returns transcripts in `/api/cards` has missed the
point and blown the budget.

Tokens live in `/var/lib/homelab-hub/search/<app>.token`, 0600, as in
`pro - home server - HOMELAB_HUB - unified search`.

## Who implements it

- **transcribe** first: it already stores plain text plus timestamped JSON, and
  it is ours to change.
- **paperless** second, and it is where the real volume is — 200+ documents
  against one audio library.
- Anything else joins by emitting the same ten-odd keys.
