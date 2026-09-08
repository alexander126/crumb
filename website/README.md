# Crumb public documentation

Fumadocs with Next.js and a static export. Public customer content lives only in
`content/docs`; the build never imports the repository-wide `docs` directory.
The site follows Crumb's jade/ink palette, Space Grotesk headings, IBM Plex Sans
body and IBM Plex Mono code. Fonts are served locally with the built assets.

## Local development

Node.js 22 or newer is required. From this directory:

```sh
npm ci
npm run dev
```

Open the local URL printed by the development server. For a production-like
preview, run `npm run build` and `npm start`. The output is `out/` and needs no
application server. Search uses the exported index in the browser; no search or
AI credentials are needed.

## Content

There are exactly three quickstarts: iOS, Android, and React Native. The React
Native page contains Expo and bare-app setup tabs, followed by shared startup,
invocation and verification steps. Preserve this grouping when adding content.

Quickstarts use published rc.3 APIs. Mark newer capabilities as Preview until
the corresponding native and React Native artifacts are published. Do not infer
availability from the version string on the main branch. Review `releases.mdx`
and the shared page notice together when promoting a release.

Only customer-safe material belongs in the content directory. Never import
engineering evidence, private deployment guidance, credentials, customer data,
source maps or application bundles. Examples use synthetic values and require
the reader's own project setup. Navigation order lives in `meta.json` files.

The build includes `/llms.txt`, `/llms-full.txt` and per-page Markdown exports
under `/llms.mdx/docs/`. Those routes use the same explicit public collection.
The source-map guide describes the CLI preview without assuming publication.

## Validation

```sh
npm run format:check
npm run types:check
npm run build
npm run links:check
npx playwright install chromium
npm test
```

The link check inspects all built local links and fragment targets. Browser tests
cover desktop/mobile routes, keyboard setup tabs, static search, and Markdown
exports. Review SDK snippets against their stated release before merging; the
website build alone does not compile native application examples.

## Publication boundary

This change provides a local site and static build only. The intended canonical
origin is `https://docs.crumbsdk.com`; metadata uses that public product domain.
Domain routing, hosting and publication require separate approval. No deployment
workflow, credentials, provider configuration or live service mutations are part
of this site. Serve extensionless static files (including `/api/search`) as well
as directories containing `index.html`; do not rewrite missing paths to the home
page. Verify search and Markdown routes on the chosen host before publication.
