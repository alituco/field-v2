import test from "node:test";
import assert from "node:assert/strict";
import { ObsController } from "../src/obs-controller.mjs";

const workspaceId = "12345678-1234-1234-1234-123456789abc";
const origin = "https://ops-staging.field.bh";
const startCommand = {
  fixtureId: null, openQueueGameId: "game-1", action: "START_STREAM",
  rtmpsUrl: "rtmps://live.cloudflare.com:443/live/", streamKey: "test-stream-key",
  overlayUrl: `${origin}/broadcast/obs/game-1#token=private-test-token`,
};
const unresolvedRecording = {
  sessionId: "earlier-output-session",
  kind: "match",
  target: { fixtureId: null, openQueueGameId: "earlier-game" },
  recordingDirectory: "/Users/ref/Movies/Fieldrush",
  recordingStartedAt: "2026-10-20T18:00:00.000Z",
  attemptedAt: "2026-10-20T18:00:00.000Z",
  possiblePath: null,
};

class FakeObs {
  constructor() {
    this.calls = [];
    this.profiles = ["Personal"];
    this.collections = ["Personal scenes"];
    this.profile = "Personal";
    this.collection = "Personal scenes";
    this.inputs = [];
    this.scenes = [];
    this.sceneItems = [];
    this.streaming = false;
    this.recording = false;
    this.outputs = [];
    this.handlers = new Map();
    this.devices = { camera: [{ itemName: "DJI Osmo", itemValue: "osmo-usb", itemEnabled: true }],
      mic: [{ itemName: "DJI Microphone", itemValue: "osmo-audio", itemEnabled: true }] };
    this.cameraKinds = ["macos-avcapture", "av_capture_input", "coreaudio_input_capture", "browser_source"];
    this.service = {};
    this.parameters = {};
    this.fail = null;
    this.recordBytes = 8192;
  }
  on(event, handler) { this.handlers.set(event, handler); }
  async connect(...args) { this.connectArgs = args; }
  async disconnect() { this.disconnected = true; }
  async call(type, args) {
    this.calls.push({ type, args: structuredClone(args) });
    if (this.fail === type) throw Object.assign(new Error("Sensitive error with streamKey=private-test-token"), { code: 500 });
    switch (type) {
      case "GetStreamStatus": return { outputActive: this.streaming, outputBytes: 4000, outputDuration: this.streaming ? Date.now() - (this.streamStartedAt ?? Date.now()) : 0 };
      case "GetRecordStatus": return { outputActive: this.recording, outputPaused: false, outputBytes: this.recordBytes, outputDuration: this.recording ? Date.now() - (this.recordStartedAt ?? Date.now()) : 0 };
      case "GetOutputList": return { outputs: [
        ...this.outputs, { outputName: "simple_file_output", outputActive: this.recording },
        { outputName: "simple_stream", outputActive: this.streaming },
      ] };
      case "GetProfileList": return { currentProfileName: this.profile, profiles: this.profiles };
      case "GetSceneCollectionList": return { currentSceneCollectionName: this.collection, sceneCollections: this.collections };
      case "CreateProfile": this.profiles.push(args.profileName); this.profile = args.profileName; return {};
      case "SetCurrentProfile": this.profile = args.profileName; return {};
      case "CreateSceneCollection": this.collections.push(args.sceneCollectionName); this.collection = args.sceneCollectionName; return {};
      case "SetCurrentSceneCollection": this.collection = args.sceneCollectionName; return {};
      case "GetSceneList": return { scenes: this.scenes };
      case "CreateScene": this.scenes.push({ sceneName: args.sceneName }); return {};
      case "GetInputKindList": return { inputKinds: this.cameraKinds };
      case "GetInputList": return { inputs: this.inputs };
      case "CreateInput": this.inputs.push({ inputName: args.inputName, inputKind: args.inputKind, settings: args.inputSettings });
        this.sceneItems.push({ sourceName: args.inputName, sceneItemId: this.sceneItems.length + 1 }); return {};
      case "CreateSceneItem": this.sceneItems.push({ sourceName: args.sourceName, sceneItemId: this.sceneItems.length + 1 }); return {};
      case "GetSceneItemList": return { sceneItems: this.sceneItems };
      case "GetSceneItemId": return { sceneItemId: this.sceneItems.find((item) => item.sourceName === args.sourceName).sceneItemId };
      case "GetSpecialInputs": return { desktop1: "Desktop Audio", desktop2: null, mic1: "Personal Mic", mic2: null, mic3: null, mic4: null };
      case "GetInputPropertiesListPropertyItems": return { propertyItems: args.propertyName === "device" ? this.devices.camera : this.devices.mic };
      case "SetProfileParameter": this.parameters[`${this.profile}/${args.parameterCategory}/${args.parameterName}`] = args.parameterValue; return {};
      case "SetRecordDirectory": this.recordDirectory = args.recordDirectory; return {};
      case "GetRecordDirectory": return { recordDirectory: this.recordDirectory };
      case "SetVideoSettings": this.video = args; return {};
      case "SetInputSettings": Object.assign(this.inputs.find((input) => input.inputName === args.inputName).settings, args.inputSettings); return {};
      case "GetSourceScreenshot": return { imageData: "data:image/jpeg;base64,YWJj" };
      case "SetStreamServiceSettings": this.service = args.streamServiceSettings; return {};
      case "GetStreamServiceSettings": return { streamServiceSettings: this.service };
      case "StartRecord": this.recording = true; this.recordStartedAt = Date.now(); return {};
      case "StopRecord": this.recording = false;
        this.handlers.get("RecordStateChanged")?.({ outputActive: false, outputState: "OBS_WEBSOCKET_OUTPUT_STOPPED", outputPath: "/Users/ref/Movies/Fieldrush/test.mkv" });
        return { outputPath: "/Users/ref/Movies/Fieldrush/test.mkv" };
      case "StartStream": this.streaming = true; this.streamStartedAt = Date.now(); return {};
      case "StopStream": this.streaming = false; return {};
      case "SetInputMute": case "SetInputAudioTracks": case "SetInputAudioMonitorType":
      case "SetSceneItemEnabled": case "SetSceneItemTransform": case "SetSceneItemIndex": case "SetCurrentProgramScene": return {};
      default: throw new Error(`Unexpected mock request ${type}`);
    }
  }
}

