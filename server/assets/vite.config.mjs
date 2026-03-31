import path from "path";
import { defineConfig } from "vite";
import { phoenixVitePlugin } from "phoenix_vite";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  server: {
    port: 5288,
    strictPort: true,
    // Allow connections from both main (7755) and admin (7766) endpoints
    cors: { origin: ["http://localhost:7755", "http://localhost:7766"] },
  },
  optimizeDeps: {
    include: ["phoenix", "phoenix_html", "phoenix_live_view"],
  },
  build: {
    manifest: true,
    rollupOptions: {
      // Dual entry points: React/Inertia (app.js) and LiveView (admin.js)
      input: ["js/app.js", "js/admin.js", "css/app.css", "css/admin.css"],
    },
    outDir: "../priv/static",
    emptyOutDir: true,
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./js"),
    },
  },
  plugins: [
    react(),
    tailwindcss(),
    phoenixVitePlugin({ pattern: /\.(ex|heex)$/ }),
  ],
});
