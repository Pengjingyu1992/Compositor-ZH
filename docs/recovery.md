# Local recovery copies

The Chinese build stores recovery packages in `~/Library/Application Support/com.wonderassembly.compositor.zh-Hans/Recovery/`. A completed edit, undo or redo schedules a write after two seconds of inactivity. Active modal edits and project operations defer the write. Images and metadata encode off the main actor; concurrent writes are serialized.

Each UUID-named `.comp` package includes the normal project manifest and images plus `recovery.json`: recovery schema version, project version, document ID, history revision, original path, title, date and normal-close flag. Both parts are replaced atomically. Ordinary project saves omit this extra file and retain project format version 11. Versions 1–11 remain readable through ProjectStore.

Recovery never calls `markSaved`, changes a document's path, or adds a recent-file entry. A restored draft receives a fresh document ID and is explicitly dirty. Its source is removed only after a replacement recovery copy has been written successfully. A failed replacement keeps the source.

Limits are 32 document identities and 4 GiB of package file contents. Writes never evict existing copies. Existing packages are validated before replacement; damaged or unsupported packages remain available for manual review and explicit deletion. Validation reads the previous image data, so repeated writes on large documents include that background cost. Failed writes surface a message in the workspace.

Normal quit or tab closure marks existing copies as normally closed; these remain accessible from File > Recovery Copies. Startup offers review for unclosed, unsupported or damaged entries. This is delayed recovery, not a guarantee that edits made immediately before a crash reach disk.