async function setup({ configure = true, obs = new FakeObs(), savedState = {}, wait, callTimeoutMs, getProcessIdentity } = {}) {
  const saved = [];
  const controller = new ObsController({ obs, workspaceId, savedState,
    allowedOverlayOrigins: [origin, "http://127.0.0.1:3000"],
    saveState: async (value) => { saved.push(value); }, callTimeoutMs, getProcessIdentity, wait: wait ?? (async () => {}) });
  await controller.connect({ password: "obs-local-test-password" });
  await controller.prepareWorkspace();
  if (configure) await controller.configure({ cameraId: "osmo-usb", microphoneId: "osmo-audio", recordingDirectory: "/Users/ref/Movies/Fieldrush" });
  return { controller, obs, saved };
}

test("connection requires password and numeric loopback, and sanitizes transport failures", async () => {
  const obs = new FakeObs();
  const controller = new ObsController({ obs, workspaceId });
  for (const url of ["ws://remote.example:4455", "ws://localhost:4455", "ws://127.0.0.1:4455/path", "ws://127.0.0.1:4455?token=secret", "wss://127.0.0.1:4455"]) {
    await assert.rejects(controller.connect({ url, password: "secret" }), /local OBS/);
  }
  await assert.rejects(controller.connect({ password: "" }), /password/);
  assert.equal(obs.connectArgs, undefined);
  obs.connect = async () => { throw new Error("do not leak secret"); };
  await assert.rejects(controller.connect({ password: "secret" }), (error) => !error.message.includes("leak"));
});

test("creates a dedicated workspace, detects current and legacy macOS devices, and excludes unavailable/default devices", async () => {
  const { controller, obs } = await setup({ configure: false });
  obs.devices.camera.push({ itemName: "Disconnected", itemValue: "gone", itemEnabled: false });
  obs.devices.mic.push({ itemName: "Default", itemValue: "default", itemEnabled: true });
  const devices = await controller.listDevices();
  assert.deepEqual(devices.cameras, [{ id: "osmo-usb", name: "DJI Osmo", inputKind: "macos-avcapture" }]);
  assert.equal(devices.microphones.length, 1);
  assert.ok(obs.profiles.includes("Personal"));
  assert.ok(obs.collections.includes("Personal scenes"));
  const legacy = new FakeObs();
  legacy.cameraKinds = legacy.cameraKinds.filter((kind) => kind !== "macos-avcapture");
  const legacySetup = await setup({ obs: legacy, configure: false });
  assert.equal((await legacySetup.controller.listDevices()).cameras[0].inputKind, "av_capture_input");
});

test("does not adopt a same-name personal profile or configure while any output is active", async () => {
  const obs = new FakeObs();
  obs.profiles.push(`Fieldrush ${workspaceId}`);
  await assert.rejects(setup({ obs }), /not owned/);
  assert.equal(obs.calls.some((call) => call.type.startsWith("Set") || call.type.startsWith("Create")), false);
  for (const mode of ["recording", "streaming", "virtual"]) {
    const busy = new FakeObs();
    if (mode === "virtual") busy.outputs.push({ outputName: "virtualcam", outputActive: true });
    else busy[mode] = true;
    await assert.rejects(setup({ obs: busy }), /Stop the current OBS output/);
    assert.equal(busy.calls.some((call) => call.type.startsWith("Set") || call.type.startsWith("Create")), false);
  }
});

