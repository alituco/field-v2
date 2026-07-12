type CloudflareError = {
  code?: number;
  message?: string;
};

type CloudflareEnvelope<T> = {
  result: T;
  success: boolean;
  errors?: CloudflareError[];
};

export type CloudflareLiveInput = {
  uid: string;
  enabled?: boolean;
  rtmps: {
    url: string;
    streamKey: string;
  };
};

export type CloudflareLifecycle = {
  isInput: boolean;
  videoUID: string | null;
  live: boolean;
};

export type CloudflareVideo = {
  uid: string;
  created?: string;
  readyToStream?: boolean;
  status?: {
    state?: string;
    errorReasonText?: string;
  };
  playback?: {
    hls?: string;
    dash?: string;
  };
};

type CreateLiveInputOptions = {
  fixtureId: string;
  name: string;
};

export async function createCloudflareLiveInput({
  fixtureId,
  name,
}: CreateLiveInputOptions) {
  return cloudflareRequest<CloudflareLiveInput>("/stream/live_inputs", {
    method: "POST",
    body: JSON.stringify({
      meta: {
        name,
        fixture_id: fixtureId,
      },
      recording: {
        mode: "automatic",
        requireSignedURLs: false,
        timeoutSeconds: 30,
      },
    }),
  });
}

export function getCloudflareLiveInput(inputId: string) {
  return cloudflareRequest<CloudflareLiveInput>(
    `/stream/live_inputs/${encodeURIComponent(inputId)}`,
  );
}

export function setCloudflareLiveInputEnabled(
  inputId: string,
  enabled: boolean,
) {
  return cloudflareRequest<CloudflareLiveInput>(
    `/stream/live_inputs/${encodeURIComponent(inputId)}`,
    {
      method: "PUT",
      body: JSON.stringify({ enabled }),
    },
  );
}

export async function getCloudflareLifecycle(inputId: string) {
  const response = await fetch(
    `${cloudflarePlaybackBaseUrl()}/${encodeURIComponent(inputId)}/lifecycle`,
    { cache: "no-store" },
  );

  if (!response.ok) {
    throw new Error(`Cloudflare lifecycle check failed (${response.status}).`);
  }

  return (await response.json()) as CloudflareLifecycle;
}

export async function getCloudflareVideo(videoId: string) {
  const { accountId, apiToken } = cloudflareConfig();
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountId}/stream/${encodeURIComponent(videoId)}`,
    {
      headers: { Authorization: `Bearer ${apiToken}` },
      cache: "no-store",
    },
  );

  if (response.status === 404) return null;

  const payload = (await response.json()) as CloudflareEnvelope<CloudflareVideo>;
  if (!response.ok || !payload.success) {
    throw cloudflareResponseError(payload.errors, response.status);
  }

  return payload.result;
}

export function listCloudflareLiveInputVideos(inputId: string) {
  return cloudflareRequest<CloudflareVideo[]>(
    `/stream/live_inputs/${encodeURIComponent(inputId)}/videos`,
  );
}

export function cloudflareHlsUrl(uid: string) {
  return `${cloudflarePlaybackBaseUrl()}/${encodeURIComponent(uid)}/manifest/video.m3u8`;
}

function cloudflarePlaybackBaseUrl() {
  const { customerCode } = cloudflareConfig();
  return `https://customer-${customerCode}.cloudflarestream.com`;
}

async function cloudflareRequest<T>(path: string, init: RequestInit = {}) {
  const { accountId, apiToken } = cloudflareConfig();
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountId}${path}`,
    {
      ...init,
      headers: {
        Authorization: `Bearer ${apiToken}`,
        "Content-Type": "application/json",
        ...init.headers,
      },
      cache: "no-store",
    },
  );
  const payload = (await response.json()) as CloudflareEnvelope<T>;

  if (!response.ok || !payload.success) {
    throw cloudflareResponseError(payload.errors, response.status);
  }

  return payload.result;
}

function cloudflareResponseError(
  errors: CloudflareError[] | undefined,
  status: number,
) {
  const message = errors
    ?.map((error) => error.message)
    .filter(Boolean)
    .join(" ");
  return new Error(message || `Cloudflare Stream request failed (${status}).`);
}

function cloudflareConfig() {
  return {
    accountId: requiredEnv("CLOUDFLARE_ACCOUNT_ID"),
    apiToken: requiredEnv("CLOUDFLARE_STREAM_API_TOKEN"),
    customerCode: normalizeCustomerCode(
      requiredEnv("CLOUDFLARE_STREAM_CUSTOMER_CODE"),
    ),
  };
}

function normalizeCustomerCode(value: string) {
  const withoutProtocol = value.trim().replace(/^https?:\/\//i, "");
  const hostname = withoutProtocol.split("/")[0].replace(/\.$/, "");
  const code = hostname
    .replace(/^customer-/i, "")
    .replace(/\.cloudflarestream\.com$/i, "");

  if (!/^[a-z0-9-]+$/i.test(code)) {
    throw new Error("CLOUDFLARE_STREAM_CUSTOMER_CODE is invalid.");
  }
  return code;
}

function requiredEnv(name: string) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is not configured.`);
  return value;
}
