// A sync word alone also occurs in ordinary PCM16 samples.
export function looksLikeMp3(bytes) {
  if (!bytes) return false;
  if (bytes.length >= 10 && bytes[0] === 0x49 && bytes[1] === 0x44 &&
      bytes[2] === 0x33 && bytes[3] >= 2 && bytes[3] <= 4 &&
      bytes[4] !== 0xff && bytes.subarray(6, 10).every(b => b < 128)) return true;
  function frameLength(offset) {
    if (offset + 4 > bytes.length) return 0;
    const b = bytes[offset + 1], c = bytes[offset + 2];
    const version = (b >> 3) & 3, bitrate = c >> 4, rateIndex = (c >> 2) & 3;
    if (bytes[offset] !== 0xff || (b & 0xe0) !== 0xe0 || version === 1 ||
        ((b >> 1) & 3) !== 1 || bitrate === 0 || bitrate === 15 || rateIndex === 3) return 0;
    const rates = version === 3
      ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
      : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    const rate = [44100, 48000, 32000][rateIndex] / (version === 3 ? 1 : version === 2 ? 2 : 4);
    return Math.floor((version === 3 ? 144000 : 72000) * rates[bitrate] / rate) + ((c >> 1) & 1);
  }
  const first = frameLength(0);
  if (!first) return false;
  const second = frameLength(first);
  return second > 0 && first + second <= bytes.length &&
    (bytes[1] & 0x1e) === (bytes[first + 1] & 0x1e) &&
    (bytes[2] & 0x0c) === (bytes[first + 2] & 0x0c);
}
