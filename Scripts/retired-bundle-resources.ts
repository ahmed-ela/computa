import { lstat } from "node:fs/promises";
import { join } from "node:path";

// Xcode can retain removed folder resources in an incremental build product.
// These paths are accepted in the previous installation only, never in a new
// signed or packaged app. Keep the source product cleanup scoped to these paths.
export const retiredBundleResources = [
  "Contents/Resources/ChromeBridge",
  "Contents/Resources/BrowserExtension",
] as const;

export async function rejectRetiredBundleResources(app: string): Promise<void> {
  for (const relative of retiredBundleResources) {
    try { await lstat(join(app, relative)); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw error;
    }
    throw new Error(`Retired bundle resource remains: ${relative}. Rebuild from current source before signing or packaging.`);
  }
}
