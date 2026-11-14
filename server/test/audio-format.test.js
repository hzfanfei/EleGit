import test from 'node:test';
import assert from 'node:assert/strict';
import { looksLikeMp3 } from '../src/audio-format.js';

test('PCM samples and isolated sync/header bytes do not select MP3', () => {
  assert.equal(looksLikeMp3(Buffer.from([255, 255, 0, 0])), false);
  const pcm = Buffer.alloc(1000);
  pcm.set([255, 251, 144, 0]);
  assert.equal(looksLikeMp3(pcm), false);
  assert.equal(looksLikeMp3(Buffer.from('ID3')), false);
});
test('recognizes complete consecutive MPEG1 and MPEG2 Layer III frames', () => {
  for (const [b, c, length] of [[251, 144, 417], [243, 128, 208]]) {
    const bytes = Buffer.alloc(length * 2);
    bytes.set([255, b, c, 0]);
    bytes.set([255, b, c, 0], length);
    assert.equal(looksLikeMp3(bytes), true);
    assert.equal(looksLikeMp3(bytes.subarray(0, -1)), false);
  }
});
test('recognizes a valid ID3 header', () => {
  assert.equal(looksLikeMp3(Buffer.from([73, 68, 51, 4, 0, 0, 0, 0, 0, 0])), true);
});
