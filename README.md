# DIA - DICOM Image Albums

DIA is a standalone Elixir and Phoenix LiveView web application for indexing locally stored DICOM datasets (such as PACS C-MOVE retrievals), querying their textual metadata, and creating shareable albums without duplicating imaging files on disk.

## Key Capabilities

- **Fault-Isolated Local Archive Indexing:** Concurrently traverses local DICOM directories using pure-Elixir Part 10 header streaming (`:dicom`), extracting study, series, and instance metadata into an embedded SQLite database while quarantining malformed files without interrupting batch scans.
- **Built-in DIMSE Storage SCP Receiver:** Optionally listens as a pure-Elixir DICOM Storage SCP (`:dimse`), accepting `C-ECHO` verification and incoming `C-STORE` pushes (including PACS `C-MOVE` sub-operations), writing standard Part 10 files into a target archive directory, and indexing them in real time.
- **Faceted Metadata Explorer & Zero-Copy Albums:** Filters indexed cohorts by modality, body part examined, study date range, institution, archive source, or free-text metadata, and bundles selected series into reproducible virtual albums with downloadable JSON and CSV cohort manifests.
- **Mode B - Standalone Virtual DICOMweb for OHIF Viewer:** Generates capability-scoped, revocable, time-bounded share links serving album-restricted QIDO-RS and WADO-RS endpoints (metadata, multipart instances, pixel frames, CORS headers, direct OHIF launch URL, and ready-to-use OHIF v3 `ohif-config.json`), with optional PS3.15 de-identification.
- **Mode A - Kheops REST & STOW-RS Bridge:** Creates target albums on a remote Kheops server and streams album instances over DICOMweb STOW-RS with live upload progress and optional PS3.15 de-identification using consistent album-level UID remapping. Access tokens remain strictly in memory and are never persisted to SQLite.

## Requirements

- Elixir 1.17+ and Erlang/OTP
- SQLite3 (bundled via `ecto_sqlite3` / `exqlite`)

## Quick Start

```bash
mix setup
mix phx.server
```

To populate a zero-PHI synthetic multi-modal DICOM archive, sample albums, and OHIF share links:

```bash
mix dia.seed_sample
```

Configure `OHIF_VIEWER_URL` (default `http://localhost:3000`) to customize direct OHIF launch links. Open `http://localhost:4000` in a browser to register local DICOM directories, control the DIMSE Storage SCP, explore metadata, and share albums.

## DICOMweb Endpoints (Mode B)

For any active album share token `<TOKEN>`:

- `GET /dicomweb/albums/<TOKEN>/studies` (QIDO-RS studies)
- `GET /dicomweb/albums/<TOKEN>/studies/<STUDY_UID>/series` (QIDO-RS series)
- `GET /dicomweb/albums/<TOKEN>/studies/<STUDY_UID>/series/<SERIES_UID>/instances` (QIDO-RS instances)
- `GET /dicomweb/albums/<TOKEN>/studies/<STUDY_UID>/series/<SERIES_UID>/metadata` (WADO-RS DICOM JSON)
- `GET /dicomweb/albums/<TOKEN>/studies/<STUDY_UID>/series/<SERIES_UID>/instances/<SOP_UID>` (WADO-RS instance)
- `GET /dicomweb/albums/<TOKEN>/studies/<STUDY_UID>/series/<SERIES_UID>/instances/<SOP_UID>/frames/<FRAMES>` (WADO-RS frames)
- `GET /dicomweb/albums/<TOKEN>/ohif-config.json` (OHIF Viewer v3 data source configuration)

## Benchmarking & Verification

```bash
mix run priv/repo/benchmark.exs
mix precommit
```
