# Search and Answers: local models

[Documentation](../README.md) · [Русский](../models.md) · English

Settings → Search and Answers provides two independent features: Semantic Search and [Ask Buffera](chat.md). The model name and size are shown before downloading. Start with Download and Enable; once the model is downloaded, use the feature switch to enable it. Literal search, OCR, and MCP work without downloading models.

| Purpose | Model and format | File size |
| --- | --- | --- |
| Semantic Search | EmbeddingGemma 2, text component, GGUF Q8_0 | 309,855,456 bytes |
| Ask Buffera | Gemma 4 E2B IT, GGUF Q4_0 | 2,841,481,184 bytes |

These are download sizes, not promises about memory use. Both models are distributed under Apache 2.0. The catalog uses the public [EmbeddingGemma 2](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF) and [Gemma 4 E2B IT](https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF) repositories maintained by ggml-org. No Hugging Face account or token is required.

## Controls

- Download and Enable explicitly starts downloading the selected model. The feature is enabled automatically after verification. Before downloading, the switch for a disabled feature is unavailable; while preparation is in progress, you can switch it off to stop work and retain the downloaded portion.
- Pause retains the downloaded portion. Resume reuses it, including after restarting Buffera. Downloads do not resume automatically when the app starts.
- Remove Model disables the feature and frees its disk space, including any unfinished download.
- Disabling pauses the download, stops processing, and releases memory; files and the prepared index remain on disk. Pausing or a preparation error preserves the intention to enable the feature, but it cannot run until its files have been verified. Enable and Resume continues preparation; the switch for a ready feature immediately uses the downloaded model.
- The model name and size remain visible on the card. Details shows the license and Run Check, which runs short built-in examples in Russian, English, and code. Clipboard history is not passed to the model during this test. The process exits and releases memory after the test or cancellation.

Models require a Mac with Apple Silicon and macOS 14 or later. A network connection is needed to download files; verification, indexing, and semantic search run locally.

## Semantic Search

On the Semantic Search card, click Download and Enable, or enable a model that is already downloaded. The card shows the number of prepared items, errors, and Retry Processing. History is processed gradually, starting with the most recent copies. After a restart, processing continues with unfinished items.

In the history window, Include semantic search supplements text matches with semantic results when the model is enabled and vectors are available. Semantic search starts at three characters after trimming whitespace and newlines from the ends of the query; shorter queries use literal search only. Clearing the checkbox leaves only text matching. Literal matches come first, in their usual order of last use; up to 200 matching semantic results are then added. Date, application, type, favorites, and remote-device filters apply before semantic results are selected. An empty query shows normal history.

Indexing uses saved text, links, file paths, and completed image OCR. Files at those paths are not opened. Concealed items are never passed to the embedding model; concealing an item removes its vectors along with its OCR. The prepared portion of the index is available while the rest of history is being processed. If the model is disabled, deleted, or unavailable, search continues using literal matches.

Long items are split into chunks: up to 512 text tokens, an overlap of 64 tokens, and at most 32 chunks per item. Input is limited to 128 KiB of UTF-8; truncation does not split a character. Partial processing of long items is shown in progress information, and original content is unchanged. Literal search continues to use saved text and OCR up to 200,000 characters.

## Battery use

Prepare history for semantic search only on external power is enabled by default. On battery power, the indexer finishes the current item and pauses its queue; new copies continue to be saved. Literal search, search over prepared items, and questions to the assistant remain available. Image OCR operates independently of this setting.

The search card shows the pause reason, progress, and Continue Now. This button allows preparation on battery until the next connection to external power or a Buffera restart. Clearing the checkbox allows it permanently. Connecting external power automatically resumes the queue from its saved position.

macOS Low Power Mode and high thermal pressure also pause background preparation, regardless of the checkbox or temporary permission. Work resumes automatically when normal conditions return. If the power source cannot be determined, the external-power-only setting keeps the queue paused with an explanation. While the assistant is answering, the indexer yields resources to it.

Most computation happens while preparing history and generating answers. The hints on both cards explain this before the feature is enabled; no percentage battery-use claim is made without measurements.

## Implementation

`BufferaModels` does not depend on history or MCP. It manages the catalog, state, and downloads through the system `URLSession`. Files belong only to Buffera and are stored in `~/Library/Application Support/Buffera/Models`; there is no shared Hugging Face cache or extra copy of the weights.

