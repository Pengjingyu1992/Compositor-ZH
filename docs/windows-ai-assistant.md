# Windows: the AI assistant panel

A docked panel at the bottom of the window that turns a natural-language request
into layer operations on the open project. It is off until an endpoint and a key
are configured, and nothing about it is required to use the editor.

## What it does

- Lists the project's layers as chips, so it is clear what the assistant can see.
- Sends a request plus the layer list to a chat-completions endpoint.
- The model answers with a list of operations; the panel checks each one against
  the live layer list and then runs them through the same path the toolbar uses.
- Reports each operation: applied, applied but already in that state, or skipped
  with the reason.

## Configuring it

AI settings are in the panel's **AI settings** dialog:

| Field | Notes |
|---|---|
| Endpoint | A chat-completions base URL. Must be `https`, except `http` on the loopback address so a model server running locally can be used. |
| Model | Sent as `model` in the request. |
| API key | Sent as `Authorization: Bearer …`. |

**Test connection** sends a one-word request, which tells a wrong key or a wrong
endpoint apart from a working one without touching the project.

The verified request shape is the OpenAI-compatible one:

```
POST {endpoint}/chat/completions
{ "model": …, "temperature": 0, "messages": [ {system}, {user} ] }
```

## Security

The assistant is deliberately narrow, because a model's output is untrusted
input.

- **The key is encrypted with Electron's `safeStorage`** (DPAPI on Windows)
  before it is written to `%APPDATA%\Compositor-Windows\ai-settings.json`, and it
  is never sent back to the renderer: the page only learns whether a key is set.
  When the platform cannot encrypt, the key is not stored at all rather than
  being written in clear text.
- **The key only goes to the configured endpoint.** A remote plain-`http`
  endpoint is refused, since the key would be readable in transit.
- **The renderer never talks to the network.** The request is made in the main
  process, which is why the page's `connect-src 'self'` policy is unchanged.
- **Operations are checked before they run.** Every `id` must exist in the
  current manifest, enumerations must match exactly, and values must be in
  range. A rejected operation is reported and skipped.
- **The allowlist is small on purpose.** The assistant may change layer
  appearance, names, transforms, order, parenting, duplication, deletion,
  filters, adjustments and effects. It has no operation for opening, saving,
  importing, exporting, or writing files, so it cannot reach the filesystem
  even if it is asked to.
- **What it does is what a person could do.** Operations go through
  `window.editor.edit` with the current revision, so they are revision-bound,
  they land on the undo stack, and unsupported rendering blocks them exactly as
  it blocks the equivalent manual edit.

## Tests

- `tests/ai-assistant.test.mjs` covers the pure parts: prompt assembly (every
  enumeration appears exactly, every layer id is present), response parsing
  (fenced, wrapped, malformed), operation checking, endpoint policy, and the
  settings round-trip.
- `tests/smoke/assistant.spec.mjs` runs the packaged app against a loopback
  stub service, so the whole path — settings, IPC, prompt, parsing, checking,
  applying, undo — is exercised with no network, no real key, and no vendor.
  It also asserts the panel never covers the canvas, and that a rejected or
  unauthorized operation changes nothing.

## Limits

- One request at a time; there is no conversation history, so each request is
  answered from the layer list alone.
- The panel is not a substitute for the editor: it emits the same operations a
  person would, and anything the editor cannot render is rejected the same way.
- Windows-only, like the rest of this application.
