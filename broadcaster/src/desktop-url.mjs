export function isDesktopDocument(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'fieldrush:' && url.hostname === 'desktop' &&
      !url.port && !url.username && !url.password && !url.search && !url.hash &&
      ['/', '/app.html'].includes(url.pathname);
  } catch { return false; }
}

export function trustedUploadUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.hostname !== 'upload.videodelivery.net' ||
      url.port || url.username || url.password || url.hash || url.pathname === '/') {
    throw new Error('The recording upload destination is not trusted.');
  }
  return url.href;
}

export function recoveryPreviewUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || !/^customer-[a-z0-9-]+\.cloudflarestream\.com$/.test(url.hostname) ||
      url.port || url.username || url.password || url.search || url.hash ||
      !/^\/[A-Za-z0-9_.-]+\/manifest\/video\.m3u8$/.test(url.pathname)) {
    throw new Error('The recording preview is unavailable.');
  }
  // The Stream iframe player works in the browser, unlike a bare HLS manifest.
  url.pathname = url.pathname.replace('/manifest/video.m3u8', '/iframe');
  return url.href;
}
