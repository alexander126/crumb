import type { Metadata } from "next";
import { Provider } from "@/components/provider";
import "@fontsource/space-grotesk/latin-500.css";
import "@fontsource/space-grotesk/latin-600.css";
import "@fontsource/ibm-plex-sans/latin-400.css";
import "@fontsource/ibm-plex-sans/latin-500.css";
import "@fontsource/ibm-plex-sans/latin-600.css";
import "@fontsource/ibm-plex-mono/latin-400.css";
import "./global.css";
export const metadata: Metadata = {
  metadataBase: new URL("https://docs.crumbsdk.com"),
  title: {
    default: "Crumb Docs — useful reports start here",
    template: "%s | Crumb Docs",
  },
  description:
    "Integrate Crumb on iOS, Android and React Native. Send your first report, protect sensitive information, and capture useful debugging evidence.",
};
export default function Layout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>
        <Provider>
          <a className="skip-link" href="#main-content">
            Skip to content
          </a>
          {children}
        </Provider>
      </body>
    </html>
  );
}
