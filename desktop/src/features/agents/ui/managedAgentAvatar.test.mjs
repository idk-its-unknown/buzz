import assert from "node:assert/strict";
import test from "node:test";

import {
  normalizeAvatarUrlInput,
  resolveManagedAgentAvatarUrl,
} from "./managedAgentAvatar.ts";

test("normalizeAvatarUrlInput: empty commit (the clear signal) becomes null", () => {
  assert.equal(normalizeAvatarUrlInput(""), null);
});

test("normalizeAvatarUrlInput: whitespace-only becomes null", () => {
  assert.equal(normalizeAvatarUrlInput("   "), null);
});

test("normalizeAvatarUrlInput: null and undefined pass through as null", () => {
  assert.equal(normalizeAvatarUrlInput(null), null);
  assert.equal(normalizeAvatarUrlInput(undefined), null);
});

test("normalizeAvatarUrlInput: URLs are kept, surrounding whitespace trimmed", () => {
  assert.equal(
    normalizeAvatarUrlInput("  https://relay.example/media/abc.png "),
    "https://relay.example/media/abc.png",
  );
});

test("normalizeAvatarUrlInput: emoji SVG data URLs pass through unchanged", () => {
  const emoji = "data:image/svg+xml,%3Csvg%3E%3C/svg%3E";
  assert.equal(normalizeAvatarUrlInput(emoji), emoji);
});

test("resolveManagedAgentAvatarUrl uploads data image URIs", async () => {
  const uploaded = await resolveManagedAgentAvatarUrl(
    "data:image/png;base64,aGVsbG8=",
    async (bytes) => {
      assert.deepEqual(bytes, [104, 101, 108, 108, 111]);
      return {
        url: "https://relay.example/avatar.png",
        sha256: "hash",
        size: bytes.length,
        type: "image/png",
        uploaded: 1,
      };
    },
  );

  assert.equal(uploaded, "https://relay.example/avatar.png");
});

test("resolveManagedAgentAvatarUrl passes emoji svg data URLs through", async () => {
  const emojiUrl =
    "data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%3C%2Fsvg%3E";
  const uploaded = await resolveManagedAgentAvatarUrl(emojiUrl, async () => {
    throw new Error("should not upload inline emoji svg data URLs");
  });

  assert.equal(uploaded, emojiUrl);
});

test("resolveManagedAgentAvatarUrl passes non-data URLs through", async () => {
  const uploaded = await resolveManagedAgentAvatarUrl(
    " https://relay.example/already-hosted.png ",
    async () => {
      throw new Error("should not upload hosted avatars");
    },
  );

  assert.equal(uploaded, "https://relay.example/already-hosted.png");
});

test("resolveManagedAgentAvatarUrl omits invalid data image URIs", async () => {
  const uploaded = await resolveManagedAgentAvatarUrl(
    "data:image/png;base64,",
    async () => {
      throw new Error("should not upload invalid data URIs");
    },
  );

  assert.equal(uploaded, undefined);
});

test("resolveManagedAgentAvatarUrl uses safe fallback when data image upload fails", async () => {
  const uploaded = await resolveManagedAgentAvatarUrl(
    "data:image/png;base64,YQ==",
    async () => {
      throw new Error("upload failed");
    },
    "app-avatar://goose",
  );

  assert.equal(uploaded, "app-avatar://goose");
});

test("resolveManagedAgentAvatarUrl ignores data URI fallbacks", async () => {
  const uploaded = await resolveManagedAgentAvatarUrl(
    "data:image/png;base64,YQ==",
    async () => {
      throw new Error("upload failed");
    },
    "data:image/png;base64,Yg==",
  );

  assert.equal(uploaded, undefined);
});
