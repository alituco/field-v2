import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Game overview | Field Admin",
  robots: { index: false, follow: false },
};

export default function AdminGameLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
