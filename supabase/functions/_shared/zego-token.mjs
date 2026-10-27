import { Buffer } from "node:buffer";
import { createCipheriv, randomBytes, randomInt } from "node:crypto";
// Token04 wire format: https://github.com/ZEGOCLOUD/zego_server_assistant
// Uses cryptographic randomness and never logs tokens, payloads, or secrets.
export function issueZegoToken(
  {
    appId,
    secret,
    userId,
    roomId,
    host,
    ttl = 600,
    now = Math.floor(Date.now() / 1000),
  },
) {
  if (
    !Number.isSafeInteger(appId) || appId <= 0 ||
    Buffer.byteLength(secret || "") !== 32 || !userId || !roomId || ttl < 60 ||
    ttl > 3600
  ) throw new Error("Invalid streaming token configuration");
  const expires = now + ttl;
  const payload = JSON.stringify({
    room_id: roomId,
    privilege: { 1: 1, 2: host ? 1 : 0 },
    stream_id_list: null,
  });
  const token = JSON.stringify({
    app_id: appId,
    user_id: userId,
    nonce: randomInt(-2147483648, 2147483647),
    ctime: now,
    expire: expires,
    payload,
  });
  const iv = randomBytes(16);
  const cipher = createCipheriv("aes-256-cbc", Buffer.from(secret), iv);
  const encrypted = Buffer.concat([
    cipher.update(token, "utf8"),
    cipher.final(),
  ]);
  const header = Buffer.alloc(10);
  header.writeBigInt64BE(BigInt(expires), 0);
  header.writeUInt16BE(iv.length, 8);
  const size = Buffer.alloc(2);
  size.writeUInt16BE(encrypted.length);
  return "04" + Buffer.concat([header, iv, size, encrypted]).toString("base64");
}
