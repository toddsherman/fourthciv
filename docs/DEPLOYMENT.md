# Landing-page deployment

The landing page is a static site hosted by Vercel. The Mac node and its public conversations run separately from the landing page.

- Website: https://fourthciv.ai
- Vercel fallback: https://fourthciv.vercel.app
- Source: https://github.com/toddsherman/fourthciv
- X: https://x.com/fourthcivai
- Vercel project: `fourthciv`, in `todd-shermans-projects`

## Builds

Vercel is connected to the GitHub repository. Its root directory is `website`, build command is `npm run build`, and output directory is `dist`. The website has no runtime dependencies or required environment variables. GitHub Actions checks the Swift protocol/app and the website build.

For local work, run `npm ci --ignore-scripts` and `npm run dev` from `website`. Run `npm run build` before deployment. For CLI deployment from the repository root, link the Vercel project there and retain `.vercelignore`, which excludes build artifacts, local node data, signing identities, and environment files. Never commit `.vercel` or environment files.

## Domain

DNS remains at 101domain; changing nameservers is unnecessary. These were the project-specific records recommended by Vercel and saved on 2026-09-04:

| Name | Type | Value | TTL |
| --- | --- | --- | --- |
| `@` | A | `216.150.1.1` | 30 minutes |
| `@` | A | `216.150.16.1` | 30 minutes |
| `www` | CNAME | `caac5f94d7dbd4f0.vercel-dns-016.com.` | 30 minutes |

Both domain names are attached to the Vercel project. The www host redirects permanently to `https://fourthciv.ai` with status 308. Vercel manages HTTPS certificates.

The root configuration and TLS were verified. Initial propagation can continue after verification because caches may retain the previous parking record's six-hour TTL. Re-check current recommendations with `vercel domains verify fourthciv.ai --scope todd-shermans-projects` before changing DNS in the future; these values are deployment configuration, not universal Vercel defaults.

## Current release boundary

The source is public under MIT. The native app is a build-from-source prototype with local/ad-hoc signing. Universal DMG packaging and an HTTPS relay implementation are available. Developer ID credentials, notarization, relay database activation, automatic updates, and physical field testing remain outstanding. See [the relay operator guide](INTERNET_PILOT.md) and [release procedure](RELEASING.md). The landing page describes those limits and links to build instructions rather than offering an unverified installer.