test("configures 1080p30 H264/AAC, MKV backup and audio isolation without modifying personal profile", async () => {
  const { controller, obs } = await setup();
  assert.equal(obs.video.outputWidth, 1920);
  assert.equal(obs.video.outputHeight, 1080);
  assert.equal(obs.video.fpsNumerator, 30);
  assert.ok(Object.keys(obs.parameters).every((name) => name.startsWith(`Fieldrush ${workspaceId}/`)));
  assert.equal(obs.parameters[`Fieldrush ${workspaceId}/SimpleOutput/RecFormat2`], "mkv");
  assert.equal(obs.parameters[`Fieldrush ${workspaceId}/SimpleOutput/StreamEncoder`], "x264");
  assert.equal(obs.parameters[`Fieldrush ${workspaceId}/SimpleOutput/StreamAudioEncoder`], "aac");
  const lastMutes = new Map(obs.calls.filter((call) => call.type === "SetInputMute").map((call) => [call.args.inputName, call.args.inputMuted]));
  assert.equal(lastMutes.get("Desktop Audio"), true);
  assert.equal(lastMutes.get("Personal Mic"), true);
  assert.equal(lastMutes.get("Fieldrush Camera"), true);
  assert.equal(lastMutes.get("Fieldrush Field Audio"), false);
  assert.equal((await controller.status()).configured, true);
  const writes = obs.calls.findIndex((call) => call.type === "SetProfileParameter");
  assert.ok(obs.calls.slice(writes).some((call) => call.type === "SetCurrentProfile" && call.args.profileName === "Personal"));
});

test("muted audio is explicit and invalid devices/folders cannot change setup", async () => {
  const { controller, obs } = await setup();
  const before = obs.calls.length;
  for (const settings of [
    { cameraId: "gone", microphoneId: null, recordingDirectory: "/Users/ref/Movies" },
    { cameraId: "osmo-usb", microphoneId: "gone", recordingDirectory: "/Users/ref/Movies" },
    { cameraId: "osmo-usb", microphoneId: null, recordingDirectory: "relative" },
  ]) await assert.rejects(controller.configure(settings));
  assert.equal(obs.calls.slice(before).some((call) => call.type.startsWith("Set")), false);
  await controller.configure({ cameraId: "osmo-usb", microphoneId: null, recordingDirectory: "/Users/ref/Movies" });
  assert.equal((await controller.status()).audioMuted, true);
  assert.equal(obs.calls.filter((call) => call.type === "SetInputMute" && call.args.inputName === "Fieldrush Field Audio").at(-1).args.inputMuted, true);
});

test("camera-only preview and microphone meter never expose unrelated screens", async () => {
  const { controller, obs } = await setup();
  assert.equal(await controller.preview(), "data:image/jpeg;base64,YWJj");
  assert.equal(obs.calls.find((call) => call.type === "GetSourceScreenshot").args.sourceName, "Fieldrush Camera");
  obs.handlers.get("InputVolumeMeters")({ inputs: [
    { inputName: "Personal Mic", inputLevelsMul: [[1, 1, 1]] },
    { inputName: "Fieldrush Field Audio", inputLevelsMul: [[0.2, 0.6, 0.4]] },
  ] });
  assert.equal((await controller.status()).audioLevel, 0.6);
});

test("start records before streaming, persists no secret, and repeats without restarting", async () => {
  const { controller, obs, saved } = await setup();
  const status = await controller.start(startCommand);
  assert.equal(status.streaming, true);
  assert.equal(status.recording, true);
  assert.equal(status.currentOpenQueueGameId, "game-1");
  assert.ok(obs.calls.findIndex((call) => call.type === "StartRecord") < obs.calls.findIndex((call) => call.type === "StartStream"));
  assert.equal(JSON.stringify(saved).includes(startCommand.streamKey), false);
  assert.equal(JSON.stringify(saved).includes("private-test-token"), false);
  await controller.start(startCommand);
  assert.equal(obs.calls.filter((call) => call.type === "StartStream").length, 1);
  assert.equal(obs.calls.filter((call) => call.type === "StartRecord").length, 1);
});

test("untrusted command URLs and ambiguous match identity are rejected before mutation", async () => {
  const { controller, obs } = await setup();
  const before = obs.calls.length;
  for (const patch of [
    { fixtureId: "fixture-2" }, { openQueueGameId: null },
    { rtmpsUrl: "rtmp://live.cloudflare.com/live" },
    { rtmpsUrl: "rtmps://user:password@live.cloudflare.com/live" },
    { overlayUrl: "https://evil.example/broadcast" },
    { overlayUrl: `${origin}.evil.example/broadcast` }, { streamKey: "" },
  ]) await assert.rejects(controller.start({ ...startCommand, ...patch }));
  assert.equal(obs.calls.slice(before).some((call) => call.type.startsWith("Set") || call.type.startsWith("Start")), false);
});

test("backup start failure blocks stream and transport errors are sanitized", async () => {
  const { controller, obs } = await setup();
  obs.fail = "StartRecord";
  await assert.rejects(controller.start(startCommand), /OBS could not complete StartRecord/);
  assert.equal(obs.calls.some((call) => call.type === "StartStream"), false);
  obs.fail = null;
  await controller.start(startCommand);
  assert.equal(obs.streaming, true);
});

