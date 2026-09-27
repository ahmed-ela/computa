import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// Explicit opt-in: compiles small temporary probes and may use a named existing
// signing identity. Never changes a keychain, app, Chrome session or permission.
const enabled = process.env.MACTOPUS_RUN_SIGNING_TESTS === "1" && process.platform === "darwin";
const appleIdentity = process.env.MACTOPUS_TEST_SIGNING_IDENTITY;
const selfSignedIdentity = process.env.MACTOPUS_TEST_SELF_SIGNED_IDENTITY;
const appID = "com.ahmedelamin.LocalCodex";
const hostID = `${appID}.ChromeBridgeHost`;
const root = resolve(import.meta.dir, "..");
let directory: string | undefined;
let adhocApp: string;
let unsignedApp: string;
let signedApp: string;
let signedHost: string;
let wrongIdentifier: string;
let selfSignedApp: string;
const children: ReturnType<typeof Bun.spawn>[] = [];

async function command(arguments_: string[]) {
  const child = Bun.spawn(arguments_, { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  return { stdout: stdout.trim(), stderr: stderr.trim(), code };
}

async function checked(arguments_: string[]) {
  const result = await command(arguments_);
  if (result.code !== 0) throw new Error(`Fixture command failed (${result.code}): ${result.stderr}`);
  return result;
}

async function signedCopy(base: string, name: string, identifier: string, identity: string) {
  const destination = join(directory!, name);
  await copyFile(base, destination);
  await checked(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none",
    "--identifier", identifier, "--sign", identity, destination]);
  await checked(["/usr/bin/codesign", "--verify", "--strict", destination]);
  return destination;
}

async function hold(path: string) {
  const child = Bun.spawn([path, "hold"], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  children.push(child);
  const reader = (child.stdout as ReadableStream<Uint8Array>).getReader();
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const first = await Promise.race([
      reader.read(),
      new Promise<never>((_, reject) => { timeout = setTimeout(() => reject(new Error("Probe readiness timed out")), 5000); }),
    ]);
    const text = new TextDecoder().decode(first.value);
    if (first.done || text !== `READY ${child.pid}\n`) throw new Error("Probe did not announce its own PID");
    return child.pid;
  } finally {
    if (timeout) clearTimeout(timeout);
    reader.releaseLock();
  }
}

function expectRejected(result: Awaited<ReturnType<typeof command>>) {
  expect(result.code).toBe(23);
  expect(result.stdout.startsWith("REJECTED ")).toBe(true);
  expect(result.stdout).not.toContain("ACCEPTED");
}

describe.skipIf(!enabled)("production Chrome bridge signing admission (opt-in)", () => {
  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "mactopus-bridge-signing-test-"));
    const base = join(directory, "probe");
    await checked(["xcrun", "swiftc", "-swift-version", "6", "-O",
      join(root, "Sources/Mactopus/Runtime/ChromeBridgeIPC.swift"),
      join(root, "Tests/Fixtures/ChromeBridgeSigningProbe.swift"), "-o", base]);
    adhocApp = await signedCopy(base, "adhoc-app", appID, "-");
    unsignedApp = join(directory, "unsigned-app");
    await copyFile(base, unsignedApp);
    await checked(["/usr/bin/codesign", "--remove-signature", unsignedApp]);
    if (appleIdentity) {
      signedApp = await signedCopy(base, "apple-app", appID, appleIdentity);
      signedHost = await signedCopy(base, "apple-host", hostID, appleIdentity);
      wrongIdentifier = await signedCopy(base, "apple-unrelated", "com.example.UnrelatedProbe", appleIdentity);
    }
    if (selfSignedIdentity) selfSignedApp = await signedCopy(base, "self-signed-app", appID, selfSignedIdentity);
  }, 60_000);

  afterAll(async () => {
    for (const child of children) {
      if (typeof child.stdin !== "number" && child.stdin) child.stdin.end();
      if (child.exitCode === null) child.kill();
      await child.exited;
    }
    if (directory) await rm(directory, { recursive: true });
  });

  test("ad-hoc owner cannot derive a trusted bridge team", async () => {
    const result = await command([adhocApp, "own-team", hostID]);
    expectRejected(result);
    expect(result.stdout).toBe("REJECTED signingRequired");
  });

  test("unsigned owner never gains admission, including OS launch rejection", async () => {
    // Apple Silicon can reject an unsigned executable before main(), which is
    // also fail-closed. Do not describe that OS rejection as an executed guard.
    const result = await command([unsignedApp, "own-team", hostID]);
    expect(result.code).not.toBe(0);
    expect(result.stdout).not.toContain("TEAM ");
  });

  test.skipIf(!selfSignedIdentity)("non-Apple self-signed certificate is not a trusted team", async () => {
    expectRejected(await command([selfSignedApp, "own-team", hostID]));
  });

  test.skipIf(!appleIdentity)("Apple-signed exact roles derive the same nonempty team", async () => {
    const app = await command([signedApp, "own-team", hostID]);
    const host = await command([signedHost, "own-team", appID]);
    expect(app.code).toBe(0);
    expect(host.code).toBe(0);
    expect(app.stdout).toMatch(/^TEAM [A-Z0-9]{10}$/);
    expect(host.stdout).toBe(app.stdout);
  });

  test.skipIf(!appleIdentity)("same-team app and host mutually authenticate actual running PIDs", async () => {
    const appPID = await hold(signedApp);
    const hostPID = await hold(signedHost);
    expect(await command([signedApp, "validate", String(hostPID), hostID])).toMatchObject({ code: 0, stdout: "ACCEPTED" });
    expect(await command([signedHost, "validate", String(appPID), appID])).toMatchObject({ code: 0, stdout: "ACCEPTED" });
  });

  test.skipIf(!appleIdentity)("wrong peer identifier, same role and ad-hoc peer are rejected", async () => {
    const unrelatedPID = await hold(wrongIdentifier);
    const appPID = await hold(signedApp);
    const adhocPID = await hold(adhocApp);
    expectRejected(await command([signedApp, "validate", String(unrelatedPID), hostID]));
    expectRejected(await command([signedApp, "own-team", appID]));
    expectRejected(await command([signedApp, "validate", String(appPID), hostID]));
    expectRejected(await command([signedHost, "validate", String(adhocPID), appID]));
  });

  test.skipIf(!appleIdentity)("unrelated Apple-signed owner cannot request bridge authority", async () => {
    expectRejected(await command([wrongIdentifier, "own-team", hostID]));
    expectRejected(await command([wrongIdentifier, "own-team", appID]));
  });

  test.skipIf(!appleIdentity)("explicit Chrome vendor team is fixed and cannot authorize fixture peers", async () => {
    const hostPID = await hold(signedHost);
    expectRejected(await command([signedApp, "validate", String(hostPID), hostID, "EQHXZ8M8AV"]));
    expectRejected(await command([signedApp, "validate", String(hostPID), "com.google.Chrome", "AAAAAAAAAA"]));
    expectRejected(await command([signedApp, "validate", String(hostPID), "com.google.Chrome", "EQHXZ8M8AV"]));
  });
});
