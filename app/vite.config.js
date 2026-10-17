import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@deployments": fileURLToPath(new URL("../deployments", import.meta.url)) },
  },
  server: { port: 8787, fs: { allow: [".."] } },
  build: { outDir: "dist", sourcemap: false },
});
