import { createHash, randomUUID } from "node:crypto";
import path from "node:path";

const CAMERA_KINDS = ["macos-avcapture", "av_capture_input"];
const MICROPHONE_KIND = "coreaudio_input_capture";
const PROFILE_SETTINGS = [
  ["Output", "Mode", "Simple"],
  ["Output", "Reconnect", "true"],
  ["Output", "RetryDelay", "2"],
  ["Output", "MaxRetries", "300"],
  ["Output", "DelayEnable", "false"],
  ["Output", "FilenameFormatting", "Fieldrush %CCYY-%MM-%DD %hh-%mm-%ss"],
  ["SimpleOutput", "StreamEncoder", "x264"],
  ["SimpleOutput", "StreamAudioEncoder", "aac"],
  ["SimpleOutput", "VBitrate", "6000"],
  ["SimpleOutput", "ABitrate", "160"],
  ["SimpleOutput", "Preset", "veryfast"],
  ["SimpleOutput", "UseAdvanced", "true"],
  ["SimpleOutput", "x264Settings", "keyint=60"],
  ["SimpleOutput", "VodTrackEnabled", "false"],
  ["SimpleOutput", "RecQuality", "Stream"],
  ["SimpleOutput", "RecFormat2", "mkv"],
  ["SimpleOutput", "RecRB", "false"],
  ["SimpleOutput", "RecTracks", "1"],
  ["Audio", "SampleRate", "48000"],
  ["Audio", "ChannelSetup", "Stereo"],
];
const VIDEO_SETTINGS = {
  baseWidth: 1920, baseHeight: 1080, outputWidth: 1920, outputHeight: 1080,
  fpsNumerator: 30, fpsDenominator: 1,
};

function targetFor(command) {
  const fixtureId = command?.fixtureId || null;
  const openQueueGameId = command?.openQueueGameId || null;
  if (Boolean(fixtureId) === Boolean(openQueueGameId) ||
      (fixtureId && typeof fixtureId !== "string") ||
      (openQueueGameId && typeof openQueueGameId !== "string")) {
    throw new Error("The broadcast command must identify exactly one match.");
  }
  return { fixtureId, openQueueGameId };
}

function sameTarget(a, b) {
  return Boolean(a && b) && a.fixtureId === b.fixtureId &&
    a.openQueueGameId === b.openQueueGameId;
}

function serviceDigest(server, key) {
  return createHash("sha256").update(JSON.stringify([server, key])).digest("hex");
}

function deviceOptions(response, inputKind) {
  const unique = new Map();
  for (const item of response.propertyItems ?? []) {
    if (item.itemEnabled !== false && typeof item.itemValue === "string" &&
        item.itemValue && item.itemValue !== "default" &&
        typeof item.itemName === "string") {
      unique.set(item.itemValue, { id: item.itemValue, name: item.itemName, inputKind });
    }
  }
  return [...unique.values()];
}