test("stream failure keeps an owned backup for retry, and missing camera blocks retry", async () => {
  const { controller, obs } = await setup();
  obs.fail = "StartStream";
  await assert.rejects(controller.start(startCommand), /StartStream/);
  assert.equal(obs.recording, true);
  assert.equal((await controller.status()).warnings.some((warning) => warning.includes("backup is recording")), true);
  obs.fail = null;
  obs.devices.camera = [];
  await assert.rejects(controller.start(startCommand), /Reconnect the selected/);
  obs.devices.camera = [{ itemName: "DJI Osmo", itemValue: "osmo-usb", itemEnabled: true }];
  await controller.start(startCommand);
  assert.equal(obs.calls.filter((call) => call.type === "StartRecord").length, 1);
});

test("unrelated stream/recording/plugin outputs cannot be taken over", async () => {
  for (const mode of ["streaming", "recording", "virtual"]) {
    const { controller, obs } = await setup();
    if (mode === "virtual") obs.outputs.push({ outputName: "virtualcam", outputActive: true });
    else obs[mode] = true;
    const before = obs.calls.length;
    await assert.rejects(controller.start(startCommand));
    assert.equal(obs.calls.slice(before).some((call) => call.type.startsWith("Set") || call.type.startsWith("Start") || call.type.startsWith("Stop")), false);
  }
});

test("stop is target-aware and verifies stream destination before stopping any output", async () => {
  const { controller, obs } = await setup();
  await controller.start(startCommand);
  await assert.rejects(controller.stop({ openQueueGameId: "game-other" }), /different match/);
  await assert.rejects(controller.start({ ...startCommand, openQueueGameId: "game-other" }), /current Fieldrush/);
  obs.service.key = "a-different-stream";
  await assert.rejects(controller.stop(startCommand), /different stream destination/);
  assert.equal(obs.streaming, true);
  assert.equal(obs.recording, true);
  obs.service.key = startCommand.streamKey;
  const stopped = await controller.stop(startCommand);
  assert.equal(stopped.streaming, false);
  assert.equal(stopped.recording, false);
  assert.equal(stopped.currentOpenQueueGameId, null);
  assert.equal(stopped.lastRecordingPath, "/Users/ref/Movies/Fieldrush/test.mkv");
  await controller.stop(startCommand);
  assert.equal(obs.calls.filter((call) => call.type === "StopStream").length, 1);
});

test("saved session recovers after restart, but profile switches block stream control", async () => {
  const { controller, obs } = await setup();
  await controller.start(startCommand);
  const restored = new ObsController({ obs, workspaceId, savedState: controller.getState(), allowedOverlayOrigins: [origin] });
  await restored.connect({ password: "test" });
  obs.profile = "Personal";
  await assert.rejects(restored.stopCurrent(), /Select the Fieldrush/);
  assert.equal(obs.streaming, true);
  obs.profile = `Fieldrush ${workspaceId}`;
  await restored.stopCurrent();
  assert.equal(obs.streaming, false);
});

test("local test verifies bytes and produces a file without pairing or streaming", async () => {
  const { controller, obs } = await setup();
  const result = await controller.testRecording(1000);
  assert.equal(result.ok, true);
  assert.equal(result.outputBytes, 8192);
  assert.equal(result.outputPath.endsWith(".mkv"), true);
  assert.equal(obs.calls.some((call) => call.type === "StartStream"), false);
  assert.equal(controller.getState().localTest, false);
  assert.equal(obs.recording, false);
  obs.recordBytes = 0;
  await assert.rejects(controller.testRecording(1000), /usable recording/);
  assert.equal(obs.recording, false);
});

test("local recording test serializes with stream start and never interrupts another active recording", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const { controller, obs } = await setup({ wait: async (ms) => { if (ms === 1000) await gate; } });
  const recording = controller.testRecording(1000);
  const streaming = controller.start(startCommand);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(obs.streaming, false);
  assert.equal(obs.recording, true);
  release();
  await recording;
  await streaming;
  assert.equal(obs.streaming, true);
  await assert.rejects(controller.testRecording(1000), /Finish the current Fieldrush session/);
  assert.equal(obs.streaming, true);
  assert.equal(obs.recording, true);
});

test("private stream tests use blank overlay and separate persistent ownership without match identity", async () => {
  const { controller, obs, saved } = await setup();
  const status = await controller.startTest({ rtmpsUrl: startCommand.rtmpsUrl, streamKey: startCommand.streamKey });
  assert.equal(status.testing, true);
  assert.equal(status.currentOpenQueueGameId, null);
  assert.equal(status.currentFixtureId, null);
  assert.equal(obs.inputs.find((input) => input.inputName === "Fieldrush Scoreboard").settings.url, "about:blank");
  assert.equal(JSON.stringify(saved).includes(startCommand.streamKey), false);
  await assert.rejects(controller.start(startCommand), /Finish the current test/);
  obs.service.key = "unrelated";
  await assert.rejects(controller.stopTest(), /does not belong/);
  assert.equal(obs.streaming, true);
  obs.service.key = startCommand.streamKey;
  const stopped = await controller.stopCurrent();
  assert.equal(stopped.streaming, false);
  assert.equal(stopped.recording, false);
  assert.equal(stopped.testing, false);
});

