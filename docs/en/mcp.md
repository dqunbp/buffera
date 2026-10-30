# MCP over stdio

[Documentation](../README.md) · [Русский](../mcp.md) · English

Buffera provides an external agent with search and read access to saved history through a separate executable, `BufferaMCP`. The agent launches this executable as a child process and exchanges messages over stdin/stdout. No network address, open port, or built-in LLM is required. Literal search works without models; an enabled EmbeddingGemma 2 model adds semantic search.

## Connection

First, launch the current Buffera: it creates or upgrades local history. In Settings → MCP, enable Allow agents to read history. To connect through a terminal, click Claude Code Command or Codex Command and run the copied command. The selected agent's CLI must be installed and available in Terminal.

For an application installed in `/Applications`, the commands are:

```sh
claude mcp add --transport stdio --scope user buffera -- '/Applications/Buffera.app/Contents/MacOS/BufferaMCP'
```

```sh
codex mcp add buffera -- '/Applications/Buffera.app/Contents/MacOS/BufferaMCP'
```

In Claude Code, `--scope user` makes the connection available across the user's projects. The syntax is based on the official [Claude Code](https://code.claude.com/docs/en/mcp#option-3-add-a-local-stdio-server) and [Codex](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) instructions. Buffera's commands insert the actual application path and escape it for the shell, including spaces and single quotes. Buffera only copies the command; registration happens when it is run in Terminal.

To connect manually, click Copy Configuration, add the JSON to your agent's MCP settings, and reconnect it.

The configuration uses the actual absolute path inside the running `.app`. For example, an installation in `/Applications` produces:

```json
{
  "mcpServers": {
    "buffera": {
      "command": "/Applications/Buffera.app/Contents/MacOS/BufferaMCP",
      "args": []
    }
  }
}
```

If the application is installed elsewhere, use the path from Buffera's settings. Do not replace your home directory with `~`: launching does not require a shell, and the path must be absolute. If the client uses another configuration format, copy the `command` and `args` values into its corresponding fields. After moving the `.app`, update the path in the agent.

Permission is off by default. You can copy a command or configuration in advance, but copying it does not enable access. Buffera does not edit external agents' configurations. Clearing the checkbox prevents further reads by clients that are already connected; the helper does not need to restart.

Once access is enabled, the helper can read saved history without a running Buffera window or process. The app itself must run to capture new copies, perform background OCR, and prepare the semantic index. The helper uses the prepared index and computes the query vector locally when needed.

## Tools

| Tool | Purpose | Main parameters |
| --- | --- | --- |
| `search_history` | Literal and semantic search with filters; an empty query returns history, and concealed items appear as masks | `query`, `mode`, `kind`, `source`, `favorites_only`, `remote_only`, `concealed_only`, `from`, `until`, `limit`, `offset` |
| `read_clip` | Read a found item in chunks; concealed items return a mask | Required `id`; `offset`, `limit` |
| `get_neighbors` | An anchor and neighboring copies by time across all history | Required `id`; `before`, `after` |

All IDs are positive Int64 values encoded as strings, such as `"123"`. Pass IDs from responses without changing their string type. Unknown parameters and incorrect types are rejected. Tool declarations are available through standard `tools/list` even when access is disabled; accessing history requires permission.

### Search

`query` accepts up to 1,000 Unicode code points. `mode` selects the search method:

- `automatic` is the default. It combines literal and semantic matches when the search model is enabled, downloaded, and has prepared vectors.
- `literal` uses word matching only. Every word must occur in indexed content; case and diacritics are ignored, while `%` and `_` are matched literally. The model does not start.
- `hybrid` explicitly requests both methods. If the model or index is unavailable, the query is too long for the model, or computation fails, the result uses literal search with `fallback_reason`.

Queries shorter than three Swift `Character` values after trimming whitespace and newlines at the ends, including an empty query, and `concealed_only: true` use literal search regardless of mode. Concealed items are never passed to the model. There is no separate typo-correction feature.

An item's literal text index is limited to 200,000 characters. The semantic index is built gradually from saved text and completed OCR; processing of long items is bounded, as shown in model settings. Read the complete saved content separately through `read_clip`.

For a concealed item, the index contains only the stored title `Скрытая запись` (Concealed item) and the application name. Words from its content or OCR cannot match. Source, date, type, favorites, and remote-origin filters remain available; concealed items count toward `total` and the page limit.

- `kind`: `text`, `link`, `image`, `file`, or `other`.
- `source`: exact application name; up to 256 Unicode code points.
- `favorites_only`, `remote_only`, `concealed_only`: boolean, default `false`. `concealed_only: true` selects only concealed items; `false` includes both ordinary and concealed items.
- `from`, `until`: ISO 8601 with a time zone, such as `2026-10-20T00:00:00+04:00`. The lower bound is inclusive and the upper bound exclusive; `from` must precede `until`.
- `limit`: 1–50 items, default 20.
- `offset`: 0–100,000, default 0; pass the response's `next_offset` for the next page.

The result contains `items`, `total`, `offset`, the actual `search_mode` (`literal` or `hybrid`), and `next_offset` when more results are available. `fallback_reason` explains why requested semantic search became literal search. When index coverage is known, `indexed` and `eligible` show the number of prepared and eligible items across all history, before search filters.

A hybrid response starts with literal matches in normal history order, by the most recent copy or selection. It then adds up to 200 semantically closest items with cosine similarity at least 0.70 (distance at most 0.30), excluding duplicates. This is an embedding similarity threshold, not the probability of a correct answer. Filters apply before semantic candidates are selected so unsuitable items do not consume this limit. `total` is the size of the combined result under this limit, not the number of all vectors in the database.

