import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  const isStaging = process.env.NEXT_PUBLIC_APP_ENV === "staging";
  const iconPrefix = isStaging ? "field-ops-staging" : "field-ops";

  return {
    id: "/",
    name: isStaging ? "Field Ops Staging" : "Field Ops",
    short_name: isStaging ? "Field STG" : "Field Ops",
    description: "Field match-day operations for referees and administrators.",
    start_url: "/?source=pwa",
    scope: "/",
    display: "standalone",
    background_color: "#f8fafc",
    theme_color: isStaging ? "#d97706" : "#0b1512",
    orientation: "portrait-primary",
    categories: ["sports", "productivity"],
    icons: [
      {
        src: `/${iconPrefix}-192.png`,
        sizes: "192x192",
        type: "image/png",
        purpose: "any",
      },
      {
        src: `/${iconPrefix}-512.png`,
        sizes: "512x512",
        type: "image/png",
        purpose: "any",
      },
      {
        src: `/${iconPrefix}-512.png`,
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
    ],
  };
}
