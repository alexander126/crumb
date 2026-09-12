import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";
import { Brand } from "@/components/brand";
export function baseOptions(): BaseLayoutProps {
  return {
    nav: { title: <Brand /> },
    githubUrl: "https://github.com/alexander126/crumb",
    links: [
      { text: "Quickstarts", url: "/docs" },
      { text: "Release status", url: "/docs/releases" },
    ],
  };
}
