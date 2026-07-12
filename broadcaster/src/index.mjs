import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

import dotenv from "dotenv";
import OBSWebSocket from "obs-websocket-js";

dotenv.config({ path: path.resolve(process.cwd(), ".env.local") });

const config = {
  refereeUrl: requiredEnv("FIELD_REFEREE_URL").replace(/\/$/, ""),
  token: requiredEnv("BROADCAST_AGENT_TOKEN"),
  deviceKey: process.env.BROADCAST_DEVICE_KEY?.trim() || "main-pitch",
  deviceName: process.env.BROADCAST_DEVICE_NAME?.trim() || "Main Pitch Camera",
  obsUrl: process.env.OBS_WEBSOCKET_URL?.trim() || "ws://127.0.0.1:4455",
  obsPassword: process.env.OBS_WEBSOCKET_PASSWORD || undefined,
  sceneName: process.env.OBS_SCENE_NAME?.trim() || null,
  overlayInputName:
    process.env.OBS_OVERLAY_INPUT_NAME?.trim() || "Field Scoreboard",
  localRecording:
    (process.env.OBS_ENABLE_LOCAL_RECORDING?.trim().toLowerCase() || "true") ===
    "true",
};

const statePath = path.resolve(process.cwd(), ".field-broadcaster-state.json");
const obs = new OBSWebSocket();
let obsConnected = false;
let shuttingDown = false;
let currentFixtureId = loadState().currentFixtureId ?? null;
let lastError = null;

obs.on("ConnectionClosed", () => {
  obsConnected = false;
});

obs.on("ConnectionError", () => {
  obsConnected = false;
});

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

console.log(`Field broadcaster starting for ${config.deviceName}.`);
console.log("Open OBS and leave this terminal running.");

while (!shuttingDown) {
  try {
    await connectObs();
    const obsStatus = await getObsStatus();
    if (!obsStatus.streaming && currentFixtureId) {
      currentFixtureId = null;
      saveState();
    }

    await sendHeartbeat(obsStatus);
    lastError = null;

    if (obsConnected) {
      const command = await claimCommand();
      if (command) await executeCommand(command);
    }
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    console.error(`[broadcaster] ${lastError}`);
    await sendHeartbeat({ streaming: false }).catch(() => undefined);
  }

  await sleep(2_000);
}

async function connectObs() {
  if (obsConnected) return;
  try {
    await obs.connect(config.obsUrl, config.obsPassword);
    obsConnected = true;
    console.log("Connected to OBS.");
  } catch (error) {
    obsConnected = false;
    throw new Error(
      `Cannot connect to OBS at ${config.obsUrl}. Enable Tools > WebSocket Server Settings. ${
        error instanceof Error ? error.message : ""
      }`.trim(),
    );
  }
}

async function getObsStatus() {
  if (!obsConnected) return { streaming: false };
  const status = await obs.call("GetStreamStatus");
  return { streaming: status.outputActive === true };
}

async function sendHeartbeat(status) {
  await api("/api/broadcast-agent/heartbeat", {
    method: "POST",
    body: JSON.stringify({
      deviceKey: config.deviceKey,
      displayName: config.deviceName,
      obsConnected,
      obsStreaming: status.streaming === true,
      currentFixtureId,
      errorMessage: lastError,
      metadata: {
        agentVersion: "0.1.0",
        hostname: os.hostname(),
        platform: process.platform,
      },
    }),
  });
}

async function claimCommand() {
  const response = await api(
    `/api/broadcast-agent/commands?deviceKey=${encodeURIComponent(config.deviceKey)}`,
  );
  return response.command ?? null;
}

async function executeCommand(command) {
  console.log(`${command.action} requested for fixture ${command.fixtureId}.`);
  try {
    if (command.action === "START_STREAM") {
      await startStream(command);
    } else if (command.action === "STOP_STREAM") {
      await stopStream();
    } else {
      throw new Error(`Unsupported command: ${command.action}`);
    }

    const status = await getObsStatus();
    await acknowledge(command.id, true, null, status.streaming);
    console.log(`${command.action} completed.`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await acknowledge(command.id, false, message, false).catch(() => undefined);
    throw error;
  }
}

async function startStream(command) {
  if (!command.rtmpsUrl || !command.streamKey || !command.overlayUrl) {
    throw new Error("Start command is missing Cloudflare or overlay settings.");
  }

  await obs.call("SetStreamServiceSettings", {
    streamServiceType: "rtmp_custom",
    streamServiceSettings: {
      server: command.rtmpsUrl,
      key: command.streamKey,
      use_auth: false,
    },
  });
  await configureOverlay(command.overlayUrl);

  if (config.localRecording) {
    try {
      const recordStatus = await obs.call("GetRecordStatus");
      if (!recordStatus.outputActive) await obs.call("StartRecord");
    } catch (error) {
      console.warn(
        `Local recording could not start: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  const streamStatus = await obs.call("GetStreamStatus");
  if (!streamStatus.outputActive) await obs.call("StartStream");
  currentFixtureId = command.fixtureId;
  saveState();
}

async function stopStream() {
  const streamStatus = await obs.call("GetStreamStatus");
  if (streamStatus.outputActive) await obs.call("StopStream");

  if (config.localRecording) {
    try {
      const recordStatus = await obs.call("GetRecordStatus");
      if (recordStatus.outputActive) await obs.call("StopRecord");
    } catch (error) {
      console.warn(
        `Local recording could not stop: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  currentFixtureId = null;
  saveState();
}

async function configureOverlay(overlayUrl) {
  const sceneName = config.sceneName ||
    (await obs.call("GetCurrentProgramScene")).currentProgramSceneName;
  const { inputs } = await obs.call("GetInputList", {
    inputKind: "browser_source",
  });
  const existing = inputs.find(
    (input) => input.inputName === config.overlayInputName,
  );
  const inputSettings = {
    url: overlayUrl,
    width: 1920,
    height: 1080,
    fps: 30,
    shutdown: false,
    restart_when_active: true,
    reroute_audio: false,
  };

  if (existing) {
    await obs.call("SetInputSettings", {
      inputName: config.overlayInputName,
      inputSettings,
      overlay: true,
    });
    return;
  }

  await obs.call("CreateInput", {
    sceneName,
    inputName: config.overlayInputName,
    inputKind: "browser_source",
    inputSettings,
    sceneItemEnabled: true,
  });
}

function acknowledge(commandId, ok, errorMessage, obsStreaming) {
  return api("/api/broadcast-agent/commands", {
    method: "POST",
    body: JSON.stringify({ commandId, ok, errorMessage, obsStreaming }),
  });
}

async function api(pathname, init = {}) {
  const response = await fetch(`${config.refereeUrl}${pathname}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${config.token}`,
      "Content-Type": "application/json",
      ...init.headers,
    },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `Field server request failed (${response.status}).`);
  }
  return payload;
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(statePath, "utf8"));
  } catch {
    return {};
  }
}

function saveState() {
  fs.writeFileSync(statePath, JSON.stringify({ currentFixtureId }), {
    mode: 0o600,
  });
}

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  try {
    await obs.disconnect();
  } finally {
    process.exit(0);
  }
}

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is not configured in .env.local.`);
  return value;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
