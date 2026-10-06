#!/usr/bin/env bun
// App release metadata. Never commits, tags, publishes, installs or launches.
import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";

export interface AppVersion { version: string; build: string }
export type Bump = "major" | "minor" | "patch" | "build";
const core = "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)";
const releasePattern = new RegExp(`^${core}(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?$`);

export function isAppVersion(value: unknown): value is string {
  return typeof value === "string" && value === value.trim() && new RegExp(`^${core}$`).test(value)
    && value.split(".").every(part => BigInt(part) <= 0xffff_ffffn);
}

export function releaseBase(value: string): string {
  const match = releasePattern.exec(value);
  if (!match || match[0].length !== value.length || !isAppVersion(`${match[1]}.${match[2]}.${match[3]}`)
    || match[4]?.split(".").some(part => /^[0-9]+$/.test(part) && part.length > 1 && part.startsWith("0"))) {
    throw new Error("Release version must be valid SemVer, such as 1.2.3 or 1.2.3-preview.1");
  }
  return `${match[1]}.${match[2]}.${match[3]}`;
}

export function isBuildNumber(value: unknown): value is string {
  // A single positive Apple build component, within its four-digit limit.
  return typeof value === "string" && value === value.trim() && /^[1-9][0-9]{0,3}$/.test(value);
}

export function parseVersionConfig(text: string): AppVersion {
  const settings = new Map<string, string>();
  for (const line of text.split(/\r?\n/)) {
    const setting = line.split("//", 1)[0].trim();
    if (!setting) continue;
    const match = /^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$/.exec(setting);
    if (!match || settings.has(match[1])) throw new Error("Version.xcconfig must contain exactly one of each version setting");
    settings.set(match[1], match[2]);
  }
  const version = settings.get("MARKETING_VERSION"), build = settings.get("CURRENT_PROJECT_VERSION");
  if (!isAppVersion(version)) throw new Error("MARKETING_VERSION must be major.minor.patch without leading zeros");
  if (!isBuildNumber(build)) throw new Error("CURRENT_PROJECT_VERSION must be an integer from 1 through 9999");
  return { version, build };
}

export function nextVersion(current: AppVersion, kind: Bump): AppVersion {
  if (!["major", "minor", "patch", "build"].includes(kind)) throw new Error("Choose major, minor, patch or build");
  if (!isAppVersion(current.version) || !isBuildNumber(current.build)) throw new Error("Invalid current app version");
  if (current.build === "9999") throw new Error("Apple build number exhausted; no files were changed");
  const parts = current.version.split(".").map(Number);
  const index = { major: 0, minor: 1, patch: 2 }[kind as Exclude<Bump, "build">];
  if (kind !== "build") {
    parts[index]++;
    for (let i = index + 1; i < parts.length; i++) parts[i] = 0;
  }
  const next = { version: parts.join("."), build: String(Number(current.build) + 1) };
  if (!isAppVersion(next.version)) throw new Error("Version component exhausted; no files were changed");
  return next;
}

async function sources(root: string) {
  const paths = ["Config/Version.xcconfig", "Cargo.toml", "Cargo.lock"].map(path => join(root, path));
  const texts = await Promise.all(paths.map(path => readFile(path, "utf8")));
  const current = parseVersionConfig(texts[0]);
  const cargo = Bun.TOML.parse(texts[1]) as any;
  if (cargo.workspace?.package?.version !== current.version) throw new Error("Cargo workspace version differs from Config/Version.xcconfig");
  const members: unknown = cargo.workspace?.members;
  if (!Array.isArray(members) || !members.length || !members.every(member => typeof member === "string" && !member.includes("*"))) {
    throw new Error("Version tool requires explicit Cargo workspace members");
  }
  const names = new Set<string>();
  for (const member of members) {
    const manifest = Bun.TOML.parse(await readFile(join(root, member, "Cargo.toml"), "utf8")) as any;
    if (typeof manifest.package?.name !== "string" || manifest.package?.version?.workspace !== true) {
      throw new Error(`Workspace member must inherit the app version: ${member}`);
    }
    names.add(manifest.package.name);
  }
  const lock = Bun.TOML.parse(texts[2]) as any;
  for (const name of names) {
    const entries = lock.package?.filter((pkg: any) => pkg.name === name && pkg.source === undefined) ?? [];
    if (entries.length !== 1 || entries[0].version !== current.version) throw new Error(`Cargo.lock app version differs for ${name}`);
  }
  return { paths, texts, current, names };
}

