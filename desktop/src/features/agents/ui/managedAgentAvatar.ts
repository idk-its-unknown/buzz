type BlobDescriptor = {
  url: string;
  sha256: string;
  size: number;
  type: string;
  uploaded: number;
};

export type UploadMediaBytes = (
  data: number[],
  filename?: string,
) => Promise<BlobDescriptor>;

export async function resolveManagedAgentAvatarUrl(
  avatarUrl: string | null | undefined,
  upload: UploadMediaBytes = defaultUploadMediaBytes,
  fallbackAvatarUrl?: string | null,
): Promise<string | undefined> {
  const resolvedAvatarUrl = avatarUrl?.trim() || undefined;
  if (!resolvedAvatarUrl?.startsWith("data:image/")) {
    return resolvedAvatarUrl;
  }

  // Emoji avatars are stored as inline, percent-encoded SVG data URLs
  // (`data:image/svg+xml,%3C...`) — the same self-contained form profile
  // persists. They are not base64 and must not be run through `atob`/upload;
  // pass them through unchanged so the emoji survives agent creation.
  if (!isBase64DataUri(resolvedAvatarUrl)) {
    return resolvedAvatarUrl;
  }

  try {
    const [, b64] = resolvedAvatarUrl.split(",", 2);
    if (!b64) {
      throw new Error("empty data URI payload");
    }
    const bytes = Array.from(atob(b64), (char) => char.charCodeAt(0));
    const blob = await upload(bytes);
    return blob.url;
  } catch {
    return safeFallbackAvatarUrl(fallbackAvatarUrl);
  }
}

/**
 * Normalize a raw avatar commit value into the stored `avatar_url` shape:
 * whitespace-only and empty commits (AgentCreationPreview signals "clear" by
 * committing "") become null; anything else passes through untrimmed-in-body
 * but with surrounding whitespace removed. Shared by the display-only
 * avatar editor and the e2e bridge mock so both agree with the Rust command.
 */
export function normalizeAvatarUrlInput(
  raw: string | null | undefined,
): string | null {
  const trimmed = raw?.trim();
  return trimmed ? trimmed : null;
}

async function defaultUploadMediaBytes(data: number[], filename?: string) {
  const { uploadMediaBytes } = await import("@/shared/api/tauri");
  return uploadMediaBytes(data, filename);
}

function isBase64DataUri(dataUri: string) {
  const header = dataUri.slice(0, dataUri.indexOf(","));
  return header.includes(";base64");
}

function safeFallbackAvatarUrl(avatarUrl: string | null | undefined) {
  const trimmed = avatarUrl?.trim() || undefined;
  return trimmed?.startsWith("data:image/") ? undefined : trimmed;
}
