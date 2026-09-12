import Link from "next/link";
import { ArrowUpRight, ArrowRight } from "lucide-react";
const platforms = [
  {
    number: "01",
    title: "React Native",
    detail: "Expo development builds & bare apps",
    href: "/docs/quickstarts/react-native",
  },
  {
    number: "02",
    title: "iOS",
    detail: "Swift Package Manager & CocoaPods",
    href: "/docs/quickstarts/ios",
  },
  {
    number: "03",
    title: "Android",
    detail: "Kotlin · Maven Central",
    href: "/docs/quickstarts/android",
  },
];
const guides = [
  {
    title: "Show the screen where it happened",
    href: "/docs/guides/screen-context",
  },
  {
    title: "Capture logs and diagnostic evidence",
    href: "/docs/guides/diagnostics",
  },
  {
    title: "Recover a JavaScript crash",
    href: "/docs/guides/javascript-crashes",
  },
  { title: "Protect sensitive information", href: "/docs/guides/privacy" },
];
export default function HomePage() {
  return (
    <div id="main-content" className="docs-home">
      <p className="eyebrow">The Crumb field guide · 0.0.1 preview</p>
      <section className="home-intro" aria-labelledby="home-title">
        <h1 id="home-title">
          Useful reports.
          <br />
          <span>Start here.</span>
        </h1>
        <p>
          Give every report a clearer starting point. Connect your app, capture
          useful evidence, and spend less time asking what happened.
        </p>
      </section>
      <section aria-labelledby="platforms-title">
        <div className="section-caption">
          <h2 id="platforms-title">Send your first report</h2>
          <span>CHOOSE YOUR PLATFORM</span>
        </div>
        {platforms.map((p) => (
          <Link key={p.href} href={p.href} className="platform-link">
            <span className="platform-number">{p.number}</span>
            <h3>{p.title}</h3>
            <p>{p.detail}</p>
            <ArrowUpRight aria-hidden="true" />
          </Link>
        ))}
      </section>
      <section className="guide-section" aria-labelledby="guides-title">
        <div>
          <p className="eyebrow">After your first report</p>
          <h2 id="guides-title">Make the evidence count.</h2>
          <p>
            Add the context your team needs, with deliberate controls over what
            you collect.
          </p>
        </div>
        <div>
          {guides.map((g) => (
            <Link key={g.href} href={g.href} className="guide-link">
              {g.title}
              <ArrowRight aria-hidden="true" />
            </Link>
          ))}
        </div>
      </section>
      <footer className="home-footer">
        <span>Built for the people building mobile apps.</span>
        <Link href="/docs/releases">Published packages & preview features</Link>
        <Link href="/docs/troubleshooting">Something not working?</Link>
      </footer>
    </div>
  );
}
