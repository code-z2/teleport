import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        // Pure logic (envelope validation, FCM messages, OAuth, blobs with a fake R2).
        test: { name: "node", include: ["test/worker.test.ts"], environment: "node" },
        resolve: {
          alias: { "cloudflare:workers": fileURLToPath(new URL("./test/stubs/cloudflare-workers.ts", import.meta.url)) },
        },
      },
      {
        // The Mac mailbox Durable Object, in the real Workers runtime (Miniflare).
        plugins: [
          cloudflareTest({
            wrangler: { configPath: "./wrangler.jsonc" },
            miniflare: { bindings: { RELAY_KEY: "k".repeat(40), FCM_SERVICE_ACCOUNT: "{}" } },
          }),
        ],
        test: { name: "workers", include: ["test/mailbox.test.ts"] },
      },
    ],
  },
});