test("private stream failure preserves its backup for explicit test cleanup", async () => {
  const { controller, obs } = await setup();
  obs.fail = "StartStream";
  await assert.rejects(controller.startTest({ rtmpsUrl: startCommand.rtmpsUrl, streamKey: startCommand.streamKey }), /StartStream/);
  assert.equal(obs.recording, true);
  obs.fail = null;
  await controller.stopTest();
  assert.equal(obs.recording, false);
  assert.equal(controller.getState().testStream, null);
});

test("a failed local recording start can be cleared without stopping unrelated outputs", async () => {
  const { controller, obs } = await setup();
  obs.fail = "StartRecord";
  await assert.rejects(controller.testRecording(1000), /StartRecord/);
  obs.fail = null;
  obs.recording = true;
  await assert.rejects(controller.stopCurrent(), /not owned by the local test/);
  assert.equal(obs.calls.some((call) => call.type === "StopRecord"), false);
  obs.recording = false;
  await controller.stopCurrent();
  assert.equal(controller.getState().localTest, false);
  await controller.start(startCommand);
  assert.equal(obs.streaming, true);
});

test("waits for asynchronous OBS start and stop acknowledgements", async () => {
  const { controller, obs } = await setup();
  const original = obs.call.bind(obs);
  let pendingStart = 0;
  let pendingStop = 0;
  obs.call = async (type, args) => {
    const result = await original(type, args);
    if (type === "StartStream") { obs.streaming = false; pendingStart = 2; }
    if (type === "StopStream") { obs.streaming = true; pendingStop = 2; }
    if (type === "GetStreamStatus" && pendingStart > 0 && --pendingStart === 0) obs.streaming = true;
    if (type === "GetStreamStatus" && pendingStop > 0 && --pendingStop === 0) obs.streaming = false;
    return result;
  };
  await controller.start(startCommand);
  assert.equal(obs.streaming, true);
  await controller.stopCurrent();
  assert.equal(obs.streaming, false);
});

test("persists exact output intents before every start/stop and recovers lost replies without duplicate writes", async () => {
  const { controller, obs, saved } = await setup();
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => {
    const output = type.endsWith("Record") ? "record" : "stream";
    if (["StartRecord", "StartStream", "StopRecord", "StopStream"].includes(type)) {
      const intent = saved.at(-1)[`${output}Intent`];
      assert.equal(intent.action, type.startsWith("Start") ? "start" : "stop");
      assert.equal(intent.owner.workspaceId, workspaceId);
      assert.equal(intent.owner.target.openQueueGameId, "game-1");
      assert.equal(intent.owner.recordingDirectory, "/Users/ref/Movies/Fieldrush");
      assert.equal(typeof intent.owner.digest, "string");
      await original(type, args);
      throw new Error("Transport lost the reply with a sensitive secret");
    }
    return original(type, args);
  };
  await controller.start(startCommand);
  const recordingStartedAt = controller.getState().recordingStartedAt;
  assert.equal(typeof recordingStartedAt, "string");
  assert.equal(controller.getState().recordIntent, null);
  assert.equal(controller.getState().streamIntent, null);
  await controller.stopCurrent();
  const state = controller.getState();
  assert.equal(state.target, null);
  assert.equal(state.recordings.length, 1);
  assert.equal(state.recordings[0].recordingStartedAt, recordingStartedAt);
  assert.equal(state.recordings[0].openQueueGameId, "game-1");
  assert.equal(state.recordings[0].path, "/Users/ref/Movies/Fieldrush/test.mkv");
  assert.ok(state.recordings[0].stoppedAt >= recordingStartedAt);
  for (const type of ["StartRecord", "StartStream", "StopRecord", "StopStream"]) {
    assert.equal(obs.calls.filter((call) => call.type === type).length, 1);
  }
});

test("bounded calls reconcile accepted actions even when OBS never returns the response", async () => {
  const { controller, obs } = await setup({ callTimeoutMs: 5 });
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => {
    const result = await original(type, args);
    if (["StartRecord", "StartStream", "StopRecord", "StopStream"].includes(type)) return new Promise(() => {});
    return result;
  };
  await controller.start(startCommand);
  await controller.stopCurrent();
  assert.equal(controller.getState().recordings.length, 1);
  assert.equal(controller.getState().target, null);
});

test("an uncertain current start remains blocking even with an earlier recovery advisory", async () => {
  const { controller, obs } = await setup({ callTimeoutMs: 5,
    savedState: { workspaceId, unresolvedRecordings: [unresolvedRecording] } });
  const original = obs.call.bind(obs);
  let attempts = 0;
  obs.call = async (type, args) => {
    if (type === "StartRecord") { attempts++; return new Promise(() => {}); }
    return original(type, args);
  };
  await assert.rejects(controller.start(startCommand), /could not complete StartRecord/);
  assert.equal(controller.getState().recordIntent.action, "start");
  const status = await controller.status();
  assert.ok(status.warnings.some(warning => warning.includes("awaiting confirmation")));
  assert.ok(status.advisories.some(advisory => advisory.includes("unconfirmed backup")));
  await assert.rejects(controller.start(startCommand), /no second start/);
  await assert.rejects(controller.stopCurrent(), /not confirmed the earlier start/);
  await assert.rejects(controller.configure({ cameraId: "osmo-usb", microphoneId: null, recordingDirectory: "/Users/ref/Movies" }), /Finish the current Fieldrush session/);
  assert.equal(attempts, 1);
  assert.equal(controller.getState().target.openQueueGameId, "game-1");
  assert.deepEqual(controller.getState().unresolvedRecordings, [unresolvedRecording]);
  assert.equal(obs.calls.some((call) => call.type === "StartStream"), false);
});

