import { timingSafeEqual } from "node:crypto";

const POLY1305_MODULUS = (1n << 130n) - 5n;
const POLY1305_R_MASK = 0x0ffffffc0ffffffc0ffffffc0fffffffn;
const UINT128_MASK = (1n << 128n) - 1n;

export function chacha20Poly1305Seal(
  key: Uint8Array,
  nonce: Uint8Array,
  plaintext: Uint8Array,
  additionalData: Uint8Array,
): Buffer {
  validateInputs(key, nonce);
  const oneTimeKey = chacha20Block(key, 0, nonce).subarray(0, 32);
  const ciphertext = chacha20Xor(key, nonce, plaintext, 1);
  const tag = poly1305Tag(oneTimeKey, macInput(additionalData, ciphertext));
  return Buffer.concat([ciphertext, tag]);
}

export function chacha20Poly1305Open(
  key: Uint8Array,
  nonce: Uint8Array,
  ciphertextAndTag: Uint8Array,
  additionalData: Uint8Array,
): Buffer | undefined {
  validateInputs(key, nonce);
  if (ciphertextAndTag.length < 16) return undefined;
  const ciphertext = Buffer.from(
    ciphertextAndTag.subarray(0, ciphertextAndTag.length - 16),
  );
  const suppliedTag = Buffer.from(
    ciphertextAndTag.subarray(ciphertextAndTag.length - 16),
  );
  const oneTimeKey = chacha20Block(key, 0, nonce).subarray(0, 32);
  const expectedTag = poly1305Tag(
    oneTimeKey,
    macInput(additionalData, ciphertext),
  );
  if (!timingSafeEqual(suppliedTag, expectedTag)) return undefined;
  return chacha20Xor(key, nonce, ciphertext, 1);
}

function validateInputs(key: Uint8Array, nonce: Uint8Array) {
  if (key.length !== 32)
    throw new Error("ChaCha20-Poly1305 key must be 32 bytes");
  if (nonce.length !== 12)
    throw new Error("ChaCha20-Poly1305 nonce must be 12 bytes");
}

function chacha20Xor(
  key: Uint8Array,
  nonce: Uint8Array,
  input: Uint8Array,
  initialCounter: number,
): Buffer {
  const blocks = Math.ceil(input.length / 64);
  if (blocks > 0xffffffff - initialCounter + 1) {
    throw new Error("ChaCha20 counter capacity exceeded");
  }
  const output = Buffer.allocUnsafe(input.length);
  for (let blockIndex = 0; blockIndex < blocks; blockIndex += 1) {
    const stream = chacha20Block(key, initialCounter + blockIndex, nonce);
    const offset = blockIndex * 64;
    const length = Math.min(64, input.length - offset);
    for (let index = 0; index < length; index += 1) {
      output[offset + index] =
        readByte(input, offset + index) ^ readByte(stream, index);
    }
  }
  return output;
}

function chacha20Block(
  key: Uint8Array,
  counter: number,
  nonce: Uint8Array,
): Buffer {
  const state = new Uint32Array(16);
  state.set([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]);
  const keyView = new DataView(key.buffer, key.byteOffset, key.byteLength);
  const nonceView = new DataView(
    nonce.buffer,
    nonce.byteOffset,
    nonce.byteLength,
  );
  for (let index = 0; index < 8; index += 1)
    state[4 + index] = keyView.getUint32(index * 4, true);
  state[12] = counter >>> 0;
  state[13] = nonceView.getUint32(0, true);
  state[14] = nonceView.getUint32(4, true);
  state[15] = nonceView.getUint32(8, true);

  const working = new Uint32Array(state);
  for (let round = 0; round < 10; round += 1) {
    quarterRound(working, 0, 4, 8, 12);
    quarterRound(working, 1, 5, 9, 13);
    quarterRound(working, 2, 6, 10, 14);
    quarterRound(working, 3, 7, 11, 15);
    quarterRound(working, 0, 5, 10, 15);
    quarterRound(working, 1, 6, 11, 12);
    quarterRound(working, 2, 7, 8, 13);
    quarterRound(working, 3, 4, 9, 14);
  }

  const output = Buffer.allocUnsafe(64);
  for (let index = 0; index < 16; index += 1) {
    output.writeUInt32LE(
      (word(working, index) + word(state, index)) >>> 0,
      index * 4,
    );
  }
  return output;
}

function quarterRound(
  state: Uint32Array,
  a: number,
  b: number,
  c: number,
  d: number,
) {
  state[a] = (word(state, a) + word(state, b)) >>> 0;
  state[d] = rotateLeft((word(state, d) ^ word(state, a)) >>> 0, 16);
  state[c] = (word(state, c) + word(state, d)) >>> 0;
  state[b] = rotateLeft((word(state, b) ^ word(state, c)) >>> 0, 12);
  state[a] = (word(state, a) + word(state, b)) >>> 0;
  state[d] = rotateLeft((word(state, d) ^ word(state, a)) >>> 0, 8);
  state[c] = (word(state, c) + word(state, d)) >>> 0;
  state[b] = rotateLeft((word(state, b) ^ word(state, c)) >>> 0, 7);
}

function word(state: Uint32Array, index: number): number {
  const value = state[index];
  if (value === undefined) throw new RangeError("ChaCha20 word out of bounds");
  return value;
}

function rotateLeft(value: number, count: number): number {
  return ((value << count) | (value >>> (32 - count))) >>> 0;
}

function macInput(additionalData: Uint8Array, ciphertext: Uint8Array): Buffer {
  const lengths = Buffer.alloc(16);
  lengths.writeBigUInt64LE(BigInt(additionalData.length), 0);
  lengths.writeBigUInt64LE(BigInt(ciphertext.length), 8);
  return Buffer.concat([
    Buffer.from(additionalData),
    Buffer.alloc(paddingLength(additionalData.length)),
    Buffer.from(ciphertext),
    Buffer.alloc(paddingLength(ciphertext.length)),
    lengths,
  ]);
}

function paddingLength(length: number): number {
  return (16 - (length % 16)) % 16;
}

function poly1305Tag(oneTimeKey: Uint8Array, message: Uint8Array): Buffer {
  const r = littleEndianInteger(oneTimeKey.subarray(0, 16)) & POLY1305_R_MASK;
  const s = littleEndianInteger(oneTimeKey.subarray(16, 32));
  let accumulator = 0n;
  for (let offset = 0; offset < message.length; offset += 16) {
    const block = message.subarray(
      offset,
      Math.min(offset + 16, message.length),
    );
    const blockInteger =
      littleEndianInteger(block) + (1n << BigInt(block.length * 8));
    accumulator = ((accumulator + blockInteger) * r) % POLY1305_MODULUS;
  }
  return integerToLittleEndian((accumulator + s) & UINT128_MASK, 16);
}

function littleEndianInteger(bytes: Uint8Array): bigint {
  let value = 0n;
  for (let index = bytes.length - 1; index >= 0; index -= 1) {
    value = (value << 8n) | BigInt(readByte(bytes, index));
  }
  return value;
}

function readByte(bytes: Uint8Array, index: number): number {
  const value = bytes[index];
  if (value === undefined) throw new RangeError("byte index out of bounds");
  return value;
}

function integerToLittleEndian(value: bigint, length: number): Buffer {
  const output = Buffer.allocUnsafe(length);
  let remaining = value;
  for (let index = 0; index < length; index += 1) {
    output[index] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }
  return output;
}
