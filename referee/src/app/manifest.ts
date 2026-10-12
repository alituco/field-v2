import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  const isStaging = process.env.NEXT_PUBLIC_APP_ENV === "staging";

  return {
    id: "/",
    name: isStaging ? "Field Ops Staging" : "Field Ops",
    short_name: isStaging ? "Field STG" : "Field Ops",
    description: "Field match-day operations for referees and administrators.",
    start_url: "/?source=pwa",
    scope: "/",
    display: "standalone",
    background_color: "#F2EFE3",
    theme_color: "#386641",
    orientation: "portrait-primary",
    categories: ["sports", "productivity"],
    icons: [
      {
        src: "/icon-192.png",
        sizes: "192x192",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icon-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icon-maskable-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
    ],
  };
}
