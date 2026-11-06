import { randomUUID } from 'node:crypto';
import { serverOrigin, PRODUCTION_ORIGIN } from './agent-client.mjs';

// The local OBS password and laptop name remain shared. Applied camera/folder
// settings must follow their OBS profile, as must credentials and recovery.
const scopedKeys = ['workspaceId', 'obsState', 'pairing', 'pendingPair', 'pendingAck',
  'lastCommand', 'lastStreamTest', 'lastLocalTest', 'recovery', 'cameraId', 'microphoneId', 'recordingDirectory'];

function profile(value, server, legacy = false) {
  const result = Object.fromEntries(scopedKeys.map(key => [key, structuredClone(value[key] ?? null)]));
  result.workspaceId ||= randomUUID();
  result.obsState ||= { workspaceId: result.workspaceId };
  for (const key of ['pairing', 'pendingPair', 'recovery']) {
    if (!result[key]) continue;
    if (!result[key].server && legacy && server !== PRODUCTION_ORIGIN) result[key].server = server;
    if (result[key].server !== server) throw new Error('Saved match credentials belong to a different environment. Keep the saved setup and contact the organizer.');
  }
  return result;
}

async function persist(store, patch) {
  const previous = store.value;
  try { await store.update(patch); }
  catch (error) { store.value = previous; throw error; }
}

export async function initializeEnvironment(store, development = false) {
  const server = serverOrigin(store.value.server, development);
  const active = profile(store.value, server, store.value.environmentVersion !== 1);
  await persist(store, { ...active, server, environmentVersion: 1 });
}

export function assertEnvironmentSwitchable(value, status, owned) {
  if (value.pairing) throw new Error('Forget the current pairing before changing environments.');
  if (status.streaming || status.recording || owned.target || owned.testStream || owned.localTest ||
      owned.recordingOwned || owned.streamingOwned || owned.outputSessionId || owned.recordIntent || owned.streamIntent) {
    throw new Error('Reconnect OBS and stop the video and recording before changing environments.');
  }
}

export function assertCanForgetPairing(value) {
  if (value.recovery) throw new Error('Finish recording recovery, or choose Start recovery over, before forgetting this pairing.');
}

export async function switchEnvironment({ store, obs, agent, server: requested, development = false }) {
  const server = serverOrigin(requested, development);
  const current = serverOrigin(store.value.server, development);
  if (server === current) return false;
  if (agent.busy) throw new Error('Wait for the current camera operation before changing environments.');
  const status = await obs.status();
  assertEnvironmentSwitchable(store.value, status, obs.getState());
  const saved = store.value.environments?.[server];
  if (saved && saved.server !== server) throw new Error('The saved environment does not match its server.');
  // A new environment may start with the same hardware choices, but its OBS
  // workspace is still unconfigured and must be connected/configured explicitly.
  const destination = profile(saved ?? { cameraId: store.value.cameraId,
    microphoneId: store.value.microphoneId, recordingDirectory: store.value.recordingDirectory }, server);
  await obs.disconnect();
  // Snapshot after disconnect so its final events remain with the old profile.
  const environments = { ...store.value.environments,
    [current]: { ...profile(store.value, current), server: current } };
  await persist(store, { ...destination, server, environments, environmentVersion: 1 });
  return true;
}

export async function saveEnvironmentObsState(store, server, state) {
  // A late recording event from a disconnected controller must never update the
  // new environment's recordings or output ownership.
  if (store.value.server === server) {
    if (store.value.workspaceId !== state.workspaceId) throw new Error('OBS workspace changed unexpectedly.');
    await store.update({ obsState: state });
  } else {
    const saved = store.value.environments?.[server];
    if (!saved || saved.workspaceId !== state.workspaceId) throw new Error('The original OBS environment is unavailable.');
    await store.update({ environments: { ...store.value.environments, [server]: { ...saved, obsState: state } } });
  }
}

export function assertRecoveryEnvironment(recovery, server, pairing) {
  if (recovery.server !== server) throw new Error('This recording recovery belongs to a different environment.');
  if (pairing && (pairing.server !== server || recovery.deviceKey !== pairing.deviceKey ||
      (pairing.matchKind === 'SOLO'
        ? recovery.openQueueGameId !== pairing.matchId || Boolean(recovery.fixtureId)
        : recovery.fixtureId !== pairing.matchId || Boolean(recovery.openQueueGameId)))) {
    throw new Error('This recording recovery belongs to a different paired match. Finish that recovery or explicitly start over.');
  }
}
