# Peak Concurrent External-Trunk Voice Calls (Genesys Cloud) — Single-File PowerShell

This repo/script computes a **defendable “peak concurrent external-trunk voice call volume”** metric over a user-specified time interval using **Genesys Cloud Analytics Conversation Details Jobs**.

It is intentionally written as a **single script** with **no authentication implementation**. You provide the `Authorization` header (or an access token). The script focuses on:

- Jobs endpoints (create → poll → page results)
- Chunking + overlap buffer (accuracy at boundaries)
- De-dupe across overlapping chunks (avoid double counting)
- Sweep-line overlap counting (deterministic + explainable)

---

## What the script calculates

**Peak Concurrent External-Trunk Voice Legs** (within the analysis interval):

- Extracts intervals per qualifying “external trunk voice leg”
- Clips each interval to the requested analysis window
- Converts intervals to `(start,+1)` and `(end,-1)` events
- Sorts chronologically (end events before start events at the same timestamp)
- Walks the event list to find the maximum concurrency (“peak”)
- Also computes **average concurrency** by integrating concurrency over time

---

## What you must provide (auth is yours)

The script does **not** call OAuth. Provide either:

- `-Headers @{ Authorization = 'Bearer <token>' }` (recommended), or
- `-AccessToken <token>` (it will build the Authorization header)

---

## Genesys endpoints used

1) `POST /api/v2/analytics/conversations/details/jobs`
Creates an analytics job for conversation details in a given interval.

2) `GET /api/v2/analytics/conversations/details/jobs/{jobId}`
Polls job status until complete.

3) `GET /api/v2/analytics/conversations/details/jobs/{jobId}/results?pageNumber={n}&pageSize={m}`
Retrieves paged results for the completed job.

---

## Parameters you will commonly use

- `-StartUtc`, `-EndUtc`
  Analysis interval. UTC is strongly recommended.

- `-ChunkSize`, `-ChunkUnit` (`Minutes|Hours|Days`)
  Controls how the interval is divided into chunks.

- `-ChunkOverlapMinutes`
  Overlap buffer around each chunk’s query window to avoid undercounting calls that span chunk boundaries.

- `-JobRequestBodyBase`
  Your baseline POST body for creating jobs. The script overwrites only the **interval** per chunk.

- `-AllowedEdgeId`
  Optional allow-list of Edge IDs (useful if your SBC is tied to specific edges).

- `-RequireTelUri`, `-RequireNullPeerId`
  Optional stricter heuristics for identifying “external trunk legs.”

---

## The “JobRequestBodyBase” contract (important)

The script needs a valid body for the `POST .../details/jobs` endpoint.

It will **overwrite only the interval per chunk** and keep everything else unchanged.

```powershell
# Minimal valid body; you likely want to add filters (divisionIds, etc.) externally.
# We will overwrite the interval per chunk. Keep everything else as-is.
$jobBase = @{
  interval = "placeholder"  # overwritten per chunk
  order    = "asc"
  paging   = @{ pageSize = 100; pageNumber = 1 }

  # Add org-specific filters here if desired (examples vary by schema):
  # segmentFilters = @(...)
  # conversationFilters = @(...)
  # orderBy = "conversationStart"
}