Each catalog entry pins a repository commit, size, and SHA-256. Downloads write to `.part`; HTTP Range resumes from the actual file size. A `200` response instead of `206` restarts that file. An invalid range, size, or checksum produces an error, not a ready model. A verified file becomes ready only after writing has finished. A late response from a cancelled operation must not restore a deleted model.

For a disabled feature, full verification of its installed file is deferred until the feature is enabled or the model test is explicitly requested. A successful SHA-256 check is reused within the current process only for the same file version: file identity, size, and modification times are checked. Replacing or changing the file requires verification again; the cache does not survive an app restart.

Run Check preserves the availability and `state.json` state of an already verified, ready model: an active chat answer and semantic search continue. Repeated verification requests are coalesced. If the file disappears, changes and fails verification, or becomes inaccessible, the model moves to an error state and further starts are blocked. Disabling, deleting, or quitting the app cancels verification; a late result does not restore the cancelled state.

If `state.json` contains malformed JSON or an invalid data structure, Buffera preserves the original alongside it as `state.corrupt-<UUID>.json` and recovers state from existing model files. Ready weights and unfinished `.part` files are kept, and both features remain disabled. Downloads and full verification do not start automatically; to use an installed model, enable the feature again, after which the file goes through normal verification. Recovered state is written atomically so the next launch does not repeat recovery. Read errors, unsafe paths, failure to preserve the original file, and failure to write new state remain explicit errors and are not treated as malformed JSON.

The manager belongs to `AppDelegate`, so closing settings does not cancel a download. Unfinished operations pause when the app quits. Model errors appear on their cards and do not stop clipboard capture.

Execution uses a prebuilt [llama.cpp](https://github.com/ggml-org/llama.cpp) library with Metal. `BufferaModelProbe` is a short-lived process with fixed test tasks. It is not a network server: it receives only the model role and a local path, returns JSON, and exits. A separate process allows loading weights into memory to be cancelled and isolates engine crashes from the app.

`BufferaEmbeddingWorker` uses the same files and libraries for indexing and queries. It receives bounded JSON messages over local pipes, without a network port or text in process arguments. Vectors contain 768 numbers. Queries and documents use the different prefixes prescribed by the model; search selects the closest chunk of an item. The process reuses loaded weights and exits after 60 seconds of inactivity, when the model is disabled, or when the app quits.

The interface, indexer, and assistant search share one embedding runtime instance inside the app; MCP processes remain independent. User queries take priority over queued documents. During typing, semantic search waits for a 450 ms pause. Cancelling an outdated query removes it from the queue or discards the result of a computation that has already started, retaining the loaded model for the next query. Disabling or deleting the model, a crash, or a timeout still terminates the process.

`BufferaSearch` combines the background indexing queue with a shared search service for the UI and MCP. The queue and vectors reside in the same SQLite database, tied to the model version, checksum, and text preparation rules. Changing this combination recreates only the derived index. Deleting an item or pruning it under history limits cascades to its jobs and vectors.

Distance calculations use pinned [sqlite-vec 0.1.9](https://github.com/asg017/sqlite-vec/releases/tag/v0.1.9), statically linked into the app. Vectors are stored in ordinary tables with foreign keys; `vec_distance_cosine` allows existing filters to apply before ranking. Sources and both the MIT and Apache-2.0 licenses are in `Sources/CSQLiteVec`; its README records the archive SHA-256.

MLX Swift was considered first. At implementation time, its stable release did not yet include EmbeddingGemma 2, and compiling Metal required full Xcode. The prebuilt llama.cpp distribution made it possible to retain macOS 14 and build Buffera with Command Line Tools. Later stages should reuse the selected model files and shared search.

## Reproducible build

`scripts/prepare-model-runtime.sh` downloads the pinned official llama.cpp release, verifies SHA-256, compiles `BufferaModelProbe`, `BufferaEmbeddingWorker`, and `BufferaChatWorker`, and places the required libraries and license inside the `.app`. Model weights are not bundled and are not downloaded during the build.

Downloader checks: `swift run --disable-sandbox --cache-path .build/cache BufferaModelChecks`. They use separate temporary directories and fixture network responses. Results of real-model and interface checks are recorded in the [historical verification log (Russian)](../verification.md).
