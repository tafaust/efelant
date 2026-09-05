import { cpSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const root = dirname(fileURLToPath(import.meta.url));
const entry = join(root, "../ts-client/src/index.ts");
const outdir = join(root, "dist");
mkdirSync(outdir, { recursive: true });

const shared = {
  entryPoints: [entry],
  bundle: true,
  sourcemap: true,
};

await Promise.all([
  esbuild.build({
    ...shared,
    format: "esm",
    platform: "neutral",
    outfile: join(outdir, "efelant.esm.js"),
  }),
  esbuild.build({
    ...shared,
    format: "cjs",
    platform: "node",
    outfile: join(outdir, "efelant.cjs.js"),
  }),
  esbuild.build({
    ...shared,
    format: "iife",
    globalName: "Efelant",
    platform: "browser",
    outfile: join(outdir, "efelant.global.js"),
  }),
]);

const siteVendor = join(root, "../../site/js/vendor");
mkdirSync(siteVendor, { recursive: true });
cpSync(join(outdir, "efelant.esm.js"), join(siteVendor, "efelant.esm.js"));

console.log("js-client: esm + cjs + global + site/js/vendor");