test("persisted start intents recover across reconnect only for the exact destination, session and workspace", async () => {
  for (const lostType of ["StartRecord", "StartStream"]) {
    const { controller, obs } = await setup();
    const original = obs.call.bind(obs);
    obs.call = async (type, args) => {
      const result = await original(type, args);
      if (type === lostType) {
        obs.handlers.get("ConnectionClosed")();
        throw new Error("closed after request accepted");
      }
      return result;
    };
    await assert.rejects(controller.start(startCommand));
    const snapshot = controller.getState();
    const intentKey = lostType === "StartRecord" ? "recordIntent" : "streamIntent";
    assert.equal(snapshot[intentKey].action, "start");
    obs.call = original;
    const restored = new ObsController({ obs, workspaceId, savedState: snapshot, allowedOverlayOrigins: [origin] });
    await restored.connect({ password: "test" });
    await assert.rejects(restored.start({ ...startCommand, openQueueGameId: "other" }), /current Fieldrush/);
    obs.profile = "Personal";
    await assert.rejects(restored.start(startCommand), /Select the Fieldrush/);
    obs.profile = `Fieldrush ${workspaceId}`;
    obs.service.key = "foreign";
    await assert.rejects(restored.start(startCommand), /different stream destination/);
    obs.service.key = startCommand.streamKey;
    obs.recordDirectory = "/Users/ref/Movies/Other";
    await assert.rejects(restored.start(startCommand), /different recording folder/);
    obs.recordDirectory = "/Users/ref/Movies/Fieldrush";
    await restored.start(startCommand);
    assert.equal(restored.getState()[intentKey], null);
    assert.equal(obs.calls.filter((call) => call.type === lostType).length, 1);
    await restored.stopCurrent();
  }
});

test("a pending intent cannot adopt an output that predates its attempted start", async () => {
  const { controller, obs } = await setup();
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => {
    const result = await original(type, args);
    if (type === "StartStream") {
      obs.streamStartedAt = Date.now() - 60_000;
      throw new Error("unknown outcome");
    }
    return result;
  };
  await assert.rejects(controller.start(startCommand), /does not match the pending/);
  await assert.rejects(controller.stopCurrent(), /does not match the pending/);
  assert.equal(obs.calls.some((call) => call.type === "StopStream"), false);
  assert.equal(controller.getState().streamingOwned, false);
});

test("record-stop event is persisted after disconnect and recovered into the original match manifest", async () => {
  const { controller, obs } = await setup();
  await controller.start(startCommand);
  const startedAt = controller.getState().recordingStartedAt;
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => {
    const result = await original(type, args);
    if (type === "StopRecord") {
      obs.handlers.get("ConnectionClosed")();
      throw new Error("reply lost after saved-file event");
    }
    return result;
  };
  await assert.rejects(controller.stopCurrent());
  await controller.pending;
  const state = controller.getState();
  assert.equal(state.recordingStoppedEvent.outputPath, "/Users/ref/Movies/Fieldrush/test.mkv");
  assert.equal(state.recordIntent.action, "stop");
  assert.equal(state.target.openQueueGameId, "game-1");
  obs.call = original;
  const restored = new ObsController({ obs, workspaceId, savedState: state, allowedOverlayOrigins: [origin] });
  await restored.connect({ password: "test" });
  await restored.stopCurrent();
  assert.equal(restored.getState().recordings[0].recordingStartedAt, startedAt);
  assert.equal(obs.calls.filter((call) => call.type === "StopRecord").length, 1);
});

test("missing stopped-file path stays recoverable; a late event saves it without queue deadlock", async () => {
  const { controller, obs } = await setup();
  await controller.start(startCommand);
  const event = obs.handlers.get("RecordStateChanged");
  obs.handlers.delete("RecordStateChanged");
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => {
    const result = await original(type, args);
    if (type === "StopRecord") throw new Error("reply and event lost");
    return result;
  };
  await assert.rejects(controller.stopCurrent(), /did not confirm the saved file/);
  assert.equal(controller.getState().recordIntent.action, "stop");
  assert.equal(controller.getState().target.openQueueGameId, "game-1");
  event({ outputActive: false, outputState: "OBS_WEBSOCKET_OUTPUT_STOPPED", outputPath: "/Users/ref/Movies/Foreign/personal.mkv" });
  await controller.pending;
  assert.equal(controller.getState().recordings, undefined);
  event({ outputActive: false, outputState: "OBS_WEBSOCKET_OUTPUT_STOPPED", outputPath: "/Users/ref/Movies/Fieldrush/test.mkv" });
  await controller.pending;
  await controller.stopCurrent();
  assert.equal(controller.getState().recordings.length, 1);
  assert.equal(obs.calls.filter((call) => call.type === "StopRecord").length, 1);
});

