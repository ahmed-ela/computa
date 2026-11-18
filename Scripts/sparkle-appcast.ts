import { createPublicKey, verify } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { sha256 } from "./package-release";
import { tagMetadata } from "./release-policy";

export interface UpdateRelease { tag: string; appBuild: string; appVersion: string; minimumMacOS: string; updatePublicKey?: string }

export function renderAppcast(release: UpdateRelease, repo: string, size: number, signature: string): string {
  const { tag, appBuild, appVersion, minimumMacOS } = release;
  if (!tagMetadata(tag).prerelease || tag !== `v${appVersion}-alpha.${appBuild}` || !/^\d+\.\d+(\.\d+)?$/.test(minimumMacOS)
    || !/^[\w.-]+\/[\w.-]+$/.test(repo) || !/^[A-Za-z0-9+/]{86}==$/.test(signature)) throw new Error("Invalid appcast metadata");
  const url = `https://github.com/${repo}/releases/download/${tag}/Computa-${tag.slice(1)}-arm64.dmg`;
  return `<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Computa for macOS</title><item><title>Computa ${tag.slice(1)}</title>
<sparkle:version>${appBuild}</sparkle:version><sparkle:shortVersionString>${appVersion}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>${minimumMacOS}</sparkle:minimumSystemVersion>
<enclosure url="${url}" length="${size}" type="application/octet-stream" sparkle:edSignature="${signature}"/>
</item></channel></rss>\n`;
}

export function verifyAppcast(xml: string, dmg: Buffer, release: UpdateRelease, repo: string) {
  const signature = / sparkle:edSignature="([A-Za-z0-9+/]{86}==)"/.exec(xml)?.[1];
  if (!signature || !release.updatePublicKey || !/^[A-Za-z0-9+/]{43}=$/.test(release.updatePublicKey)
    || xml !== renderAppcast(release, repo, dmg.length, signature)) throw new Error("Appcast differs from the expected release");
  const key = createPublicKey({ format: "der", type: "spki", key: Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(release.updatePublicKey, "base64"),
  ]) });
  if (!verify(null, dmg, key, Buffer.from(signature, "base64"))) throw new Error("Update signature does not match the disk image and app key");
}

// Run only after the final DMG has been signed, notarized and stapled. The private key stays in Keychain.
if (import.meta.main) {
  const [signer, file, repo = "ahmed-ela/computa"] = process.argv.slice(2);
  if (!signer || !file) throw new Error("Usage: bun Scripts/sparkle-appcast.ts PATH/TO/sign_update FINAL.dmg [OWNER/REPO]");
  const dmg = resolve(file), directory = dirname(dmg), manifest = dmg.replace(/\.dmg$/, ".manifest.json");
  const release = JSON.parse(await readFile(manifest, "utf8"));
  if (release.channel !== "notarized" || basename(dmg) !== `Computa-${release.tag.slice(1)}-arm64.dmg`) throw new Error("Expected a notarized Computa DMG");
  async function run(command: string[]) {
    const child = Bun.spawn(command, { stdout: "pipe", stderr: "inherit" });
    const output = await new Response(child.stdout).text();
    if (await child.exited !== 0) throw new Error(`${command[0]} failed`);
    return output.trim();
  }
  await run(["xcrun", "stapler", "validate", dmg]);
  await run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg]);
  const bytes = await readFile(dmg), signature = await run([signer, "--account", "com.ahmedelamin.LocalCodex.Sparkle", "-p", dmg]);
  const xml = renderAppcast(release, repo, bytes.length, signature);
  verifyAppcast(xml, bytes, release, repo);
  const appcast = join(directory, "appcast.xml");
  await writeFile(appcast, xml);
  const sums = await Promise.all([dmg, manifest, appcast].map(async path => `${await sha256(path)}  ${basename(path)}`));
  await writeFile(join(directory, "SHA256SUMS"), sums.join("\n") + "\n");
}
