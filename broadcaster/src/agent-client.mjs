import { randomBytes } from 'node:crypto';

export function serverOrigin(value, development = false) {
  const parsed = new URL(value);
  const allowed = parsed.origin === 'https://ops-staging.field.bh' ||
    (development && ['http://127.0.0.1:3000', 'http://localhost:3000'].includes(parsed.origin));
  if (!allowed || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) {
    throw new Error('Choose the Fieldrush staging server or the local development server.');
  }
  return parsed.origin;
}

export function safeMessage(error) {
  const text = error instanceof Error ? error.message : String(error);
  return text.replace(/(?:https?|rtmps?|wss?):\/\/\S+/gi, '[connection]')
    .replace(/[A-Za-z0-9_-]{40,}/g, '[private value]').slice(0, 250);
}

export class AgentClient {
  constructor({ store, obs, onChange = () => {}, fetcher = fetch, development = false, now = () => Date.now() }) {
    Object.assign(this, { store, obs, onChange, fetcher, development, now });
    this.running = false;
    this.busy = false;
    this.session = null;
    this.error = null;
    this.reachable = false;
    this.timer = null;
  }
  async request(path, { method = 'GET', body, token = this.store.value.pairing?.token } = {}) {
    const origin = serverOrigin(this.store.value.server, this.development);
    const response = await this.fetcher(origin + path, {
      method, redirect: 'error', signal: AbortSignal.timeout(10_000),
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const text = await response.text();
    const responseError = message => Object.assign(new Error(message), { status: response.status });
    if (text.length > 100_000) throw responseError('Fieldrush returned an invalid response.');
    let data;
    try { data = JSON.parse(text); } catch {
      if (response.status === 404 && path.startsWith('/api/broadcast-agent/')) {
        throw responseError('Broadcaster support is not deployed on the selected server. Update the referee server or use Local development for local testing.');
      }
      throw responseError('Fieldrush is unavailable. Try again shortly.');
    }
    if (!response.ok) {
      const error = new Error(typeof data.error === 'string' ? safeMessage(data.error) : `Fieldrush request failed (${response.status}).`);
      error.status = response.status;
      throw error;
    }
    return data;
  }
  async pair(code, displayName) {
    if (this.busy) throw new Error('Wait for the current camera operation to finish.');
    const status = await this.obs.status();
    const owned = this.obs.getState?.() || {};
    if (!status.connected && (owned.target || owned.testStream || owned.localTest || owned.recordingOwned || owned.streamingOwned)) throw new Error('Reconnect OBS and confirm it is stopped before pairing another match.');
    if (owned.target || owned.testStream || owned.localTest) throw new Error('Clear the previous camera session with Stop video and recording before pairing another match.');
    if (status.streaming || status.recording) throw new Error('Stop streaming and recording before pairing another match.');
    const normalized = String(code).toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (normalized.length !== 12) throw new Error('Enter the 12-character code shown on your match page.');
    if (typeof displayName !== 'string' || displayName.trim().length < 2 || displayName.trim().length > 80) throw new Error('Give this laptop a name between 2 and 80 characters.');
    const pending = this.store.value.pendingPair;
    const token = pending?.code === normalized ? pending.token : randomBytes(32).toString('base64url');
    // Save before issuing the request: retrying a lost response uses the same credential.
    await this.store.update({ pendingPair: { code: normalized, token } });
    const result = await this.request('/api/broadcast-agent/pair', { method: 'POST', token: null, body: { code: normalized, displayName: displayName.trim(), deviceToken: token } });
    this.validateSession(result);
    await this.store.update({ pairing: { ...result, token }, pendingPair: null, pendingAck: null, lastCommand: null, lastStreamTest: null });
    this.session = result;
    this.error = null;
    return this.publicSession();
  }
  validateSession(session) {
    if (!session || typeof session.deviceKey !== 'string' || !session.deviceKey ||
        !['SOLO', 'CLAN'].includes(session.matchKind) || !/^[0-9a-f-]{36}$/i.test(session.matchId ?? '') ||
        !Number.isFinite(Date.parse(session.expiresAt)) || Date.parse(session.expiresAt) <= this.now()) {
      throw new Error('The laptop pairing is invalid or expired. Create a new code from the match page.');
    }
    const paired = this.store.value.pairing;
    if (paired && session.deviceKey === paired.deviceKey && (session.matchId !== paired.matchId || session.matchKind !== paired.matchKind)) {
      throw new Error('The paired match changed unexpectedly. Pair this laptop again.');
    }
  }
  publicSession() {
    const paired = this.session ?? this.store.value.pairing;
    if (!paired) return null;
    const { deviceKey, displayName, matchId, matchKind, matchLabel, venue, startsAt, expiresAt, refereeName } = paired;
    return { deviceKey, displayName, matchId, matchKind, matchLabel, venue, startsAt, expiresAt, refereeName };
  }
  start() {
    if (this.running) return;
    this.running = true;
    void this.loop();
  }
  stop() { this.running = false; clearTimeout(this.timer); }
  async loop() {
    if (!this.running) return;
    await this.tick();
    if (this.running) this.timer = setTimeout(() => void this.loop(), 2_000);
  }
  async tick() {
    if (this.busy || !this.store.value.pairing) return;
    this.busy = true;
    try {
      const paired = this.store.value.pairing;
      if (Date.parse(paired.expiresAt) <= this.now()) {
        const error = new Error('Pairing expired. Get a new code from the match page.');
        error.status = 401;
        throw error;
      }
      const session = await this.request('/api/broadcast-agent/session');
      this.validateSession(session);
      if (session.deviceKey !== paired.deviceKey || session.matchKind !== paired.matchKind || session.matchId !== paired.matchId) throw new Error('Pairing did not match this laptop.');
      this.session = session;
      this.reachable = true;
      const status = await this.obs.status();
      await this.request('/api/broadcast-agent/heartbeat', { method: 'POST', body: {
        deviceKey: paired.deviceKey, displayName: paired.displayName,
        obsConnected: status.connected === true && status.configured === true && status.cameraAvailable !== false && status.microphoneAvailable !== false,
        obsStreaming: status.streaming === true,
        currentFixtureId: status.currentFixtureId ?? null,
        currentOpenQueueGameId: status.currentOpenQueueGameId ?? null,
        errorMessage: status.error ? safeMessage(status.error) : status.warnings?.length ? safeMessage(status.warnings.join(' ')) : null,
        metadata: { agentVersion: '0.2.0', platform: 'darwin', recording: status.recording === true, configured: status.configured === true },
      } });
      const pending = this.store.value.pendingAck;
      if (pending) {
        await this.acknowledge(pending);
        await this.store.update({ pendingAck: null });
      }
      if (status.connected) {
        const result = await this.request(`/api/broadcast-agent/commands?deviceKey=${encodeURIComponent(paired.deviceKey)}`);
        if (result.command) await this.execute(result.command);
      }
      this.error = null;
    } catch (error) {
      this.error = safeMessage(error);
      this.reachable = false;
      if ([401, 403].includes(error.status)) {
        // Revoked devices stop transmitting. A network failure alone never stops
        // local recording or affects the referee's match clock.
        try { await this.obs.stopCurrent(); } catch { this.error += ' Stop OBS manually if it is still broadcasting.'; }
        this.stop();
        this.session = null;
        await this.store.update({ pairing: null, pendingAck: null });
      }
    } finally {
      this.busy = false;
      this.onChange();
    }
  }
  async execute(command) {
    const paired = this.store.value.pairing;
    const expectedFixture = paired.matchKind === 'CLAN' ? paired.matchId : null;
    const expectedSolo = paired.matchKind === 'SOLO' ? paired.matchId : null;
    if (!command.id || !['START_STREAM', 'STOP_STREAM'].includes(command.action) ||
        (command.fixtureId ?? null) !== expectedFixture || (command.openQueueGameId ?? null) !== expectedSolo) {
      throw new Error('Ignored a camera command for a different match.');
    }
    if (this.store.value.lastCommand?.commandId === command.id) {
      await this.acknowledge(this.store.value.lastCommand);
      return;
    }
    let result;
    try {
      if (command.action === 'START_STREAM') { await this.beforeStart?.(); await this.obs.start(command); }
      else await this.obs.stop(command);
      const status = await this.obs.status();
      result = { commandId: command.id, ok: true, errorMessage: null, obsStreaming: status.streaming === true };
    } catch (error) {
      result = { commandId: command.id, ok: false, errorMessage: safeMessage(error), obsStreaming: (await this.obs.status()).streaming === true };
    }
    // Persist the outcome BEFORE acknowledgment. Lost acknowledgments must never
    // execute an already-applied start/stop a second time after restart.
    await this.store.update({ pendingAck: result, lastCommand: result });
    await this.acknowledge(result);
    await this.store.update({ pendingAck: null });
    if (!result.ok) throw new Error(result.errorMessage);
  }
  acknowledge(result) { return this.request('/api/broadcast-agent/commands', { method: 'POST', body: result }); }
}
