import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, realpath } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { newProject } from '../packages/comp-bridge/edit.mjs';
import { ProjectSession } from '../packages/platform/project-session.mjs';
import { RecoveryStore, saveProject } from '../packages/platform/save-project.mjs';

async function setup(t) {
  const directory = await mkdtemp(path.join(await realpath(os.tmpdir()), 'comp-recovery-navigation-'));
  const store = new RecoveryStore(path.join(directory, 'recovery'));
  const session = new ProjectSession(undefined, { recovery: store });
  t.after(async () => { session.close(); await store.queue.catch(() => {}); await rm(directory, { recursive: true, force: true }); });
  session.create(8, 6);
  await session.flushRecovery();
  const [snapshot] = await store.list();
  return { directory, store, session, snapshot };
}

test('discard followed by canceled open keeps the dirty document and its recovery', async t => {
  const { store, session, snapshot } = await setup(t);
  const current = session.current;
  session.discardRecoveryOnReplacement();
  assert.deepEqual(await session.open(() => null), { canceled: true });
  assert.equal(session.current, current);
  assert.equal(session.isDirty(), true);
  assert.deepEqual((await store.restore(snapshot.key)).manifest, current.data.manifest);
});

test('discard followed by a failed read or invalid new canvas keeps recovery', async t => {
  const { directory, store, session, snapshot } = await setup(t);
  const current = session.current;
  session.discardRecoveryOnReplacement();
  assert.ok((await session.open(() => path.join(directory, 'missing.comp'))).error);
  assert.equal(session.current, current);
  assert.deepEqual((await store.restore(snapshot.key)).manifest, current.data.manifest);
  session.discardRecoveryOnReplacement();
  assert.ok(session.create(0, 6).error);
  assert.equal(session.current, current);
  assert.deepEqual((await store.restore(snapshot.key)).manifest, current.data.manifest);
});

test('pending autosave survives canceled and failed navigation after discard', async t => {
  const { directory, store, session, snapshot } = await setup(t);
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const result = session.edit(session.current.id, session.revision, { kind: 'add', type: 'group', name: 'Pending autosave' });
  assert.ok(result.project);
  const revision = session.revision;
  assert.notEqual(revision, snapshot.revision);
  session.discardRecoveryOnReplacement();
  assert.deepEqual(await session.open(() => null), { canceled: true });
  session.discardRecoveryOnReplacement();
  assert.ok((await session.open(() => path.join(directory, 'missing.comp'))).error);
  t.mock.timers.tick(800);
  await store.queue;
  const latest = (await store.list()).find(item => item.revision === revision);
  assert.ok(latest, 'the queued autosave must still write the retained document');
  assert.equal((await store.restore(latest.key)).manifest.layers[0].name, 'Pending autosave');
});

test('a successful replacement clears only the discarded document recovery', async t => {
  const { directory, store, session } = await setup(t);
  const other = newProject(16, 12);
  await store.write(other, randomUUID());
  const location = path.join(directory, 'other.comp');
  await saveProject(other, location);
  session.discardRecoveryOnReplacement();
  const result = await session.open(() => location);
  assert.ok(result.project);
  assert.equal(result.project.dirty, false);
  await store.queue;
  const items = await store.list();
  assert.equal(items.length, 1);
  assert.equal(items[0].documentID, other.manifest.documentID);
});

test('successful reload clears discarded edits for the same document ID', async t => {
  const { directory, store, session } = await setup(t);
  const location = path.join(directory, 'source.comp');
  await saveProject(session.current.data, location);
  session.current.location = location;
  session.discardRecoveryOnReplacement();
  assert.ok((await session.reload(session.current.id)).project);
  await store.queue;
  assert.equal((await store.list()).length, 0);
  assert.equal(session.isDirty(), false);
});

test('restoring an unsaved snapshot of the same document keeps the recovery source', async t => {
  const { store, session, snapshot } = await setup(t);
  session.discardRecoveryOnReplacement();
  const restored = await store.restore(snapshot.key);
  session.install(restored);
  await store.queue;
  assert.equal(session.isDirty(), true);
  assert.deepEqual((await store.restore(snapshot.key)).manifest, restored.manifest);
});

test('new recovery written after a queued discard survives its cleanup', async t => {
  const { store, session } = await setup(t);
  const revision = randomUUID();
  const clearing = store.clear(session.current.data.manifest.documentID);
  const writing = store.write(session.current.data, revision);
  await Promise.all([clearing, writing]);
  const items = await store.list();
  assert.equal(items.length, 1);
  assert.equal(items[0].revision, revision);
});
