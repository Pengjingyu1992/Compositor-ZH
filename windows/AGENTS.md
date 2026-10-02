# Windows edition

This is a separate Windows application in the same repository. Do not change the native macOS app, its project, installed bundle, settings, or update channel as part of Windows work.

The alpha.1/alpha.2 releases were read-only. Batch 3 enables editing through validated, revision-bound operations. Keep unknown manifest fields and unmodified resource bytes, invalidate stale previews after visual edits, and explicitly delete text/shape metadata when rasterizing. Save through staged packages; overwrite requires an unchanged-source fingerprint, a durable journal, a complete backup, and interruption recovery. Unsupported rendering must remain explicit and must block visual edits. Reject unsafe paths, symlinks, missing resources, excessive allocations, and malformed metadata before rendering.

Dependencies must be pinned in package-lock.json. Include Pentrado, Vue, Typr, Electron, and Chromium licenses in distributed packages. Windows releases use windows-v* tags, are prereleases until accepted on real Windows machines, and must not displace the macOS /releases/latest target.

Use synthetic fixtures only. Never commit users' projects, absolute home paths, credentials, or private audit logs. Verification runs in Windows CI; follow explicit user instructions about local testing.
