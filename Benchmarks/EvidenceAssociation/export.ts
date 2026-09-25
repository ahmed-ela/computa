import { makeEvidenceAssociationFixtures } from "./fixtures";
const [path] = Bun.argv.slice(2);
if (!path?.startsWith("/")) throw new Error("Absolute output path required");
await Bun.write(path, JSON.stringify(makeEvidenceAssociationFixtures(), null, 2));