test("record events from a different workspace are ignored and a later foreign recording is not adopted", async () => {
  const { controller, obs } = await setup();
  await controller.start(startCommand);
  const event = { outputActive: false, outputState: "OBS_WEBSOCKET_OUTPUT_STOPPED", outputPath: "/Users/ref/Movies/Fieldrush/test.mkv" };
  obs.handlers.get("CurrentProfileChanged")({ profileName: "Personal" });
  obs.handlers.get("RecordStateChanged")(event);
  await controller.pending;
  assert.equal(controller.getState().recordingStoppedEvent, null);
  obs.handlers.get("CurrentProfileChanged")({ profileName: `Fieldrush ${workspaceId}` });
  obs.handlers.get("RecordStateChanged")(event);
  await controller.pending;
  await assert.rejects(controller.start(startCommand), /already stopped/);
  await assert.rejects(controller.stopCurrent(), /already stopped/);
  assert.equal(obs.calls.some((call) => call.type === "StopRecord"), false);
});

test("private/local tests also recover accepted-but-unacknowledged output actions", async () => {
  for (const kind of ["local", "private"]) {
    const { controller, obs } = await setup();
    const original = obs.call.bind(obs);
    obs.call = async (type, args) => {
      const result = await original(type, args);
      if (["StartRecord", "StartStream", "StopRecord", "StopStream"].includes(type)) throw new Error("lost response");
      return result;
    };
    if (kind === "local") await controller.testRecording(1000);
    else {
      await controller.startTest({ rtmpsUrl: startCommand.rtmpsUrl, streamKey: startCommand.streamKey });
      await controller.stopTest();
    }
    assert.equal(obs.recording, false);
    assert.equal(obs.streaming, false);
    assert.equal(controller.getState().outputSessionId, null);
    assert.equal(controller.getState().recordings.length, 0);
  }
});

test("connect and disconnect are bounded even when the local port is not a responding OBS server", async () => {
  const obs = new FakeObs();
  obs.connect = async () => new Promise(() => {});
  obs.disconnect = async () => { obs.disconnected = true; return new Promise(() => {}); };
  const controller = new ObsController({ obs, workspaceId, callTimeoutMs: 5 });
  await assert.rejects(controller.connect({ password: "test" }), /Could not connect/);
  assert.equal(obs.disconnected, true);
  assert.equal(controller.connected, false);
  await assert.rejects(controller.disconnect(), /timed out/);
});

test("explicit Stop can release an unknown start only after a verified OBS process restart with no active outputs", async () => {
  let processIdentity = "obs-pid-101-start-1000";
  const { controller, obs } = await setup({ getProcessIdentity: async () => processIdentity, callTimeoutMs: 5 });
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => type === "StartRecord" ? new Promise(() => {}) : original(type, args);
  await assert.rejects(controller.start(startCommand));
  const attemptedAt = controller.getState().recordIntent.requestedAt;
  await assert.rejects(controller.stopCurrent(), /not confirmed/);
  processIdentity = null;
  await assert.rejects(controller.stopCurrent(), /not confirmed/);
  processIdentity = "obs-pid-102-start-2000";
  // A changed OS process without reconnecting the actual WebSocket is not proof.
  await assert.rejects(controller.stopCurrent(), /not confirmed/);
  await controller.disconnect();
  await controller.connect({ password: "test" });
  obs.streaming = true;
  const writes = obs.calls.filter(call => /^(Start|Stop)/.test(call.type)).length;
  await assert.rejects(controller.stopCurrent(), /restarted OBS still has an active output/);
  assert.equal(obs.calls.filter(call => /^(Start|Stop)/.test(call.type)).length, writes);
  obs.streaming = false;
  const stopped = await controller.stopCurrent();
  const state = controller.getState();
  assert.equal(state.target, null);
  assert.equal(state.recordIntent, null);
  assert.equal(state.outputSessionId, null);
  assert.equal(state.unresolvedRecordings.length, 1);
  assert.deepEqual(state.unresolvedRecordings[0].target, { fixtureId: null, openQueueGameId: "game-1" });
  assert.equal(state.unresolvedRecordings[0].recordingStartedAt, null);
  assert.equal(state.unresolvedRecordings[0].attemptedAt, attemptedAt);
  assert.equal(state.unresolvedRecordings[0].possiblePath, null);
  assert.deepEqual(stopped.warnings, []);
  assert.ok(stopped.advisories.some(advisory => advisory.includes("unconfirmed backup")));
  const recoveryDetails = structuredClone(state.unresolvedRecordings);
  obs.call = original;
  const nextMatch = { ...startCommand, openQueueGameId: "game-2",
    overlayUrl: `${origin}/broadcast/obs/game-2#token=private-test-token` };
  await controller.start(nextMatch);
  assert.equal(obs.streaming, true);
  assert.equal(controller.getState().target.openQueueGameId, "game-2");
  assert.deepEqual(controller.getState().unresolvedRecordings, recoveryDetails);
  await controller.stopCurrent();
  assert.deepEqual(controller.getState().unresolvedRecordings, recoveryDetails);
  assert.equal(controller.getState().recordings[0].openQueueGameId, "game-2");
});

