import { expect, test } from 'bun:test';
import { generateKeyPairSync, sign } from 'node:crypto';
import { renderAppcast, verifyAppcast } from './sparkle-appcast';

test('only the advertised build, repository, exact disk image and embedded public key verify', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const release = { tag: 'v0.8.0-alpha.586', appVersion: '0.8.0', appBuild: '586', minimumMacOS: '14.0',
    updatePublicKey: publicKey.export({ format: 'jwk' }).x!.replace(/-/g, '+').replace(/_/g, '/') + '=' };
  const dmg = Buffer.from('sealed fixture');
  const signature = sign(null, dmg, privateKey).toString('base64');
  const xml = renderAppcast(release, 'owner/computa', dmg.length, signature);
  expect(() => verifyAppcast(xml, dmg, release, 'owner/computa')).not.toThrow();
  expect(() => verifyAppcast(xml, Buffer.from('edited fixture'), release, 'owner/computa')).toThrow();
  expect(() => verifyAppcast(xml, dmg, release, 'other/computa')).toThrow();
  expect(() => verifyAppcast(xml.replace('<sparkle:version>586', '<sparkle:version>999'), dmg, release, 'owner/computa')).toThrow();
  expect(() => verifyAppcast(xml, dmg, { ...release, updatePublicKey: Buffer.alloc(32).toString('base64') }, 'owner/computa')).toThrow();
});
