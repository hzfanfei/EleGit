/**
 * IMA ADPCM for call audio sent to the phone: 4 bits a sample instead of 16.
 * 24 kHz PCM16 is 384 kbps; over the tunnel's cross-border leg that stalled for
 * seconds, and the barge state sat behind the queued audio.
 *
 * Packet: "WXA1" | sampleRate u32le | sampleCount u32le | predictor i16le | index u8 | 0 | nibbles (low first)
 */
export const ADPCM_MAGIC = Buffer.from("WXA1", "ascii");
export const ADPCM_HEADER_BYTES = 16;

const INDEX_TABLE = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];
const STEP_TABLE = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107,
  118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
  6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
  32767,
];

function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

/** A packet starts mid-word; from the smallest step the first milliseconds pop. */
function startIndex(pcm, count) {
  const n = Math.min(count - 1, 32);
  if (n <= 0) return 0;
  let sum = 0;
  for (let i = 0; i < n; i += 1) sum += Math.abs(pcm.readInt16LE((i + 1) * 2) - pcm.readInt16LE(i * 2));
  const want = sum / n;
  let index = 0;
  while (index < 88 && STEP_TABLE[index] < want) index += 1;
  return index;
}

/** Encode PCM16 LE into one self-contained packet. */
export function encodeAdpcm(pcm, sampleRate = 24000) {
  const count = pcm.length >> 1;
  const out = Buffer.alloc(ADPCM_HEADER_BYTES + ((count + 1) >> 1));
  ADPCM_MAGIC.copy(out, 0);
  out.writeUInt32LE(sampleRate, 4);
  out.writeUInt32LE(count, 8);
  let predictor = count ? pcm.readInt16LE(0) : 0;
  let index = startIndex(pcm, count);
  out.writeInt16LE(predictor, 12);
  out.writeUInt8(index, 14);
  for (let i = 0; i < count; i += 1) {
    const sample = pcm.readInt16LE(i * 2);
    const step = STEP_TABLE[index];
    let diff = sample - predictor;
    let code = 0;
    if (diff < 0) {
      code = 8;
      diff = -diff;
    }
    let delta = step >> 3;
    if (diff >= step) {
      code |= 4;
      diff -= step;
      delta += step;
    }
    if (diff >= step >> 1) {
      code |= 2;
      diff -= step >> 1;
      delta += step >> 1;
    }
    if (diff >= step >> 2) {
      code |= 1;
      delta += step >> 2;
    }
    predictor = clamp(code & 8 ? predictor - delta : predictor + delta, -32768, 32767);
    index = clamp(index + INDEX_TABLE[code], 0, 88);
    const at = ADPCM_HEADER_BYTES + (i >> 1);
    out[at] |= i & 1 ? code << 4 : code;
  }
  return out;
}

/** Decoder, kept beside the encoder so tests pin the phone's format. */
export function decodeAdpcm(packet) {
  if (!isAdpcmPacket(packet)) return null;
  const sampleRate = packet.readUInt32LE(4);
  const count = packet.readUInt32LE(8);
  let predictor = packet.readInt16LE(12);
  let index = packet.readUInt8(14);
  const pcm = Buffer.alloc(count * 2);
  for (let i = 0; i < count; i += 1) {
    const byte = packet[ADPCM_HEADER_BYTES + (i >> 1)];
    const code = i & 1 ? byte >> 4 : byte & 15;
    const step = STEP_TABLE[index];
    let delta = step >> 3;
    if (code & 4) delta += step;
    if (code & 2) delta += step >> 1;
    if (code & 1) delta += step >> 2;
    predictor = clamp(code & 8 ? predictor - delta : predictor + delta, -32768, 32767);
    index = clamp(index + INDEX_TABLE[code], 0, 88);
    pcm.writeInt16LE(predictor, i * 2);
  }
  return { sampleRate, pcm };
}

export function isAdpcmPacket(buf) {
  return Boolean(buf && buf.length >= ADPCM_HEADER_BYTES && buf.subarray(0, 4).equals(ADPCM_MAGIC));
}
