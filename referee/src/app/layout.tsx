import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";

import { PwaInstallPrompt } from "@/components/pwa-install-prompt";
import { resolveFieldEnvironment } from "@/lib/app-environment";

import "./globals.css";

const fieldrushFont = localFont({
  src: "./fonts/PlusJakartaSans.ttf",
  variable: "--font-fieldrush",
  weight: "200 800",
  display: "swap",
});

export function generateMetadata(): Metadata {
  const isStaging = process.env.NEXT_PUBLIC_APP_ENV === "staging";

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
        { url: "/favicon.ico", sizes: "any", type: "image/x-icon" },
        { url: "/favicon-16x16.png", sizes: "16x16", type: "image/png" },
        { url: "/favicon-32x32.png", sizes: "32x32", type: "image/png" },
        { url: "/favicon.svg", sizes: "any", type: "image/svg+xml" },
      ],
      apple: [
        {
          url: "/apple-touch-icon.png",
          sizes: "180x180",
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
  themeColor: "#386641",
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
    <html lang="en" className={fieldrushFont.variable}>
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
