# Windows edition

This is a separate Windows application in the same repository. Do not change the native macOS app, its project, installed bundle, settings, or update channel as part of Windows work.

The first release is read-only. Do not add write IPC, save shortcuts, or editor mutations. Keep the original manifest and resource bytes. Unsupported rendering must be explicit; a QuickLook preview is a saved thumbnail, not a new render and may be stale. Reject unsafe paths, symlinks, missing resources, excessive allocations, and malformed metadata before rendering.

Dependencies must be pinned in package-lock.json. Include Pentrado, Vue, Typr, Electron, and Chromium licenses in distributed packages. Windows releases use windows-v* tags, are prereleases until accepted on real Windows machines, and must not displace the macOS /releases/latest target.

Use synthetic fixtures only. Never commit users' projects, absolute home paths, credentials, or private audit logs. Verification runs in Windows CI; follow explicit user instructions about local testing.
