// Policy for producing new releases. Historical installer versions stay generic SemVer.
import { releaseBase } from "./version";

export interface TagMetadata {
  version: string;
  appVersion: string;
  channel: "alpha" | "stable";
  prerelease: boolean;
}

export function tagMetadata(tag: string): TagMetadata {
  const match = typeof tag === "string"
    ? /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-alpha\.([1-9][0-9]*))?$/.exec(tag)
    : null;
  if (!match || match[0] !== tag) {
    throw new Error("Release tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-alpha.N with a positive canonical N");
  }
  const version = tag.slice(1);
  const appVersion = releaseBase(version);
  const prerelease = match[4] !== undefined;
  return { version, appVersion, channel: prerelease ? "alpha" : "stable", prerelease };
}
