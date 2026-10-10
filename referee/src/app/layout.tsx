import type { Metadata, Viewport } from "next";

import { PwaInstallPrompt } from "@/components/pwa-install-prompt";
import { resolveFieldEnvironment } from "@/lib/app-environment";

import "./globals.css";

export function generateMetadata(): Metadata {
  const isStaging = process.env.NEXT_PUBLIC_APP_ENV === "staging";
  const iconPrefix = isStaging ? "field-ops-staging" : "field-ops";

  return {
    title: isStaging ? "Field Ops Staging" : "Field Ops",
    description: "Mobile match-day operations for Field referees and administrators.",
    applicationName: isStaging ? "Field Ops Staging" : "Field Ops",
    manifest: "/manifest.webmanifest",
    robots: {
      index: false,
      follow: false,
      nocache: true,
      googleBot: {
        index: false,
        follow: false,
      },
    },
    icons: {
      icon: [
        { url: `/${iconPrefix}-192.png`, sizes: "192x192", type: "image/png" },
        { url: `/${iconPrefix}-512.png`, sizes: "512x512", type: "image/png" },
      ],
      apple: [
        {
          url: `/${iconPrefix}-192.png`,
          sizes: "192x192",
          type: "image/png",
        },
      ],
    },
    appleWebApp: {
      capable: true,
      statusBarStyle: "default",
      title: isStaging ? "Field STG" : "Field Ops",
    },
    formatDetection: {
      telephone: false,
    },
  };
}

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  viewportFit: "cover",
  themeColor: "#f8fafc",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const environment = resolveFieldEnvironment();
  if (environment.error) {
    throw new Error(environment.error);
  }

  return (
    <html lang="en">
      <body className={environment.label ? "field-nonproduction" : undefined}>
        {environment.label ? (
          <div
            className={`field-environment-ribbon field-environment-${environment.environment}`}
            role="status"
          >
            FIELD {environment.label}
          </div>
        ) : null}
        {children}
        <PwaInstallPrompt />
      </body>
    </html>
  );
}
