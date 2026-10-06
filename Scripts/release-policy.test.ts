import { expect, test } from "bun:test";
import { tagMetadata } from "./release-policy";
import { releaseBase } from "./version";

test("stable tags preserve the numeric app version", () => {
  expect(tagMetadata("v0.1.0")).toEqual({ version: "0.1.0", appVersion: "0.1.0", channel: "stable", prerelease: false });
  expect(tagMetadata("v4294967295.0.1").appVersion).toBe("4294967295.0.1");
});

test("alpha is the only new prerelease label and its sequence is canonical", () => {
  expect(tagMetadata("v1.2.3-alpha.1")).toEqual({ version: "1.2.3-alpha.1", appVersion: "1.2.3", channel: "alpha", prerelease: true });
  // Keep the sequence as a SemVer identifier rather than rounding through Number.
  expect(tagMetadata("v1.2.3-alpha.9007199254740993").version).toBe("1.2.3-alpha.9007199254740993");
});

test("new release policy rejects alternative labels, metadata, malformed cores and sequences", () => {
  for (const tag of [
    "1.2.3", "v01.2.3", "v1.02.3", "v1.2.03", "v1.2", "v1.2.3.4", "v4294967296.0.0",
    "v1.2.3-beta.1", "v1.2.3-rc.1", "v1.2.3-preview.1", "v1.2.3-dev.1", "v1.2.3-Alpha.1",
    "v1.2.3-alpha", "v1.2.3-alpha.0", "v1.2.3-alpha.01", "v1.2.3-alpha.-1", "v1.2.3-alpha.1.2",
    "v1.2.3+build.1", "v1.2.3-alpha.1+build.1", "v1.2.3-alpha.1\n", " v1.2.3", "v1.2.3 ",
  ]) expect(() => tagMetadata(tag)).toThrow();
});

test("generic historical SemVer parsing remains compatible", () => {
  expect(releaseBase("1.2.3-preview.1")).toBe("1.2.3");
  expect(releaseBase("1.2.3-beta.1+build.001")).toBe("1.2.3");
});