/** All mutations are serialized. Inject an OBS client for offline contract tests. */
export class ObsController {
  constructor({ obs = null, workspaceId, savedState = {}, saveState = async () => {},
    allowedOverlayOrigins = [], callTimeoutMs = 15_000,
    getProcessIdentity = async () => null,
    wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) } = {}) {
    if (typeof workspaceId !== "string" || !/^[a-zA-Z0-9-]{8,64}$/.test(workspaceId)) {
      throw new Error("A persistent, unique broadcaster workspace ID is required.");
    }
    this.obs = obs;
    this.workspaceId = workspaceId;
    this.names = {
      profile: `Fieldrush ${workspaceId}`, collection: `Fieldrush ${workspaceId}`,
      reloadProfile: `Fieldrush setup ${workspaceId}`,
      scene: "Fieldrush Match", camera: "Fieldrush Camera",
      microphone: "Fieldrush Field Audio", overlay: "Fieldrush Scoreboard",
    };
    this.state = savedState.workspaceId === workspaceId
      ? structuredClone(savedState) : { workspaceId };
    this.saveState = saveState;
    this.allowedOverlayOrigins = new Set(allowedOverlayOrigins);
    this.connected = false;
    this.pending = Promise.resolve();
    this.audioLevel = null;
    this.audioLevelAt = 0;
    this.boundObs = null;
    this.wait = wait;
    if (!Number.isInteger(callTimeoutMs) || callTimeoutMs < 1 || callTimeoutMs > 60_000) {
      throw new Error("Use a finite OBS request timeout between 1 and 60000 milliseconds.");
    }
    this.callTimeoutMs = callTimeoutMs;
    this.recordingEvents = new Map();
    this.getProcessIdentity = getProcessIdentity;
    this.connectedProcessIdentity = null;
  }

  getState() { return structuredClone(this.state); }

  async connect({ url = "ws://127.0.0.1:4455", password } = {}) {
    const address = new URL(url);
    if (address.protocol !== "ws:" || !["127.0.0.1", "[::1]"].includes(address.hostname) ||
        address.username || address.password || address.pathname !== "/" || address.search ||
        address.hash || typeof password !== "string" || password.length < 1) {
      throw new Error("Use the local OBS WebSocket address and its authentication password.");
    }
    if (!this.obs) {
      const { default: OBSWebSocket } = await import("obs-websocket-js");
      this.obs = new OBSWebSocket();
    }
    if (this.boundObs !== this.obs) {
      this.obs.on?.("ConnectionClosed", () => { this.connected = false; });
      this.obs.on?.("ConnectionError", () => { this.connected = false; });
      this.obs.on?.("CurrentProfileChanged", ({ profileName }) => { this.currentProfileName = profileName; });
      this.obs.on?.("CurrentSceneCollectionChanged", ({ sceneCollectionName }) => { this.currentCollectionName = sceneCollectionName; });
      this.obs.on?.("InputVolumeMeters", ({ inputs }) => {
        const mic = inputs?.find((input) => input.inputName === this.names.microphone);
        if (mic && Array.isArray(mic.inputLevelsMul)) {
          const levels = mic.inputLevelsMul.flat().filter(Number.isFinite);
          this.audioLevel = levels.length ? Math.max(0, Math.min(1, Math.max(...levels))) : 0;
          this.audioLevelAt = Date.now();
        }
      });
      this.obs.on?.("RecordStateChanged", (event) => this._recordingEvent(event));
      this.boundObs = this.obs;
    }
    if (this.connected) return this.status();
    try {
      await this._bounded(this.obs.connect(url, password, { rpcVersion: 1, eventSubscriptions: 2047 | (1 << 16) }), Math.min(this.callTimeoutMs, 10_000));
      this.connected = true;
      this.connectedProcessIdentity = await this._processIdentity();
      return await this.status();
    } catch {
      this.connected = false;
      await this._bounded(this.obs.disconnect(), Math.min(this.callTimeoutMs, 1000)).catch(() => {});
      throw new Error("Could not connect to OBS. Open OBS, enable its WebSocket server and authentication, then check the password.");
    }
  }

  async disconnect() {
    this.connected = false;
    if (this.obs) await this._bounded(this.obs.disconnect(), Math.min(this.callTimeoutMs, 1000));
  }

  _exclusive(operation) {
    const result = this.pending.then(operation);
    this.pending = result.catch(() => {});
    return result;
  }

  async _persist(patch) {
    this.state = { ...this.state, ...patch, workspaceId: this.workspaceId };
    await this.saveState(this.getState());
  }

  async _call(type, args) {
    if (!this.connected) throw new Error("Connect to OBS first.");
    let timer;
    try {
      // obs-websocket-js does not time out requests itself. A timeout says nothing
      // about whether OBS performed a mutation; output intents survive it.
      return await Promise.race([
        this.obs.call(type, args),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), this.callTimeoutMs); }),
      ]);
    } catch (cause) {
      const error = new Error(`OBS could not complete ${type}. Check OBS and try again.`);
      // OBS request rejection codes are below 1000; WebSocket close codes such
      // as 1006 are transport failures, never proof that a mutation was refused.
      error.uncertain = !(Number.isInteger(cause?.code) && cause.code >= 200 && cause.code < 1000);
      throw error;
    } finally { clearTimeout(timer); }
  }

  async _bounded(operation, timeoutMs) {
    let timer;
    try {
      return await Promise.race([operation, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("OBS connection timed out. Check OBS and reconnect.")), timeoutMs);
      })]);
    } finally { clearTimeout(timer); }
  }

  async _processIdentity() {
    try {
      const identity = await this._bounded(Promise.resolve().then(() => this.getProcessIdentity()), Math.min(this.callTimeoutMs, 1000));
      return typeof identity === "string" && identity.length > 0 && identity.length <= 1024 ? identity : null;
    } catch { return null; }
  }

  async _newOutputSession() {
    const processIdentity = await this._processIdentity();
    if (processIdentity && this.connectedProcessIdentity && processIdentity !== this.connectedProcessIdentity) {
      throw new Error("OBS restarted after connecting. Reconnect before starting a session.");
    }
    return { outputSessionId: randomUUID(), outputProcessIdentity: processIdentity,
      recordingStoppedEvent: null, recordingStartedAt: null };
  }

  async _releaseAfterVerifiedRestart() {
    // Only an explicit Stop calls this. The desktop main process obtains this
    // identity from the actual loopback listener's PID, launch time and OBS path.
    // Reconnecting to the same process or clicking a UI assertion is not enough.
    if (!this.state.outputSessionId || !this.state.outputProcessIdentity) return false;
    const current = await this._processIdentity();
    if (!current || current === this.state.outputProcessIdentity || current !== this.connectedProcessIdentity) return false;
    const { stream, record, outputs } = await this._outputs();
    if (stream.outputActive || record.outputActive || outputs.some(output => output.outputActive)) {
      throw new Error("The restarted OBS still has an active output. Stop it in OBS before clearing the previous session.");
    }
    await this._assertWorkspace();
    const owner = this._outputOwner();
    const evidence = this.recordingEvents.get(owner.sessionId) ?? this.state.recordingStoppedEvent;
    let unresolved = this.state.unresolvedRecordings || [];
    const mayHaveRecorded = this._isOutputOwned("record") || this.state.recordIntent || this.state.recordingStartedAt;
    if (mayHaveRecorded) {
      if (evidence?.owner?.sessionId === owner.sessionId && this.state.recordingStartedAt) {
        await this._finishRecording(owner, evidence.outputPath, evidence.stoppedAt);
      } else {
        const recovery = {
          sessionId: owner.sessionId, kind: owner.kind, target: owner.target,
          recordingDirectory: owner.recordingDirectory,
          recordingStartedAt: this.state.recordingStartedAt ?? null,
          attemptedAt: this.state.recordIntent?.requestedAt ?? null,
          possiblePath: evidence?.owner?.sessionId === owner.sessionId ? evidence.outputPath : null,
          savedAt: new Date().toISOString(),
          reason: "OBS restarted before the saved recording could be confirmed. Check the original backup folder before deleting any files.",
        };
        unresolved = [...unresolved.filter(item => item.sessionId !== owner.sessionId), recovery].slice(-100);
      }
    }
    await this._persist({ target: null, testStream: null, localTest: false,
      recordingOwned: false, streamingOwned: false, recordIntent: null, streamIntent: null,
      outputSessionId: null, outputProcessIdentity: null, serviceDigest: null,
      recordingStartedAt: null, recordingStoppedEvent: null, unresolvedRecordings: unresolved });
    return true;
  }

  _outputOwner() {
    const kind = this.state.target ? "match" : this.state.testStream ? "private-test" : this.state.localTest ? "local-test" : null;
    if (!kind || !this.state.outputSessionId) throw new Error("There is no owned Fieldrush output session.");
    return {
      sessionId: this.state.outputSessionId, workspaceId: this.workspaceId, kind,
      target: this.state.target ?? null,
      digest: this.state.testStream?.serviceDigest ?? this.state.serviceDigest ?? null,
      recordingDirectory: this.state.recordingDirectory,
    };
  }

  _sameOwner(owner) {
    try { return JSON.stringify(owner) === JSON.stringify(this._outputOwner()); }
    catch { return false; }
  }

  async _assertOutputDestination(owner, output) {
    if (!this._sameOwner(owner)) throw new Error("This OBS operation belongs to a different Fieldrush session.");
    await this._assertWorkspace();
    const { recordDirectory } = await this._call("GetRecordDirectory");
    if (recordDirectory !== owner.recordingDirectory) {
      throw new Error("OBS is using a different recording folder. Check OBS before continuing.");
    }
    if (owner.kind !== "local-test") {
      const { streamServiceSettings } = await this._call("GetStreamServiceSettings");
      if (serviceDigest(streamServiceSettings.server, streamServiceSettings.key) !== owner.digest) {
        throw new Error(output === "stream" && owner.kind === "private-test"
          ? "The active stream does not belong to this private test. Stop it in OBS."
          : "OBS is using a different stream destination. Stop it in OBS before continuing.");
      }
    }
  }

  _isOutputOwned(output) {
    const property = output === "record" ? "recordingOwned" : "streamingOwned";
    return Boolean(this.state.testStream ? this.state.testStream[property] : this.state[property]);
  }

  async _setOutputOwned(output, owned, patch = {}) {
    const property = output === "record" ? "recordingOwned" : "streamingOwned";
    await this._persist(this.state.testStream
      ? { ...patch, testStream: { ...this.state.testStream, [property]: owned } }
      : { ...patch, [property]: owned });
  }

  _recordingEvent(event) {
    // Capture synchronously, but serialize disk persistence after the operation.
    // Waiting on the mutation queue inside an OBS event handler would deadlock a
    // StopRecord request whose response follows this event.
    if (event?.outputActive !== false || event.outputState !== "OBS_WEBSOCKET_OUTPUT_STOPPED") return;
    if (this.currentProfileName !== this.names.profile || this.currentCollectionName !== this.names.collection) return;
    let owner;
    try { owner = this._outputOwner(); } catch { return; }
    if (!this._isOutputOwned("record") && !this.state.recordIntent) return;
    if (typeof event.outputPath !== "string" || !path.isAbsolute(event.outputPath) ||
        path.dirname(event.outputPath) !== owner.recordingDirectory) return;
    const evidence = { owner, outputPath: event.outputPath, stoppedAt: new Date().toISOString() };
    this.recordingEvents.set(owner.sessionId, evidence);
    this._exclusive(async () => {
      if (!this._sameOwner(owner)) return;
      // Persist the observed path even if the socket closed immediately after the
      // event. It is evidence only; status/destination still gate finalization.
      await this._persist({ recordingStoppedEvent: evidence });
      await this._assertOutputDestination(owner, "record");
      const record = await this._call("GetRecordStatus");
      // A new manually started recording is never adopted as the old one.
      if (!record.outputActive) await this._finishRecording(owner, evidence.outputPath, evidence.stoppedAt);
    }).catch(() => { /* Leave the owning operation/intents intact for explicit recovery. */ });
  }

  async _confirmOutputStarted(output, status, intent) {
    const owner = intent?.owner ?? this._outputOwner();
    await this._assertOutputDestination(owner, output);
    if (!status.outputActive || (output === "record" && status.outputPaused)) {
      throw new Error("The owned OBS output is not running. Check OBS before continuing.");
    }
    // A persisted intent is proof of an attempted start, not proof that an
    // arbitrary already-running output is ours. Its duration must fit that start.
    if (intent && (!Number.isFinite(status.outputDuration) || status.outputDuration < 0 ||
        status.outputDuration > Date.now() - Date.parse(intent.requestedAt) + 2000)) {
      throw new Error("The active OBS output does not match the pending Fieldrush start. Stop it in OBS.");
    }
    if (output === "record" && (this.recordingEvents.has(owner.sessionId) ||
        this.state.recordingStoppedEvent?.owner?.sessionId === owner.sessionId)) {
      throw new Error("The original local backup already stopped. Do not take over this recording; check OBS.");
    }
    await this._setOutputOwned(output, true, {
      [`${output}Intent`]: null,
      ...(output === "record" ? {
        recordingStartedAt: this.state.recordingStartedAt ?? new Date(Date.now() - (status.outputDuration ?? 0)).toISOString(),
      } : {}),
    });
  }

  async _assertOwnedOutput(output, status) {
    const intent = this.state[`${output}Intent`];
    if (!this._isOutputOwned(output)) {
      if (intent?.action !== "start" || !this._sameOwner(intent.owner)) {
        throw new Error(output === "record" ? "The active recording is not owned by this Fieldrush session." : "Refusing to control a stream that is not owned by this Fieldrush match.");
      }
      await this._confirmOutputStarted(output, status, intent);
    } else {
      const owner = this._outputOwner();
      await this._assertOutputDestination(owner, output);
      if (output === "record" && (this.recordingEvents.has(owner.sessionId) ||
          this.state.recordingStoppedEvent?.owner?.sessionId === owner.sessionId)) {
        throw new Error("The original local backup already stopped. Do not take over this recording; check OBS.");
      }
    }
  }

  async _startOutput(output) {
    const owner = this._outputOwner();
    const request = output === "record" ? "GetRecordStatus" : "GetStreamStatus";
    const existing = await this._call(request);
    if (existing.outputActive) { await this._assertOwnedOutput(output, existing); return existing; }
    if (output === "record" && (this.recordingEvents.has(owner.sessionId) ||
        this.state.recordingStoppedEvent?.owner?.sessionId === owner.sessionId)) {
      throw new Error("The local backup already ended. Finish this Fieldrush session before starting a new recording.");
    }
    if (this.state[`${output}Intent`]) {
      throw new Error("An earlier OBS operation has not been confirmed. Check OBS and reconnect before retrying; no second start was sent.");
    }
    await this._assertOutputDestination(owner, output);
    const intent = { action: "start", owner, requestedAt: new Date().toISOString() };
    await this._persist({ [`${output}Intent`]: intent });
    let error;
    try { await this._call(output === "record" ? "StartRecord" : "StartStream"); }
    catch (caught) {
      if (!caught.uncertain) { await this._persist({ [`${output}Intent`]: null }); throw caught; }
      error = caught;
    }
    let started;
    try { started = await this._waitOutput(request, true); }
    catch (caught) { throw error ?? caught; }
    await this._confirmOutputStarted(output, started, intent);
    return started;
  }

  async _finishRecording(owner, outputPath, stoppedAt = new Date().toISOString()) {
    if (!this._sameOwner(owner)) throw new Error("The recording belongs to a different Fieldrush session.");
    const event = this.recordingEvents.get(owner.sessionId) ?? this.state.recordingStoppedEvent;
    outputPath ||= event?.owner?.sessionId === owner.sessionId ? event.outputPath : null;
    if (typeof outputPath !== "string" || !path.isAbsolute(outputPath) || path.dirname(outputPath) !== owner.recordingDirectory) {
      throw new Error("OBS stopped recording but did not confirm the saved file. Keep this session open and recover the recording from OBS before continuing.");
    }
    const manifest = owner.kind === "match" && this.state.recordingStartedAt ? {
      path: outputPath, recordingStartedAt: this.state.recordingStartedAt,
      stoppedAt: event?.stoppedAt ?? stoppedAt, ...owner.target,
    } : null;
    await this._setOutputOwned("record", false, {
      recordIntent: null, recordingStartedAt: null, lastRecordingPath: outputPath,
      recordingStoppedEvent: event ?? { owner, outputPath, stoppedAt },
      recordings: manifest ? [...(this.state.recordings || []).filter(item => item.path !== outputPath), manifest].slice(-100) : this.state.recordings || [],
    });
    return outputPath;
  }

  async _stopOutput(output) {
    const owner = this._outputOwner();
    const request = output === "record" ? "GetRecordStatus" : "GetStreamStatus";
    const status = await this._call(request);
    await this._assertOutputDestination(owner, output);
    if (!status.outputActive) {
      const intent = this.state[`${output}Intent`];
      if (intent?.action === "start") {
        throw new Error("OBS has not confirmed the earlier start. Keep this session open and check OBS; no output was stopped or retried.");
      }
      if (output === "record" && (this._isOutputOwned(output) || intent)) return this._finishRecording(owner);
      await this._setOutputOwned(output, false, { [`${output}Intent`]: null });
      return output === "record" ? this.state.lastRecordingPath : null;
    }
    await this._assertOwnedOutput(output, status);
    await this._persist({ [`${output}Intent`]: { action: "stop", owner, requestedAt: new Date().toISOString() } });
    let result = {}, error;
    try { result = await this._call(output === "record" ? "StopRecord" : "StopStream"); }
    catch (caught) { error = caught; }
    try { await this._waitOutput(request, false); }
    catch (caught) { throw error ?? caught; }
    await this._assertOutputDestination(owner, output);
    if (output === "record") return this._finishRecording(owner, result.outputPath);
    await this._setOutputOwned(output, false, { streamIntent: null });
    return null;
  }

  async _outputs() {
    const stream = await this._call("GetStreamStatus");
    const record = await this._call("GetRecordStatus");
    const { outputs } = await this._call("GetOutputList");
    if (typeof stream.outputActive !== "boolean" || typeof record.outputActive !== "boolean" ||
        !Array.isArray(outputs) || outputs.some((output) => typeof output.outputActive !== "boolean")) {
      throw new Error("OBS returned incomplete output status. Reconnect before continuing.");
    }
    return { stream, record, outputs };
  }

  async _idle() {
    if (this.state.outputSessionId || this.state.recordIntent || this.state.streamIntent) {
      throw new Error("Finish the current Fieldrush session before changing the OBS setup.");
    }
    const state = await this._outputs();
    if (state.stream.outputActive || state.record.outputActive ||
        state.outputs.some((output) => output.outputActive)) {
      throw new Error("Stop the current OBS output before changing the Fieldrush setup.");
    }
  }

  async _waitOutput(request, active) {
    for (let attempt = 0; attempt < 50; attempt++) {
      const output = await this._call(request);
      if (output.outputActive === active) return output;
      await this.wait(200);
    }
    throw new Error(active ? "OBS did not start the output. Check OBS before trying again." : "OBS is still stopping. Try again shortly.");
  }

  async _workspaceCurrent() {
    const profiles = await this._call("GetProfileList");
    this.currentProfileName = profiles.currentProfileName;
    const collections = await this._call("GetSceneCollectionList");
    this.currentCollectionName = collections.currentSceneCollectionName;
    return this.currentProfileName === this.names.profile && this.currentCollectionName === this.names.collection;
  }

  async _assertWorkspace() {
    if (!this.state.profileCreated || !this.state.collectionCreated || !(await this._workspaceCurrent())) {
      throw new Error("Select the Fieldrush OBS profile and scene collection before continuing.");
    }
  }

  prepareWorkspace() { return this._exclusive(() => this._prepareWorkspace()); }

  async _prepareWorkspace() {
    await this._idle();
    const profiles = await this._call("GetProfileList");
    const collections = await this._call("GetSceneCollectionList");
    // A coincidentally named user workspace is never adopted or overwritten.
    if ((profiles.profiles.includes(this.names.profile) && !this.state.profileCreated) ||
        (collections.sceneCollections.includes(this.names.collection) && !this.state.collectionCreated)) {
      throw new Error("This OBS workspace already exists but is not owned by this installation. Choose a new broadcaster workspace.");
    }
    if (!profiles.profiles.includes(this.names.profile)) {
      await this._persist({ previousProfileName: profiles.currentProfileName, configured: false });
      await this._call("CreateProfile", { profileName: this.names.profile });
      await this._persist({ profileCreated: true });
    } else if (profiles.currentProfileName !== this.names.profile) {
      await this._call("SetCurrentProfile", { profileName: this.names.profile });
    }
    if (!collections.sceneCollections.includes(this.names.collection)) {
      await this._call("CreateSceneCollection", { sceneCollectionName: this.names.collection });
      await this._persist({ collectionCreated: true, configured: false });
    } else if (collections.currentSceneCollectionName !== this.names.collection) {
      await this._call("SetCurrentSceneCollection", { sceneCollectionName: this.names.collection });
    }
    const scenes = await this._call("GetSceneList");
    if (!scenes.scenes.some((scene) => scene.sceneName === this.names.scene)) {
      await this._call("CreateScene", { sceneName: this.names.scene });
    }
    const { inputKinds } = await this._call("GetInputKindList", { unversioned: true });
    const cameraKind = CAMERA_KINDS.find((kind) => inputKinds.includes(kind));
    if (!cameraKind || !inputKinds.includes(MICROPHONE_KIND) || !inputKinds.includes("browser_source")) {
      throw new Error("Install the current macOS version of OBS with camera, microphone and browser sources.");
    }
    await this._ensureInput(this.names.camera, cameraKind, { device: "", enable_audio: false });
    await this._ensureInput(this.names.microphone, MICROPHONE_KIND, { device_id: "disabled" });
    await this._ensureInput(this.names.overlay, "browser_source", {
      url: "about:blank", width: 1920, height: 1080, reroute_audio: false,
    });
    await this._silenceUnselectedAudio();
    await this._persist({ cameraKind });
    return this._listDevices();
  }

  async _ensureInput(inputName, inputKind, inputSettings) {
    const { inputs } = await this._call("GetInputList");
    const existing = inputs.find((input) => input.inputName === inputName);
    if (existing && (existing.unversionedInputKind ?? existing.inputKind) !== inputKind) {
      throw new Error(`The ${inputName} source has the wrong type. Recreate the Fieldrush workspace.`);
    }
    if (!existing) {
      await this._call("CreateInput", {
        sceneName: this.names.scene, inputName, inputKind, inputSettings, sceneItemEnabled: true,
      });
    } else {
      const { sceneItems } = await this._call("GetSceneItemList", { sceneName: this.names.scene });
      if (!sceneItems.some((item) => item.sourceName === inputName)) {
        await this._call("CreateSceneItem", { sceneName: this.names.scene, sourceName: inputName, sceneItemEnabled: true });
      }
    }
  }

  listDevices() { return this._exclusive(() => this._listDevices()); }

  async _listDevices() {
    await this._assertWorkspace();
    const cameras = await this._call("GetInputPropertiesListPropertyItems", {
      inputName: this.names.camera, propertyName: "device",
    });
    const microphones = await this._call("GetInputPropertiesListPropertyItems", {
      inputName: this.names.microphone, propertyName: "device_id",
    });
    return {
      cameras: deviceOptions(cameras, this.state.cameraKind),
      microphones: deviceOptions(microphones, MICROPHONE_KIND),
    };
  }

  configure({ cameraId, microphoneId = null, recordingDirectory }) {
    return this._exclusive(async () => {
      if (typeof recordingDirectory !== "string" || !path.isAbsolute(recordingDirectory) ||
          /[\x00-\x1f]/.test(recordingDirectory)) {
        throw new Error("Choose an absolute folder for the local backup recording.");
      }
      await this._idle();
      await this._assertWorkspace();
      const devices = await this._listDevices();
      if (!devices.cameras.some((device) => device.id === cameraId)) {
        throw new Error("The selected camera is unavailable. Connect the Osmo by USB-C and select webcam mode.");
      }
      if (microphoneId !== null && !devices.microphones.some((device) => device.id === microphoneId)) {
        throw new Error("The selected microphone is unavailable. Select an audio input or mute audio.");
      }
      await this._persist({ configured: false });
      for (const [parameterCategory, parameterName, parameterValue] of PROFILE_SETTINGS) {
        await this._call("SetProfileParameter", { parameterCategory, parameterName, parameterValue });
      }
      await this._call("SetRecordDirectory", { recordDirectory: recordingDirectory });
      // SetProfileParameter writes config only. Switching reloads the output encoders.
      const profiles = await this._call("GetProfileList");
      let reloadProfile = this.state.previousProfileName;
      if (!reloadProfile || reloadProfile === this.names.profile || !profiles.profiles.includes(reloadProfile)) {
        reloadProfile = this.names.reloadProfile;
        if (profiles.profiles.includes(reloadProfile) && !this.state.reloadProfileCreated) {
          throw new Error("The Fieldrush setup profile is already in use by another installation.");
        }
        if (!profiles.profiles.includes(reloadProfile)) {
          await this._call("CreateProfile", { profileName: reloadProfile });
          await this._persist({ reloadProfileCreated: true });
        } else await this._call("SetCurrentProfile", { profileName: reloadProfile });
      } else await this._call("SetCurrentProfile", { profileName: reloadProfile });
      await this._call("SetCurrentProfile", { profileName: this.names.profile });
      await this._call("SetVideoSettings", VIDEO_SETTINGS);
      await this._applyDevices(cameraId, microphoneId);
      await this._silenceUnselectedAudio(microphoneId !== null);
      await this._call("SetInputAudioTracks", {
        inputName: this.names.microphone,
        inputAudioTracks: { 1: true, 2: false, 3: false, 4: false, 5: false, 6: false },
      });
      await this._call("SetInputAudioMonitorType", { inputName: this.names.microphone, monitorType: "OBS_MONITORING_TYPE_NONE" });
      await this._configureScene();
      await this._persist({ cameraId, microphoneId, recordingDirectory, configured: true });
      return this.status();
    });
  }

  async _silenceUnselectedAudio(enableMicrophone = false) {
    const special = await this._call("GetSpecialInputs");
    for (const inputName of new Set(Object.values(special).filter((name) => typeof name === "string" && name))) {
      await this._call("SetInputMute", { inputName, inputMuted: true });
    }
    await this._call("SetInputMute", { inputName: this.names.camera, inputMuted: true });
    await this._call("SetInputMute", { inputName: this.names.microphone, inputMuted: !enableMicrophone });
  }

  async _applyDevices(cameraId = this.state.cameraId, microphoneId = this.state.microphoneId) {
    await this._call("SetInputSettings", {
      inputName: this.names.camera,
      inputSettings: { device: cameraId, use_preset: true, preset: "AVCaptureSessionPresetHigh", enable_audio: false },
      overlay: true,
    });
    await this._call("SetInputSettings", {
      inputName: this.names.microphone,
      inputSettings: { device_id: microphoneId ?? "disabled" }, overlay: true,
    });
  }

  async _assertSelectedDevices() {
    const devices = await this._listDevices();
    if (!devices.cameras.some((device) => device.id === this.state.cameraId) ||
        (this.state.microphoneId !== null && !devices.microphones.some((device) => device.id === this.state.microphoneId))) {
      throw new Error("Reconnect the selected camera and microphone before starting.");
    }
  }

  async _configureScene() {
    const { sceneItems } = await this._call("GetSceneItemList", { sceneName: this.names.scene });
    const ownedNames = new Set([this.names.camera, this.names.microphone, this.names.overlay]);
    for (const item of sceneItems) {
      await this._call("SetSceneItemEnabled", {
        sceneName: this.names.scene, sceneItemId: item.sceneItemId,
        sceneItemEnabled: ownedNames.has(item.sourceName),
      });
    }
    for (const inputName of [this.names.camera, this.names.overlay]) {
      const { sceneItemId } = await this._call("GetSceneItemId", { sceneName: this.names.scene, sourceName: inputName });
      await this._call("SetSceneItemTransform", {
        sceneName: this.names.scene, sceneItemId,
        sceneItemTransform: {
          positionX: 0, positionY: 0, rotation: 0, alignment: 5,
          boundsType: "OBS_BOUNDS_SCALE_INNER", boundsAlignment: 0, boundsWidth: 1920, boundsHeight: 1080,
          cropLeft: 0, cropRight: 0, cropTop: 0, cropBottom: 0,
        },
      });
      if (inputName === this.names.overlay) {
        await this._call("SetSceneItemIndex", { sceneName: this.names.scene, sceneItemId, sceneItemIndex: sceneItems.length - 1 });
      }
    }
    await this._call("SetCurrentProgramScene", { sceneName: this.names.scene });
  }

  async status() {
    if (!this.connected) return { connected: false, streaming: false, recording: false, configured: false };
    const { stream, record } = await this._outputs();
    const current = await this._workspaceCurrent();
    // Warnings describe current faults and block remote readiness. Historical
    // recording recovery evidence must stay visible without stranding an
    // otherwise healthy, idle laptop in the server's ERROR state.
    const warnings = [];
    const advisories = [];
    if (!current) warnings.push("Select the Fieldrush OBS profile and scene collection.");
    let cameraAvailable = false;
    let microphoneAvailable = this.state.microphoneId === null;
    if (current && this.state.cameraKind) {
      const devices = await this._listDevices();
      cameraAvailable = devices.cameras.some((device) => device.id === this.state.cameraId);
      microphoneAvailable ||= devices.microphones.some((device) => device.id === this.state.microphoneId);
    }
    if (this.state.configured && !cameraAvailable) warnings.push("The selected camera is disconnected or unavailable.");
    if (this.state.configured && !microphoneAvailable) warnings.push("The selected microphone is disconnected or unavailable.");
    if (this.state.target && !stream.outputActive && record.outputActive) warnings.push("The local backup is recording, but the stream is offline. Retry streaming when the connection returns.");
    if (stream.outputActive && !record.outputActive) warnings.push("Streaming without a local backup. Check recording storage in OBS.");
    if (record.outputActive && record.outputPaused) warnings.push("The local backup is paused. Resume recording in OBS.");
    if (this.state.recordIntent || this.state.streamIntent) warnings.push("An OBS operation is awaiting confirmation. Keep this session open and check OBS before changing setup.");
    if (this.state.unresolvedRecordings?.length) advisories.push("An earlier OBS session has an unconfirmed backup. Check its saved recovery details and original recording folder.");
    return {
      connected: true, streaming: stream.outputActive, recording: record.outputActive,
      testing: this.state.localTest === true || Boolean(this.state.testStream),
      recordingPaused: record.outputPaused === true, reconnecting: stream.outputReconnecting === true,
      configured: this.state.configured === true && current,
      cameraAvailable, microphoneAvailable,
      audioMuted: this.state.microphoneId === null,
      audioLevel: Date.now() - this.audioLevelAt < 3000 ? this.audioLevel : null,
      currentFixtureId: this.state.target?.fixtureId ?? null,
      currentOpenQueueGameId: this.state.target?.openQueueGameId ?? null,
      recordingDirectory: this.state.recordingDirectory ?? null,
      lastRecordingPath: this.state.lastRecordingPath ?? null,
      outputBytes: stream.outputBytes ?? 0,
      droppedFrames: stream.outputSkippedFrames ?? 0,
      totalFrames: stream.outputTotalFrames ?? 0,
      warnings,
      advisories,
    };
  }

  async preview() {
    await this._assertWorkspace();
    const { imageData } = await this._call("GetSourceScreenshot", {
      sourceName: this.names.camera, imageFormat: "jpg", imageWidth: 640, imageCompressionQuality: 70,
    });
    if (typeof imageData !== "string" || !/^data:image\/(jpeg|jpg);base64,[A-Za-z0-9+/=]+$/.test(imageData) || imageData.length > 2_000_000) {
      throw new Error("The camera preview is unavailable.");
    }
    return imageData;
  }

  testRecording(durationMs = 10_000) {
    return this._exclusive(async () => {
      if (!Number.isInteger(durationMs) || durationMs < 1000 || durationMs > 30_000) {
        throw new Error("The camera recording test must last between 1 and 30 seconds.");
      }
      if (!this.state.configured) throw new Error("Finish camera, audio and backup setup first.");
      if (this.state.target || this.state.testStream) throw new Error("Finish the current Fieldrush session before running a local test.");
      await this._idle();
      await this._assertWorkspace();
      await this._assertSelectedDevices();
      await this._applyDevices();
      await this._silenceUnselectedAudio(this.state.microphoneId !== null);
      await this._configureScene();
      await this._call("SetInputSettings", { inputName: this.names.overlay, inputSettings: { url: "about:blank" }, overlay: true });
      await this._persist({ localTest: true, ...await this._newOutputSession() });
      await this._startOutput("record");
      await this.wait(durationMs);
      const recorded = await this._call("GetRecordStatus");
      // Only stop the output in the workspace we started. Never stop a different session.
      await this._assertWorkspace();
      const outputPath = await this._stopOutput("record");
      await this._persist({ localTest: false, recordingOwned: false, outputSessionId: null });
      if (!recorded.outputActive || recorded.outputPaused || !(recorded.outputBytes > 0) || !outputPath) {
        throw new Error("The local recording test did not produce a usable recording. Check the camera and recording folder in OBS.");
      }
      return { ok: true, outputPath, outputBytes: recorded.outputBytes, durationMs };
    });
  }

  /** A private Cloudflare input supplied by the authenticated server; no public match identity. */
  startTest({ rtmpsUrl, streamKey }) {
    return this._exclusive(async () => {
      let server;
      try { server = new URL(rtmpsUrl); } catch { throw new Error("The private test stream settings are invalid."); }
      if (server.protocol !== "rtmps:" || server.username || server.password || server.hash ||
          typeof streamKey !== "string" || !streamKey.trim()) {
        throw new Error("The private test stream settings are invalid.");
      }
      if (!this.state.configured) throw new Error("Finish camera, audio and backup setup first.");
      if (this.state.target || this.state.testStream || this.state.localTest) {
        throw new Error("Finish the current Fieldrush session before running a private stream test.");
      }
      await this._idle();
      await this._assertWorkspace();
      await this._assertSelectedDevices();
      await this._applyDevices();
      await this._silenceUnselectedAudio(this.state.microphoneId !== null);
      await this._configureScene();
      await this._call("SetInputSettings", { inputName: this.names.overlay,
        inputSettings: { url: "about:blank" }, overlay: true });
      await this._call("SetStreamServiceSettings", { streamServiceType: "rtmp_custom",
        streamServiceSettings: { server: rtmpsUrl, key: streamKey, use_auth: false } });
      await this._persist({ testStream: { serviceDigest: serviceDigest(rtmpsUrl, streamKey),
        recordingOwned: false, streamingOwned: false }, ...await this._newOutputSession() });
      const recording = await this._startOutput("record");
      if (recording.outputPaused) throw new Error("The backup recording is paused. Check OBS before testing.");
      await this._startOutput("stream");
      return this.status();
    });
  }

  stopTest() { return this._exclusive(() => this._stopTest()); }

  async _stopTest() {
    if (!this.state.testStream || this.state.target) throw new Error("There is no private stream test to stop.");
    await this._assertWorkspace();
    if (await this._releaseAfterVerifiedRestart()) return this.status();
    await this._stopOutput("stream");
    await this._stopOutput("record");
    await this._persist({ testStream: null, outputSessionId: null });
    return this.status();
  }

  start(command) { return this._exclusive(() => this._start(command)); }

  async _start(command) {
    const target = targetFor(command);
    let server, overlay;
    try { server = new URL(command.rtmpsUrl); overlay = new URL(command.overlayUrl); }
    catch { throw new Error("The broadcast command has invalid stream settings."); }
    if (server.protocol !== "rtmps:" || server.username || server.password || server.hash ||
        !this.allowedOverlayOrigins.has(overlay.origin) || overlay.username || overlay.password ||
        !["https:", "http:"].includes(overlay.protocol) ||
        (overlay.protocol === "http:" && !["127.0.0.1", "localhost", "[::1]"].includes(overlay.hostname)) ||
        typeof command.streamKey !== "string" || !command.streamKey.trim()) {
      throw new Error("The broadcast command has invalid or untrusted stream settings.");
    }
    if (!this.state.configured) throw new Error("Finish camera, audio and backup setup before streaming.");
    if (this.state.testStream || this.state.localTest) throw new Error("Finish the current test before starting a match stream.");
    await this._assertWorkspace();
    const { stream, record, outputs } = await this._outputs();
    if (this.state.target && !sameTarget(this.state.target, target)) {
      throw new Error("Finish the current Fieldrush broadcast before starting another match.");
    }
    const digest = serviceDigest(command.rtmpsUrl, command.streamKey);
    if (this.state.target && this.state.serviceDigest !== digest) {
      throw new Error("This match has different stream credentials. Stop the current stream first.");
    }
    if (this.state.streamIntent?.action === "stop" || this.state.recordIntent?.action === "stop") {
      throw new Error("Finish stopping the current Fieldrush session before starting again.");
    }
    if (stream.outputActive) {
      await this._assertOwnedStream(target, stream);
      if (this.state.serviceDigest !== digest) throw new Error("This match has different stream credentials. Stop the current stream first.");
      if (!record.outputActive || record.outputPaused) throw new Error("The stream is active without its owned, running backup. Check OBS before continuing.");
      await this._assertOwnedOutput("record", record);
      return this.status();
    }
    if (record.outputActive) {
      if (!sameTarget(this.state.target, target)) throw new Error("OBS is recording outside this Fieldrush session. Stop that recording before continuing.");
      await this._assertOwnedOutput("record", record);
    }
    if (this.state.streamIntent || (this.state.recordIntent && !record.outputActive)) {
      throw new Error("An earlier OBS operation has not been confirmed. Check OBS and reconnect before retrying; no second start was sent.");
    }
    // Reject virtual camera, replay buffer, or plugin outputs; they are not ours.
    if (outputs.some((output) => output.outputActive &&
        !(record.outputActive && this.state.recordingOwned && ["simple_file_output", "adv_file_output"].includes(output.outputName)))) {
      throw new Error("Another OBS output is active. Stop it before starting Fieldrush.");
    }
    await this._assertSelectedDevices();
    await this._applyDevices();
    await this._silenceUnselectedAudio(this.state.microphoneId !== null);
    await this._configureScene();
    await this._call("SetInputSettings", {
      inputName: this.names.overlay,
      inputSettings: { url: command.overlayUrl, width: 1920, height: 1080, fps: 30,
        shutdown: false, restart_when_active: true, reroute_audio: false }, overlay: true,
    });
    await this._call("SetStreamServiceSettings", {
      streamServiceType: "rtmp_custom",
      streamServiceSettings: { server: command.rtmpsUrl, key: command.streamKey, use_auth: false },
    });
    await this._persist({ target, serviceDigest: digest, streamingOwned: false,
      ...(!this.state.target ? await this._newOutputSession() : {}) });
    if (!record.outputActive) {
      const started = await this._startOutput("record");
      if (!started.outputActive || started.outputPaused) throw new Error("The local backup did not start. Check recording storage in OBS before streaming.");
    }
    const started = await this._startOutput("stream");
    if (!started.outputActive) throw new Error("The stream did not start. Your local backup remains recording; check the connection and retry.");
    await this._persist({ streamingOwned: true });
    return this.status();
  }

  async _assertOwnedStream(target, status) {
    if (!sameTarget(this.state.target, target)) {
      throw new Error("Refusing to control a stream that is not owned by this Fieldrush match.");
    }
    await this._assertOwnedOutput("stream", status ?? await this._call("GetStreamStatus"));
  }

  stop(command) { return this._exclusive(() => this._stop(targetFor(command))); }
  stopCurrent() {
    return this._exclusive(async () => {
      if (this.state.testStream) return this._stopTest();
      if (this.state.localTest && !this.state.target) {
        await this._assertWorkspace();
        if (await this._releaseAfterVerifiedRestart()) return this.status();
        const { stream, record } = await this._outputs();
        if (stream.outputActive) throw new Error("Another stream is active. Stop it in OBS before ending the local test.");
        if (record.outputActive && !this.state.recordingOwned && !this.state.recordIntent) throw new Error("The active recording is not owned by the local test. Stop it in OBS.");
        await this._stopOutput("record");
        await this._persist({ localTest: false, recordingOwned: false, outputSessionId: null });
        return this.status();
      }
      if (!this.state.target) throw new Error("There is no Fieldrush broadcast to stop.");
      return this._stop(this.state.target);
    });
  }

  async _stop(target) {
    const { stream, record } = await this._outputs();
    if (!sameTarget(this.state.target, target)) {
      if (!stream.outputActive && !record.outputActive && !this.state.target) return this.status();
      throw new Error("This stop command belongs to a different match.");
    }
    await this._assertWorkspace();
    if (await this._releaseAfterVerifiedRestart()) return this.status();
    await this._stopOutput("stream");
    await this._stopOutput("record");
    await this._persist({ target: null, serviceDigest: null, streamingOwned: false, recordingOwned: false, outputSessionId: null });
    return this.status();
  }
}
