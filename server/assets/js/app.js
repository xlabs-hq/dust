/**
 * Main app entry point - React + Inertia.js
 *
 * This is the entry point for the DustWeb endpoint (port 7000).
 * It uses React with Inertia.js for client-side rendering.
 */

import "vite/modulepreload-polyfill";
import "phoenix_html";
import { createInertiaApp } from "@inertiajs/react";
import { createRoot } from "react-dom/client";
import React from "react";
import axios from "axios";

// Configure axios CSRF for Inertia's internal requests
const csrfToken = document
  .querySelector('meta[name="csrf-token"]')
  ?.getAttribute("content");
if (csrfToken) {
  axios.defaults.headers.common["X-CSRF-Token"] = csrfToken;
}

// Create the Inertia app
createInertiaApp({
  title: (title) => (title ? `${title} — Dust` : "Dust"),
  resolve: async (name) => {
    // Import all page components
    const pages = import.meta.glob("./pages/**/*.tsx", { eager: true });

    const page = pages[`./pages/${name}.tsx`];
    if (!page) {
      throw new Error(
        `Page not found: ${name}. Looking for ./pages/${name}.tsx`
      );
    }

    const component = page.default || page;

    // Support persistent layouts via Page.layout property
    // Pages without an explicit layout get the Shell layout
    if (!component.layout) {
      const { Shell } = await import("./layouts/Shell");
      component.layout = (page) => React.createElement(Shell, null, page);
    }

    return component;
  },
  setup({ el, App, props }) {
    if (!el) {
      console.error("Inertia mount element not found");
      return;
    }
    createRoot(el).render(React.createElement(App, props));
  },
  progress: { color: "#4B5563" },
});
