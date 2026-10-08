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
endpoint apart from a working one without touching the project. It tests the
unsaved values in the dialog and reports the endpoint and model used. It does
not save settings. An empty key reuses the saved key only for the same endpoint;
changing the endpoint requires a new key, both when testing and when saving.

The verified request shape is the OpenAI-compatible one:

```
POST {endpoint}/chat/completions
{ "model": …, "temperature": 0, "messages": [ {system}, {user} ] }
```

## What it can do

The assistant is offered 26 of the editor's 39 operations:

| Group | Operations |
|---|---|
| Layers | `appearance` (visibility, opacity, blend mode), `rename`, `transform`, `reorder`, `duplicate`, `delete`, `parent`, `lock`, `rasterize`, `ungroup` |
| New layers | `add` (pixels, group, adjustment), `styled` (text and shapes) |
| Pixels | `filter`, `adjustment`, `effect`, `applyMask` |
| Masks | `clip` (clip to another layer), `mask` (add, remove, toggle, invert, link), `transformMask` |
| Sets of layers | `group`, `arrange`, `moveLayers`, `transformLayers` |
| The document | `canvas`, `imageSize`, `flipCanvas` |

## What it deliberately cannot do, and why

Being explicit about this matters more than covering everything: a model that
promises something it cannot deliver, or invents a substitute that appears to
work, is worse than one that says "I can't do that". Each of these needs
information that is not in the conversation, and the prompt tells the model so.

| Operation | Why not |
|---|---|
| `selection`, `selectionMask` | A selection is made by pointing at the canvas; the model cannot see or make one. |
| `fill`, `gradient`, `clear` | They act on a selection. With none, they would fill or erase the whole layer. |
| `bucket` | It seeds from a pixel of the canvas. |
| `stroke` | It is a freehand path drawn over the canvas. |
| `pixels` | It is raw pixel data. |
| `guides` | Guides are dragged out of the rulers. |
| `merge` | It needs the layers composited into one image, which is the editor's own merge path. Doing it in the panel would duplicate that path, including its blend-mode and effective-opacity rules; extracting it is better done on its own. |
| `batch`, `duplicateTree`, `importPixels` | Internal compositions of operations already offered: the panel already applies operations in order, `duplicate` already copies a group with its children, and `add` with type `pixels` covers the last. |

## How a request is checked

A model's answer is untrusted input. Each operation is checked against the live
layer list immediately before it runs, including changes made by preceding
operations in the same answer. Each result is reported separately:

- **Requests own a project and revision.** Both are captured before the network
  request. Switching, closing, reloading, or manually editing the project
  invalidates the answer. Image rendering is checked again before submission.
  Only successful commits from this request may advance its expected revision.

- **The ids are resolved, not trusted.** The editor matches ids exactly
  (`m.layers.find(l => l.id === op.id)`), so an id the model re-cased would come
  back as an opaque `stale`. Every id an operation names — `id`, `ids`,
  `parentID`, `maskSourceID`, `sourceID`, `keyID` — is mapped back to the spelling the
  project uses first.
- **Targets remain explicit.** The assistant uses the shared commit function,
  without the toolbar's selection expansion. An unknown id is rejected; it
  never becomes an omitted id or a new layer. Current multiselection does not
  override a single target.
- **Enumerations must match exactly** and values must be in range, checked here
  so the panel can say which part failed instead of passing on an opaque error.
- **Set operations must be possible**: the layers must exist, and `group` needs
  them to share a parent, which is what the editor requires too.
- **Parameters follow the editor protocol.** Filters use `settings`, for example
  `{"kind":"filter","id":"…","filter":"Gaussian Blur","settings":{"radius":20}}`.
  Adjustments and effects use `field` and `value`, for example
  `{"kind":"adjustment","id":"…","field":"saturation","value":20}` and
  `{"kind":"effect","id":"…","effect":"shadow","field":"opacity","value":0.6}`.
- **Restyling preserves existing defaults.** A partial text or shape change
  inherits its position, size, font, spacing, colors, and box. UTF-16 font/color
  runs are remapped when content changes; explicit font or color changes replace
  the corresponding runs. An explicit box size requests resizing.
- **Outcomes come from the commit result.** Repeated identical errors remain
  failures; a busy editor rejects the operation immediately. There is no timeout
  that silently converts a failed or unsubmitted edit into success.

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
  filters, adjustments, effects, locking, rasterizing, masks and ungrouping; it
  may create text, shape, group, pixel and adjustment layers; it may align,
  move and transform sets of layers; and it may resize or flip the document. It
  has no operation for opening, saving, importing, exporting, or writing files,
  so it cannot reach the filesystem even if it is asked to. The operations it is
  not offered are listed above, with the reason for each.
- **A text or shape layer is rendered by the editor, not by the model.** The
  model supplies the parameters (content, font size, colour, alignment, box);
  the panel renders them with the same `renderText`/`renderShape` the editor's
  own text and shape tools use, and the resulting image is stored alongside the
  parameters so the layer stays re-editable.
- **What it does is what a person could do.** Operations use the shared commit
  gate before `window.editor.edit`, with the captured project and revision.
  Busy state, painting, GPU failure, lost context, and unsupported rendering
  block visual changes. Backend locks are checked again, and successful edits
  enter the normal undo stack. Metadata-only rename/lock operations remain
  available under the editor's existing read-only preview policy.

## Tests

- `tests/ai-assistant.test.mjs` covers the pure parts: prompt assembly (every
  enumeration appears exactly, every layer id is present), response parsing
  (fenced, wrapped, malformed), operation checking, text and shape
  normalisation, endpoint policy, and the settings round-trip.
- `tests/assistant-runner.test.mjs` exercises delayed replies and image rendering,
  project/revision ownership, sequential mask changes, deleted targets, repeated
  failures, shared permission rejection, actual parameter storage, text runs,
  and unsaved connection settings using synthetic projects.
- `tests/smoke/assistant.spec.mjs` runs the packaged app against a loopback
  stub service, so the whole path — settings, IPC, prompt, parsing, checking,
  applying, undo — is exercised with no network, no real key, and no vendor.
  It also asserts the panel never covers the canvas, that a refused or
  unauthorized operation changes nothing, and that a text or shape request
  really produces a new layer without disturbing the selected one.
  Regressions cover project switching during a request, multiselection, actual
  WebGL context loss with preview retention, partial text restyling, repeated
  lock failures, and connection testing before saving.

These suites run in the Windows verification workflow, including the packaged
Electron smoke checks with a software GPU. Local macOS execution is not a
substitute for Windows acceptance or hardware GPU checks.

## Limits

- One request at a time; there is no conversation history, so each request is
  answered from the layer list alone.
- The panel is not a substitute for the editor: it emits the same operations a
  person would, and anything the editor cannot render is rejected the same way.
- Windows-only, like the rest of this application.
