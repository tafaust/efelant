import { Config } from "@stencil/core";

export const config: Config = {
  namespace: "efelant",
  globalStyle: "src/global/theme.css",
  outputTargets: [
    { type: "dist", esmLoaderPath: "../loader" },
    {
      type: "dist-custom-elements",
      customElementsExportBehavior: "auto-define-custom-elements",
    },
    { type: "docs-json", file: "dist/docs.json" },
    { type: "www", serviceWorker: null },
  ],
};