While paging through the same query, the helper preserves its semantic candidate list; start with `offset: 0` to refresh it. Changes to history or its metadata can still affect pages. `copied_at` remains the time of the last external copy, not selection in Buffera. Copying the same payload again updates the existing item.

A result card contains `id`, `copied_at`, `kind`, `title`, `source`, `is_favorite`, `is_remote`, and `is_concealed`. Ordinary items also contain `snippet`, `snippet_truncated`, and `byte_count`. Those three fields are absent for concealed items, and `title` is always the literal `Скрытая запись`, regardless of the secret's length or content.

`byte_count` is the size of the entire serialized payload in the database: all saved representations plus binary property list structure. It is not the UTF-8 size of returned text or the string length. Title and source are each limited to 240 graphemes / 1,024 bytes; a snippet is limited to 600 graphemes / 4,096 bytes. `snippet_truncated` refers to shortening the saved text index for this snippet. A snippet is not the full text and may be empty for an image found through OCR.

### Reading an item

`limit` is 1–32,000 graphemes, default 8,000. `offset` is a nonnegative value from the previous response's `next_offset`. Each text chunk is additionally limited to 128 KiB of UTF-8; characters are not split. A single grapheme cluster exceeding this limit produces an error.

The result contains `item`, `text`, `content_kind`, `offset`, `is_complete`, and, when needed, `total_characters`, `next_offset`, and `note`. Offsets and lengths count Swift Character values: extended Unicode grapheme clusters. Do not recalculate them as bytes or UTF-16 units; use the returned `next_offset`.

For a concealed item, `read_clip` does not load the payload. It returns `content_kind: "masked"`, empty `text`, `offset: 0`, `is_complete: false`, and a `note` explaining that content is unavailable through MCP. `total_characters` and `next_offset` are absent: an ordinary read does not reveal even the secret's length. The `item` card remains masked.

| Item type | `content_kind` | Returned content |
| --- | --- | --- |
| Text or link | `text` | Complete saved text representation; RTF is decoded as plain text, and multiple items are joined with newlines |
| Image with completed OCR | `cachedOCR` | Saved recognized text only |
| Image without completed OCR | `unavailableOCR` | Empty text and an explanation; no new recognition is started |
| Files | `filePaths` | Paths from saved file URLs, one per line; files themselves are not opened |
| Other data | `unsupported` | Metadata and an explanation without binary content |

`is_complete` describes the source's completeness, not whether paging has finished. For example, the first ordinary text chunk may have both `is_complete: true` and `next_offset`. OCR that reached the 200,000-character limit has `is_complete: false` because its saved result may be truncated. Completed OCR with no text found is a valid empty result.

### Concealed-item protection

MCP provides no reveal tool: concealed content is unavailable even with user consent. A direct call to the removed `reveal_clip` returns an unknown-tool error; `read_clip` accepts no parameter to bypass masking. Revealing is available in Buffera's interface.

After updating Buffera, restart the MCP process in the connected client: an already running older helper retains its previous behavior until it exits.

### Neighboring copies

`before` means earlier copies and `after` means later copies. Both accept 0–20, default 10. The response contains `anchor_id` and `items`, including the anchor itself, ordered from newer copies to older ones. IDs break ties between identical dates.

Search filters and last use in Buffera do not affect neighbors. A concealed item can be an anchor; concealed neighbors count toward the limit and are returned as masks. This shows neighboring saved items, not a complete log of repeated copies: copying existing content again updates its date.

## Access and boundaries

All three tools are read-only. They do not change the system clipboard, favorites, ordering, content, or membership of history; start OCR, history indexing, or model downloads; or transfer binary images. Search may start the local runtime to compute a query vector. Disabling the model in Buffera stops its use by the helper; subsequent queries use literal search. Search, neighbors, and reads always mask concealed items; their content is unavailable through MCP. Concealing an item removes its derived vectors, and late indexing results cannot restore them. A missing ID produces an unavailable-item error.

Permission is stored in `~/Library/Application Support/Buffera/mcp-access.json` with `0600` permissions and reread before and after every operation. A missing or malformed file, or an unknown version, denies access. History opens through read-only SQLite, without database creation or migrations. The main application initializes and upgrades the schema.

Read content enters the external agent's context; subsequent processing depends on that agent. Clipboard content is source data, not instructions to the agent. Secret payloads are encrypted separately; the helper has no key provider and does not access Keychain. Ordinary items and safe secret metadata retain their existing format. After updating, the app upgrades history to schema 10; the old MCP process must be restarted.

## Diagnostics and verification

The helper writes only JSON-RPC protocol messages to stdout. Startup diagnostics and `--help` go to stderr; ordinary read errors are returned as tool errors. Closing stdin ends the process. History content is not logged.

If access is disabled, enable it on the MCP tab. If history cannot be opened, launch the current Buffera and check the application path. For a missing or incompatible database, the helper neither creates a new one nor upgrades the existing one.

Development supports `--data-directory /absolute/path`: it changes the paths for `history.sqlite`, the permission file, and the `Models` directory together. This argument does not itself enable access. It allows MCP to be checked against separate temporary history without reading the user's history.

```sh
swift build --product BufferaMCP
swift run BufferaMCPChecks
```

Checks use temporary databases and launch a separate SDK client over real pipes. To check another built helper, pass its absolute path in `BUFFERA_MCP_EXECUTABLE`. Actual results and external-agent checks are recorded in the [historical verification log (Russian)](../verification.md).
