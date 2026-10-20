import { app, BrowserWindow, dialog, ipcMain, Menu, powerSaveBlocker, protocol, safeStorage, session, shell } from 'electron';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { DesktopState } from '../desktop-state.mjs';
import { AgentClient, safeMessage, serverOrigin } from '../agent-client.mjs';
import { ObsController } from '../obs-controller.mjs';
import { isDesktopDocument, recoveryPreviewUrl } from '../desktop-url.mjs';
import { uploadRecording } from '../recording-upload.mjs';
import { obsProcessIdentity } from '../obs-process.mjs';
import { recordingDiskPolicy, requireRecordingSpace, SAFETY_RESERVE_BYTES } from './disk-policy.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const runFile = promisify(execFile);
const appOrigin = 'fieldrush://desktop';
protocol.registerSchemesAsPrivileged([{ scheme: 'fieldrush', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);
if (!app.requestSingleInstanceLock()) app.quit();
let window, store, obs, agent, blocker, refreshTimer;
let operationBusy = false;
let quitting = false;
let latest = {};
let stateError = null;
let progress = null, recoveryAbort = null, reconnectAllowed = false, reconnectAt = 0;
let refreshing = null;

function trusted(event) {
  if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame ||
      !isDesktopDocument(event.senderFrame.url)) throw new Error('Untrusted app request.');
}
function handle(name, fn) {
  ipcMain.handle(name, async (event, value) => {
    trusted(event);
    try { return { ok: true, value: await fn(value) }; }
    catch (error) { return { ok: false, error: safeMessage(error) }; }
  });
}
async function operation(fn) {
  if (operationBusy) throw new Error('Another setup step is running. Please wait.');
  operationBusy = true;
  agent?.stop();
  try {
    const deadline = Date.now() + 45_000;
    while (agent?.busy && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
    if (agent?.busy) throw new Error('Fieldrush is still syncing. Try again shortly.');
    return await fn();
  } finally {
    operationBusy = false;
    progress = null;
    if (store.value.pairing) agent.start();
    await refresh();
  }
}

async function refresh() {
  if (refreshing) return refreshing;
  refreshing = refreshState().finally(() => { refreshing = null; });
  return refreshing;
}
async function refreshState() {
  if (!obs || !window || window.isDestroyed()) return;
  if (reconnectAllowed && !obs.connected && !operationBusy && !agent.busy && Date.now() > reconnectAt) {
    reconnectAt = Date.now() + 10_000;
    // Reconnect only after the user has connected once this session. Do not
    // reconfigure scenes or outputs when recovering a socket connection.
    await obs.connect({ password: store.value.obsPassword }).catch(() => {});
  }
  const status = await obs.status().catch(() => ({ connected: false, streaming: false, recording: false }));
  const owned = obs.getState();
  const outputUncertain = !status.connected && Boolean(owned.streamingOwned || owned.recordingOwned || owned.testStream || owned.localTest);
  if ((status.streaming || status.recording || outputUncertain || operationBusy) && blocker === undefined) blocker = powerSaveBlocker.start('prevent-app-suspension');
  if (!status.streaming && !status.recording && !outputUncertain && !operationBusy && blocker !== undefined) { powerSaveBlocker.stop(blocker); blocker = undefined; }
  let freeBytes = null;
  if (store.value.recordingDirectory) {
    try { const space = await fs.statfs(store.value.recordingDirectory); freeBytes = space.bavail * space.bsize; } catch { /* shown as unavailable */ }
  }
  const diskPolicy = recordingDiskPolicy(store.value.server, !app.isPackaged);
  if (freeBytes !== null && freeBytes < SAFETY_RESERVE_BYTES && status.recording && owned.recordingOwned) {
    stateError = 'Recording stopped: less than 256 MB of disk space remains. Free space before restarting.';
    await obs.stopCurrent().catch(() => { stateError = 'Disk nearly full. Could not stop the recording automatically; stop OBS now.'; });
  }
  latest = {
    server: store.value.server, development: !app.isPackaged,
    displayName: store.value.displayName || `${os.userInfo().username}'s Mac`,
    recordingDirectory: store.value.recordingDirectory || '',
    cameraId: store.value.cameraId || '', microphoneId: store.value.microphoneId ?? null,
    hasObsPassword: Boolean(store.value.obsPassword),
    pairing: agent.publicSession(), reachable: agent.reachable,
    status, freeBytes, diskPolicyLabel: diskPolicy.label, busy: operationBusy, progress, outputUncertain, outputHeld: Boolean(owned.target || owned.testStream || owned.localTest), canPauseUpload: Boolean(recoveryAbort), hasRecovery: Boolean(store.value.recovery),
    error: stateError || agent.error || null,
    lastLocalTest: store.value.lastLocalTest ?? null,
    lastStreamTest: store.value.lastStreamTest ?? null,
    version: app.getVersion(),
  };
  window.webContents.send('state-changed', latest);
  return latest;
}

async function configureController() {
  if (store.value.cameraId && store.value.recordingDirectory) {
    const space = await fs.statfs(store.value.recordingDirectory);
    requireRecordingSpace(space.bavail * space.bsize, recordingDiskPolicy(store.value.server, !app.isPackaged));
    await obs.configure({ cameraId: store.value.cameraId, microphoneId: store.value.microphoneId ?? null, recordingDirectory: store.value.recordingDirectory });
  }
}

async function requireKnownIdle() {
  const status = await obs.status(), owned = obs.getState();
  if (status.streaming || status.recording || owned.target || owned.testStream || owned.localTest || (!status.connected && (owned.recordingOwned || owned.streamingOwned))) {
    throw new Error('Reconnect OBS and stop the video and recording before changing this setup.');
  }
}

app.whenReady().then(async () => {
  if (process.platform !== 'darwin') { await dialog.showMessageBox({ message: 'This version of Fieldrush Broadcaster supports Mac only.' }); app.quit(); return; }
  store = new DesktopState(app.getPath('userData'), safeStorage);
  // Never overwrite an existing encrypted setup when the keychain is locked.
  await store.load();
  // Persisted server settings are untrusted; never send credentials to arbitrary URLs.
  try { serverOrigin(store.value.server, !app.isPackaged); } catch { store.value.server = 'https://ops-staging.field.bh'; store.value.pairing = null; }
  obs = new ObsController({
    getProcessIdentity: obsProcessIdentity,
    workspaceId: store.value.workspaceId, savedState: store.value.obsState || {},
    saveState: value => store.update({ obsState: value }),
    allowedOverlayOrigins: [store.value.server],
  });
  agent = new AgentClient({ store, obs, development: !app.isPackaged, onChange: () => void refresh() });
  agent.beforeStart = async () => {
    if (!(await obs.status()).recording) {
      if (!store.value.recordingDirectory) throw new Error('Choose a backup recording folder.');
      const space = await fs.statfs(store.value.recordingDirectory);
      requireRecordingSpace(space.bavail * space.bsize, recordingDiskPolicy(store.value.server, !app.isPackaged));
    }
  };

  protocol.handle('fieldrush', async request => {
    const url = new URL(request.url);
    if (url.hostname !== 'desktop' || request.method !== 'GET') return new Response('', { status: 403 });
    const pathname = url.pathname === '/' ? '/app.html' : url.pathname;
    const files = { '/app.html': ['app.html', 'text/html'], '/app.css': ['app.css', 'text/css'], '/app.js': ['app.js', 'text/javascript'] };
    try {
      if (pathname === '/Outfit.ttf' || pathname === '/PlusJakartaSans.ttf') {
        const fontDir = app.isPackaged ? path.join(process.resourcesPath, 'fonts') : path.resolve(directory, '../../../mobile/assets/fonts');
        return new Response(await fs.readFile(path.join(fontDir, pathname.slice(1))), { headers: { 'Content-Type': 'font/ttf' } });
      }
      const entry = files[pathname];
      if (!entry) return new Response('', { status: 404 });
      return new Response(await fs.readFile(path.join(directory, entry[0])), { headers: { 'Content-Type': entry[1], 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-src 'none'" } });
    } catch { return new Response('', { status: 404 }); }
  });
  session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  window = new BrowserWindow({ width: 1120, height: 850, minWidth: 900, minHeight: 650, title: 'Fieldrush Broadcaster', backgroundColor: '#faf7ef', webPreferences: { preload: path.join(directory, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true } });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Fieldrush', submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'hide' }, { role: 'quit' }] },
    { role: 'editMenu' }, { role: 'windowMenu' },
  ]));
  handle('state', refresh);
  handle('open-obs', async () => {
    try { await fs.access('/Applications/OBS.app'); await runFile('/usr/bin/open', ['-a', '/Applications/OBS.app']); }
    catch { await shell.openExternal('https://obsproject.com/download'); }
  });
  handle('open-referee', () => shell.openExternal(serverOrigin(store.value.server, !app.isPackaged) + '/'));
  handle('open-guide', () => shell.openExternal(serverOrigin(store.value.server, !app.isPackaged) + '/broadcast/setup'));
  handle('set-server', value => operation(async () => {
    await requireKnownIdle();
    const status = await obs.status();
    if (store.value.pairing || status.streaming || status.recording) throw new Error('Forget the current pairing before changing servers.');
    const server = serverOrigin(value, !app.isPackaged);
    await store.update({ server, pendingPair: null });
    // Each controller has a fixed exact overlay origin allowlist.
    await obs.disconnect();
    obs = new ObsController({ getProcessIdentity: obsProcessIdentity, workspaceId: store.value.workspaceId, savedState: store.value.obsState || {}, saveState: state => store.update({ obsState: state }), allowedOverlayOrigins: [server] });
    agent.obs = obs;
  }));
  handle('connect-obs', value => operation(async () => {
    const password = typeof value?.password === 'string' && value.password ? value.password : store.value.obsPassword;
    if (typeof password !== 'string' || !password || password.length > 1024) throw new Error('Enter the password from OBS → Tools → WebSocket Server Settings.');
    await obs.connect({ url: 'ws://127.0.0.1:4455', password });
    await store.update({ obsPassword: password });
    reconnectAllowed = true;
    const status = await obs.status();
    const held = obs.getState();
    if (!status.streaming && !status.recording && !held.outputSessionId && !held.target && !held.testStream && !held.localTest) await obs.prepareWorkspace();
    return await obs.listDevices();
  }));
  handle('devices', () => operation(() => obs.listDevices()));
  handle('choose-folder', () => operation(async () => {
    await requireKnownIdle();
    const result = await dialog.showOpenDialog(window, { title: 'Save match recordings', properties: ['openDirectory', 'createDirectory'], defaultPath: app.getPath('videos') });
    if (result.canceled) return null;
    await store.update({ recordingDirectory: result.filePaths[0], lastLocalTest: null });
    return result.filePaths[0];
  }));
  handle('configure', value => operation(async () => {
    await requireKnownIdle();
    if (typeof value?.cameraId !== 'string' || !value.cameraId || (value.microphoneId !== null && typeof value.microphoneId !== 'string')) throw new Error('Select your USB camera and audio input.');
    await store.update({ cameraId: value.cameraId, microphoneId: value.microphoneId, lastLocalTest: null, lastStreamTest: null });
    await configureController();
  }));
  handle('preview', async () => obs.preview());
  handle('local-test', () => operation(async () => {
    await store.update({ lastLocalTest: null });
    progress = 'Recording a 10-second camera test…'; void refresh();
    await obs.testRecording(10_000);
    await store.update({ lastLocalTest: new Date().toISOString() });
  }));
  handle('stream-test', () => operation(async () => {
    await store.update({ lastStreamTest: null });
    if (!store.value.pairing) throw new Error('Pair this laptop to a match first.');
    progress = 'Preparing a private test. It will not appear on your match page…'; void refresh();
    let failure = null;
    try {
      const input = await agent.request('/api/broadcast-agent/test', { method: 'POST', body: { action: 'prepare' } });
      await obs.startTest(input);
      progress = 'Checking that live video reaches the server…'; void refresh();
      let verified = false;
      for (let attempt = 0; attempt < 15; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 2000));
        const [remote, local] = await Promise.all([agent.request('/api/broadcast-agent/test'), obs.status()]);
        if (attempt >= 4 && remote.connected === true && local.streaming && local.recording && local.outputBytes > 0) { verified = true; break; }
      }
      if (!verified) throw new Error('The private test did not confirm a working stream. Check the camera and internet before kickoff.');
    } catch (error) { failure = error; }
    finally {
      try { if (obs.getState().testStream) await obs.stopTest(); }
      catch { failure = new Error('The private test could not stop locally. Stop OBS manually, then retry cleanup.'); }
      try { await agent.request('/api/broadcast-agent/test', { method: 'POST', body: { action: 'finish' } }); }
      catch { failure = new Error('Private test cleanup is incomplete. Reconnect and run the test again before starting a match.'); }
    }
    if (failure) throw failure;
    await store.update({ lastStreamTest: new Date().toISOString() });
  }));
  handle('cancel-upload', async () => { recoveryAbort?.abort(new Error('Upload paused. Choose Recover a recording to resume.')); });
  handle('restart-recovery', () => operation(async () => {
    const pending = store.value.recovery;
    if (pending?.uploaded && store.value.pairing?.deviceKey === pending.deviceKey) {
      const current = await agent.request(`/api/broadcast-agent/recovery?uploadId=${encodeURIComponent(pending.uploadId)}`);
      if (current.publicationPending) throw new Error('This replay replacement is already reserved. Choose Recover a recording to finish it before starting over.');
    }
    const answer = await dialog.showMessageBox(window, { type: 'warning', message: 'Start recording recovery over?', detail: 'This forgets the pending upload on this Mac, not your local recording or the match replay. Unpublished uploads remain private. An already attached replay is not removed.', buttons: ['Keep upload', 'Start over'], cancelId: 0, defaultId: 0 });
    if (answer.response === 1) await store.update({ recovery: null });
  }));
  handle('recover-recording', () => operation(async () => {
    await requireKnownIdle();
    const paired = store.value.pairing;
    if (!paired) throw new Error('Recover the recording while this laptop is still paired to its finished match.');
    const status = await obs.status();
    if (status.streaming || status.recording) throw new Error('Finish the match and stop video and recording before recovery.');
    let pending = store.value.recovery;
    if (pending && !pending.uploaded && Date.parse(pending.expiresAt) <= Date.now()) {
      await store.update({ recovery: null });
      throw new Error('The upload window expired. Your local recording is unchanged. Choose Recover a recording to start again.');
    }
    if (!pending || pending.deviceKey !== paired.deviceKey) {
      const recordings = (obs.getState().recordings || []).filter(item =>
        paired.matchKind === 'SOLO' ? item.openQueueGameId === paired.matchId : item.fixtureId === paired.matchId);
      if (!recordings.length) throw new Error('No completed backup from this paired match is saved on this Mac. Recovery needs the original full recording and its saved start time.');
      const chosen = await dialog.showOpenDialog(window, { title: 'Choose the original complete match recording', properties: ['openFile'], defaultPath: recordings.at(-1).path, filters: [{ name: 'Match recordings', extensions: ['mkv', 'mp4', 'mov'] }] });
      if (chosen.canceled) return;
      const manifest = recordings.find(item => item.path === chosen.filePaths[0]);
      if (!manifest) throw new Error('Choose an original recording from this match. Edited files or other matches cannot be attached.');
      const stat = await fs.stat(manifest.path);
      if (!stat.isFile()) throw new Error('Choose the original recording file.');
      const consent = await dialog.showMessageBox(window, { type: 'question', message: 'Upload this match backup?', detail: `${path.basename(manifest.path)} · ${(stat.size / 1024 ** 3).toFixed(2)} GB\nThe upload is private. You will preview and confirm it before the replay changes. Keep this app open; you can pause and resume the upload.`, buttons: ['Cancel', 'Upload privately'], cancelId: 0, defaultId: 0 });
      if (consent.response !== 1) return;
      const prepared = await agent.request('/api/broadcast-agent/recovery', { method: 'POST', body: { action: 'prepare', fileName: path.basename(manifest.path), size: stat.size, recordingStartedAt: manifest.recordingStartedAt } });
      if (prepared.attached === true) { progress = 'This recording is already attached.'; await refresh(); return; }
      if (typeof prepared.uploadId !== 'string' || (prepared.status !== 'ATTACHING' && (prepared.protocol !== 'tus' || typeof prepared.uploadUrl !== 'string'))) throw new Error('The recording upload was not prepared correctly.');
      pending = { ...prepared, ...manifest, deviceKey: paired.deviceKey, size: stat.size, mtime: stat.mtimeMs, uploaded: prepared.status === 'ATTACHING' };
      await store.update({ recovery: pending });
    }
    if (!pending.uploaded) {
      recoveryAbort = new AbortController();
      try {
        await uploadRecording({ filePath: pending.path, uploadUrl: pending.uploadUrl, expectedSize: pending.size, expectedMtime: pending.mtime, signal: recoveryAbort.signal,
          onProgress: (sent, total) => { progress = `Uploading private backup · ${Math.floor(sent / total * 100)}%`; void refresh(); } });
        pending = { ...pending, uploaded: true }; await store.update({ recovery: pending });
      } finally { recoveryAbort = null; }
    }
    progress = 'Checking the uploaded recording…'; await refresh();
    const result = await agent.request(`/api/broadcast-agent/recovery?uploadId=${encodeURIComponent(pending.uploadId)}`);
    if (result.status === 'ATTACHED') { await store.update({ recovery: null }); await dialog.showMessageBox(window, { message: 'The recovered replay is attached to the match.' }); return; }
    if (result.status === 'EXPIRED' || result.status === 'FAILED') { await store.update({ recovery: null }); throw new Error('This upload expired or could not be processed. Your local recording is unchanged. Start recovery again.'); }
    if (result.status !== 'READY') { await dialog.showMessageBox(window, { message: 'Your backup is uploaded and still processing.', detail: 'Nothing has been published. Choose Recover a recording again in a few minutes to preview and confirm it.' }); return; }
    await shell.openExternal(recoveryPreviewUrl(result.playbackUrl));
    const confirmation = await dialog.showMessageBox(window, { type: 'warning', message: 'Replace this match’s replay with the backup?', detail: 'Review the private preview opened in your browser. Confirm only if it contains the entire match, including kickoff and the finish. The server will also check its saved timestamps and duration.', buttons: ['Not yet', 'Replace replay'], cancelId: 0, defaultId: 0 });
    if (confirmation.response !== 1) return;
    const attached = await agent.request('/api/broadcast-agent/recovery', { method: 'POST', body: { action: 'attach', uploadId: pending.uploadId, recordingStartedAt: pending.recordingStartedAt } });
    if (attached.attached !== true) throw new Error('The replay was not confirmed. Try recovery again.');
    await store.update({ recovery: null });
    await dialog.showMessageBox(window, { message: 'The recovered replay is now attached to the match.' });
  }));
  handle('pair', value => operation(async () => {
    await store.update({ displayName: String(value?.displayName ?? '').trim() });
    return await agent.pair(value?.code, value?.displayName);
  }));
  handle('forget', () => operation(async () => {
    await requireKnownIdle();
    const status = await obs.status();
    if (status.streaming || status.recording) throw new Error('Stop the stream and recording before forgetting this match.');
    await store.update({ pairing: null, pendingPair: null, pendingAck: null, lastCommand: null, lastStreamTest: null });
    agent.session = null;
    agent.reachable = false;
  }));
  handle('stop-local', () => operation(async () => {
    const answer = await dialog.showMessageBox(window, { type: 'warning', message: 'Stop broadcasting from this Mac?', detail: 'This stops the live video and local recording. The match clock and scoring continue.', buttons: ['Keep broadcasting', 'Stop video and recording'], cancelId: 0, defaultId: 0 });
    if (answer.response === 1) {
      const wasTest = Boolean(obs.getState().testStream);
      await obs.stopCurrent();
      if (wasTest && store.value.pairing) await agent.request('/api/broadcast-agent/test', { method: 'POST', body: { action: 'finish' } });
    }
  }));
  handle('open-recordings', async () => {
    if (!store.value.recordingDirectory) throw new Error('Choose a recording folder first.');
    const error = await shell.openPath(store.value.recordingDirectory);
    if (error) throw new Error('Could not open your recording folder.');
  });
  window.on('close', event => {
    if (quitting) return;
    if (latest.status?.streaming || latest.status?.recording || latest.outputUncertain || operationBusy) {
      event.preventDefault();
      void dialog.showMessageBox(window, { type: 'warning', message: 'Keep Fieldrush open during the match.', detail: 'Stop the video and recording before closing the app. You can minimize this window.', buttons: ['Keep open'] });
    }
  });
  app.on('before-quit', event => {
    if (!quitting && (latest.status?.streaming || latest.status?.recording || latest.outputUncertain || operationBusy)) {
      event.preventDefault(); window.show();
      void dialog.showMessageBox(window, { message: 'Stop the stream and recording before quitting Fieldrush.', buttons: ['Keep open'] });
    } else { quitting = true; agent.stop(); clearInterval(refreshTimer); }
  });
  await window.loadURL(appOrigin + '/');
  await refresh();
  refreshTimer = setInterval(() => void refresh(), 2_000);
  // OBS is connected only by an explicit user action. Merely opening the app
  // never switches scenes, accesses a camera, records, or starts a broadcast.
  if (store.value.pairing) agent.start();
}).catch(async () => { await dialog.showErrorBox('Fieldrush could not open', 'Restart Fieldrush. If the problem continues, reinstall the app.'); app.quit(); });

app.on('second-instance', () => { window?.show(); window?.focus(); });
app.on('window-all-closed', () => app.quit());
