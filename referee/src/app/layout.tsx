import type { Metadata, Viewport } from "next";

import { resolveFieldEnvironment } from "@/lib/app-environment";

import "./globals.css";

export const metadata: Metadata = {
  title: "Field Referee",
  description: "Mobile referee console for Field fixtures.",
};

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
      </body>
    </html>
  );
}
