import Link from "next/link";
import { Brand } from "@/components/brand";
export default function NotFound() {
  return (
    <main id="main-content" tabIndex={-1} className="docs-home">
      <Link href="/" aria-label="Crumb documentation home">
        <Brand />
      </Link>
      <div className="home-intro">
        <div>
          <p className="eyebrow">404 · Page not found</p>
          <h1>This trail ends here.</h1>
        </div>
        <p>
          The page may have moved. The quickstarts and guides are still
          available.
        </p>
      </div>
      <Link className="guide-link" href="/docs">
        Browse the documentation →
      </Link>
    </main>
  );
}