export async function checkVersion(root: string): Promise<AppVersion> {
  return (await sources(root)).current;
}

export async function bumpVersion(root: string, kind: Bump): Promise<AppVersion> {
  const { paths, texts, current, names } = await sources(root);
  const next = nextVersion(current, kind);
  const updated = [
    texts[0].replace(/^([ \t]*MARKETING_VERSION[ \t]*=[ \t]*)\S+/m, (_, prefix) => `${prefix}${next.version}`)
      .replace(/^([ \t]*CURRENT_PROJECT_VERSION[ \t]*=[ \t]*)\S+/m, (_, prefix) => `${prefix}${next.build}`),
    texts[1].replace(/^(\[workspace\.package\][^\r\n]*\r?\n)([\s\S]*?)(?=^\[|(?![\s\S]))/m,
      (_, header, body) => header + body.replace(/^([ \t]*version[ \t]*=[ \t]*)(["'])[\s\S]*?\2/m,
        (_: string, prefix: string, quote: string) => `${prefix}${quote}${next.version}${quote}`)),
    texts[2].replace(/\[\[package\]\][\s\S]*?(?=\n\[\[package\]\]|$)/g, block => {
      const pkg = (Bun.TOML.parse(block) as any).package[0];
      return names.has(pkg.name) && pkg.source === undefined
        ? block.replace(/^(version\s*=\s*")[^"]+(".*)/m, (_, prefix, suffix) => `${prefix}${next.version}${suffix}`) : block;
    }),
  ];
  // Parsing accepts more TOML layouts than the surgical text updates support.
  // Refuse any incomplete rewrite before replacing even the canonical file.
  const planned = parseVersionConfig(updated[0]);
  const plannedCargo = Bun.TOML.parse(updated[1]) as any;
  const plannedLock = Bun.TOML.parse(updated[2]) as any;
  if (planned.version !== next.version || planned.build !== next.build || plannedCargo.workspace?.package?.version !== next.version
    || [...names].some(name => {
      const entries = plannedLock.package?.filter((pkg: any) => pkg.name === name && pkg.source === undefined) ?? [];
      return entries.length !== 1 || entries[0].version !== next.version;
    })) throw new Error("Unsupported version file layout; no files were changed");
  const stages = paths.map(path => `${path}.version-${randomUUID()}`);
  const changed: number[] = [];
  try {
    for (let i = 0; i < paths.length; i++) {
      if (updated[i] !== texts[i]) await writeFile(stages[i], updated[i], { flag: "wx" });
    }
    for (let i = 0; i < paths.length; i++) {
      if (await readFile(paths[i], "utf8") !== texts[i]) throw new Error("Version files changed during bump; retry after reviewing them");
    }
    for (let i = 0; i < paths.length; i++) {
      if (updated[i] !== texts[i]) { await rename(stages[i], paths[i]); changed.push(i); }
    }
  } catch (error) {
    for (const i of changed) await writeFile(paths[i], texts[i]);
    throw error;
  } finally {
    await Promise.all(stages.map(path => rm(path, { force: true })));
  }
  return next;
}

const help = "Usage: bun Scripts/version.ts [show | check | bump major|minor|patch|build]";
if (import.meta.main) {
  try {
    const args = process.argv.slice(2), root = resolve(import.meta.dir, "..");
    if (args.length === 1 && args[0] === "--help") console.log(help);
    else {
      let version: AppVersion;
      if (!args.length || (args.length === 1 && ["show", "check"].includes(args[0]))) version = await checkVersion(root);
      else if (args.length === 2 && args[0] === "bump" && ["major", "minor", "patch", "build"].includes(args[1])) version = await bumpVersion(root, args[1] as Bump);
      else throw new Error(help);
      console.log(`Computa ${version.version} (${version.build})`);
    }
  } catch (error) { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; }
}
