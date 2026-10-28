const $ = id => document.getElementById(id);
let state = {}, busy = false, previewing = false, toastTimer;
function notice(message) { $('toast').textContent = message; $('toast').hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('toast').hidden = true; }, 4500); }
function error(message) { $('error').textContent = message || ''; $('error').hidden = !message; }
async function invoke(action, value, message) {
  if (busy) return;
  busy = true; render(); error(null);
  try {
    const result = await window.fieldrush.invoke(action, value);
    if (!result.ok) throw new Error(result.error);
    if (message) notice(message);
    return result.value;
  } catch (e) { error(e.message); }
  finally { busy = false; render(); }
}
function fillDevices(devices) {
  if (!devices) return;
  for (const [id, list, chosen] of [['camera', devices.cameras, state.cameraId], ['microphone', devices.microphones, state.microphoneId]]) {
    const select = $(id), previous = select.value || chosen;
    select.replaceChildren(new Option(id === 'camera' ? 'Select your USB camera' : 'Muted — no audio', ''));
    for (const device of list || []) select.add(new Option(device.name, device.id));
    if ([...select.options].some(option => option.value === previous)) select.value = previous;
    else if (id === 'camera') {
      const osmo = (list || []).find(device => /osmo|dji/i.test(device.name));
      if (osmo) select.value = osmo.id;
    }
  }
  $('devices-section').hidden = false;
}
function render(next) {
  if (next) state = next;
  const status = state.status || {}, paired = state.pairing;
  document.querySelectorAll('button').forEach(button => { button.disabled = busy || state.busy; });
  $('progress-panel').hidden = !state.progress; $('progress').textContent = state.progress || '';
  $('pause-upload').hidden = !state.canPauseUpload; $('pause-upload').disabled = false;
  $('restart-recovery').hidden = !state.hasRecovery;
  const warning = [
    ...(state.outputUncertain ? ['OBS disconnected while video may still be running. Reconnect OBS before changing the match or closing Fieldrush.'] : (status.warnings || [])),
    ...(status.advisories || []),
  ].join(' ');
  $('warning').textContent = warning; $('warning').hidden = !warning;
  $('devices-section').hidden = !status.connected;
  $('connect').textContent = status.connected ? 'Reconnect' : 'Connect OBS';
  if (state.hasObsPassword) $('obs-password').placeholder = 'Saved securely — leave blank to reuse';
  if (!$('device-name').value) $('device-name').value = state.displayName || '';
  $('pair-form').hidden = Boolean(paired); $('paired').hidden = !paired;
  $('dev-server').hidden = !state.development; $('server').value = state.server || 'https://ops-staging.field.bh';
  $('server').disabled = Boolean(paired) || busy || state.outputUncertain;
  $('configure').disabled = busy || state.busy || !status.connected || status.streaming || status.recording;
  $('choose-folder').textContent = state.recordingDirectory || 'Choose a folder on this Mac ›';
  $('disk').textContent = state.freeBytes == null ? 'Local recording keeps a copy if the internet drops.' : `${(state.freeBytes / 1024 ** 3).toFixed(1)} GB free · ${state.diskPolicyLabel || 'at least 5 GB needed'}`;
  $('match-name').textContent = paired?.matchLabel || (paired?.matchKind === 'SOLO' ? 'Solo match' : 'Clan match');
  $('match-details').textContent = [paired?.venue, paired?.startsAt ? new Date(paired.startsAt).toLocaleString() : ''].filter(Boolean).join(' · ');
  $('expires').textContent = paired ? `Pairing expires ${new Date(paired.expiresAt).toLocaleString()}` : '';
  $('connection').textContent = status.streaming ? '● Streaming' : status.recording ? '● Recording locally' : paired && state.reachable && status.configured ? 'Camera connected' : status.connected ? 'OBS connected' : 'Getting ready';
  $('connection').classList.toggle('live', status.streaming);
  $('video-status').textContent = status.streaming ? 'Live video sending' : status.configured ? 'Camera configured' : 'Camera not configured';
  $('recording-status').textContent = status.recording ? '● Backup recording' : 'Backup not recording';
  $('audio-level').style.width = `${Math.max(0, Math.min(1, status.audioLevel || 0)) * 100}%`;
  $('audio-label').textContent = $('microphone').value ? 'Check that the audio meter moves.' : 'Field audio is muted.';
  for (const [id, good] of [['check-camera', status.configured && status.cameraAvailable && status.microphoneAvailable], ['check-recording', state.lastLocalTest], ['check-pairing', paired && state.reachable], ['check-upload', state.lastStreamTest]]) $(id).classList.toggle('passed', Boolean(good));
  $('local-test').disabled = busy || state.busy || !status.configured || status.streaming || status.recording;
  $('stream-test').disabled = busy || state.busy || !status.configured || !paired || !state.reachable || status.streaming || status.recording;
  $('stop-local').hidden = !status.streaming && !status.recording && !state.outputHeld;
  $('forget').disabled = busy || state.busy || status.streaming || status.recording || state.outputUncertain || state.outputHeld;
  $('recover-recording').disabled = busy || state.busy || !paired || status.streaming || status.recording || state.outputUncertain || state.outputHeld;
  $('pair-form').querySelector('button').disabled = busy || state.busy || state.outputUncertain || state.outputHeld;
  $('version').textContent = `Fieldrush Broadcaster ${state.version || ''} · Mac`;
  if (next?.error) error(next.error);
}
$('connect-form').addEventListener('submit', async event => { event.preventDefault(); const devices = await invoke('connect-obs', { password: $('obs-password').value }, 'OBS connected'); $('obs-password').value = ''; fillDevices(devices); });
$('pair-form').addEventListener('submit', async event => { event.preventDefault(); const paired = await invoke('pair', { code: $('pair-code').value, displayName: $('device-name').value }, 'Laptop paired to your match'); if (paired) $('pair-code').value = ''; });
$('configure').onclick = () => invoke('configure', { cameraId: $('camera').value, microphoneId: $('microphone').value || null }, 'Camera setup saved');
$('refresh-devices').onclick = async () => fillDevices(await invoke('devices'));
$('server').onchange = () => invoke('set-server', $('server').value);
for (const [id, action, message] of [
  ['open-obs', 'open-obs'], ['referee', 'open-referee'], ['open-controls', 'open-referee'], ['guide', 'open-guide'],
  ['choose-folder', 'choose-folder'], ['forget', 'forget', 'Pairing forgotten on this Mac'], ['open-recordings', 'open-recordings'],
  ['local-test', 'local-test', 'Local recording test passed'], ['stream-test', 'stream-test', 'Private stream test passed'],
  ['stop-local', 'stop-local'], ['recover-recording', 'recover-recording'], ['restart-recovery', 'restart-recovery'],
]) $(id).onclick = () => invoke(action, undefined, message);
$('pause-upload').onclick = () => window.fieldrush.invoke('cancel-upload');
window.fieldrush.onState(render);
void window.fieldrush.invoke('state').then(result => { if (result.ok) render(result.value); else error(result.error); });
setInterval(async () => {
  if (previewing || busy || !state.status?.configured) return;
  previewing = true;
  try {
    const result = await window.fieldrush.invoke('preview');
    if (result.ok && typeof result.value === 'string' && result.value.startsWith('data:image/')) {
      $('preview').src = result.value; $('preview').hidden = false; $('preview-empty').hidden = true;
    } else { $('preview').hidden = true; $('preview-empty').hidden = false; }
  } finally { previewing = false; }
}, 1500);