test("historical recovery advisories never hide current camera, microphone, or backup faults", async () => {
  const cases = [
    { fault: ({ obs }) => { obs.devices.camera = []; }, warning: /selected camera is disconnected/ },
    { fault: ({ obs }) => { obs.devices.mic = []; }, warning: /selected microphone is disconnected/ },
    { fault: ({ obs }) => { obs.streaming = true; }, warning: /Streaming without a local backup/ },
    { fault: async ({ controller, obs }) => { await controller.start(startCommand); obs.streaming = false; },
      warning: /local backup is recording, but the stream is offline/ },
  ];
  for (const { fault, warning } of cases) {
    const context = await setup({ savedState: { workspaceId, unresolvedRecordings: [unresolvedRecording] } });
    const healthy = await context.controller.status();
    assert.deepEqual(healthy.warnings, []);
    assert.equal(healthy.advisories.length, 1);
    await fault(context);
    const status = await context.controller.status();
    assert.ok(status.warnings.some(message => warning.test(message)), warning.source);
    assert.equal(status.warnings.some(message => message.includes("earlier OBS session")), false);
    assert.equal(status.advisories.length, 1);
    assert.match(status.advisories[0], /unconfirmed backup/);
    assert.deepEqual(context.controller.getState().unresolvedRecordings, [unresolvedRecording]);
  }
});

test("verified restart preserves metadata for a known-running backup instead of inventing a recovery file", async () => {
  let processIdentity = "obs-pid-101-start-1000";
  const { controller, obs } = await setup({ getProcessIdentity: async () => processIdentity });
  await controller.start(startCommand);
  const startedAt = controller.getState().recordingStartedAt;
  await controller.disconnect();
  obs.streaming = false;
  obs.recording = false;
  processIdentity = "obs-pid-102-start-2000";
  await controller.connect({ password: "test" });
  await controller.stopCurrent();
  const state = controller.getState();
  assert.equal(state.unresolvedRecordings[0].recordingStartedAt, startedAt);
  assert.equal(state.unresolvedRecordings[0].recordingDirectory, "/Users/ref/Movies/Fieldrush");
  assert.equal(state.unresolvedRecordings[0].possiblePath, null);
  assert.equal(state.recordings, undefined);
  assert.equal(state.target, null);
  assert.equal(obs.calls.some(call => call.type === "StopRecord" || call.type === "StopStream"), false);
});

test("verified restart uses a captured stop event to finish the original recording manifest", async () => {
  let processIdentity = "obs-pid-101-start-1000";
  const { controller, obs } = await setup({ getProcessIdentity: async () => processIdentity });
  await controller.start(startCommand);
  const startedAt = controller.getState().recordingStartedAt;
  obs.handlers.get("RecordStateChanged")({ outputActive: false, outputState: "OBS_WEBSOCKET_OUTPUT_STOPPED", outputPath: "/Users/ref/Movies/Fieldrush/test.mkv" });
  obs.handlers.get("ConnectionClosed")();
  await controller.pending;
  obs.streaming = false;
  obs.recording = false;
  processIdentity = "obs-pid-102-start-2000";
  await controller.connect({ password: "test" });
  await controller.stopCurrent();
  assert.equal(controller.getState().recordings[0].recordingStartedAt, startedAt);
  assert.equal(controller.getState().unresolvedRecordings.length, 0);
});

test("unknown local test start can be released after verified restart without fabricating a match", async () => {
  let processIdentity = "obs-pid-101-start-1000";
  const { controller, obs } = await setup({ getProcessIdentity: async () => processIdentity, callTimeoutMs: 5 });
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => type === "StartRecord" ? new Promise(() => {}) : original(type, args);
  await assert.rejects(controller.testRecording(1000));
  await controller.disconnect();
  processIdentity = "obs-pid-102-start-2000";
  await controller.connect({ password: "test" });
  await controller.stopCurrent();
  assert.equal(controller.getState().localTest, false);
  assert.equal(controller.getState().unresolvedRecordings[0].kind, "local-test");
  assert.equal(controller.getState().unresolvedRecordings[0].target, null);
});

test("a WebSocket close code never clears the uncertain output intent as a known OBS rejection", async () => {
  const { controller, obs } = await setup();
  const original = obs.call.bind(obs);
  obs.call = async (type, args) => {
    if (type === "StartRecord") throw Object.assign(new Error("socket closed"), { code: 1006 });
    return original(type, args);
  };
  await assert.rejects(controller.start(startCommand));
  assert.equal(controller.getState().recordIntent.action, "start");
  await assert.rejects(controller.start(startCommand), /no second start/);
});
