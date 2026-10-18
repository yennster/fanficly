# Fanficly

An open-source, ad-free reader for [Archive of Our Own](https://archiveofourown.org), with native apps for iPhone, iPad and Mac, and for Windows. There are no servers, accounts, ads or analytics: everything runs on your device and talks directly to AO3. Website: [fanficly.app](https://fanficly.app).

<img src="apple/screenshots/showcase.png" alt="Fanficly on iPhone, iPad and Mac">

<img src="docs/screenshots/windows/showcase.jpg" alt="Fanficly on a Windows desktop and tablet">

## The apps

| App | Where | Built with | Ships through | Docs |
| --- | --- | --- | --- | --- |
| iPhone, iPad and Mac | [`apple/`](apple/) | SwiftUI, Swift 6, iOS 17+ (Mac via Catalyst) | App Store | [README](apple/README.md) · [contributing](apple/CONTRIBUTING.md) · [roadmap](apple/docs/ROADMAP.md) · [accessibility](apple/ACCESSIBILITY.md) |
| Windows | [`windows/`](windows/) | C#, .NET 10, WinUI 3, Native AOT | Microsoft Store | [README](windows/README.md) · [contributing](windows/CONTRIBUTING.md) · [roadmap](windows/ROADMAP.md) · [accessibility](windows/ACCESSIBILITY.md) |

The two apps share behavior, not code: the Windows app is a port of the Swift app, which stays the reference implementation. Both are developed on `main`.

## Repository layout

```text
apple/        the iPhone, iPad and Mac app (Xcode project from project.yml)
windows/      the Windows app (Fanficly.Windows.slnx)
website/      fanficly.app (static site, deployed by Vercel)
docs/         shared pictures (docs/screenshots/windows/)
bin/          repo-wide scripts (roadmap.sh lists both roadmaps)
.github/      CI: ci.yml for apple/, windows-*.yml for windows/; release.yml and
              store-assets.yml release the Apple app (apple/docs/RELEASING.md)
```

CI is split by app: a change under `apple/` runs the Apple workflow, a change under `windows/` runs the Windows ones, and a pull request that touches both runs both.

## Privacy

We collect nothing. Each store listing links its own policy: [PRIVACY.md](PRIVACY.md) for iPhone, iPad and Mac, and [windows/PRIVACY.md](windows/PRIVACY.md) for Windows.

## Contributing

PRs welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md), then the guide for the app you're changing. Be kind, be patient with reviewers. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Fanficly is not affiliated with AO3 or the Organization for Transformative Works.

## License

[PolyForm Noncommercial License 1.0.0](LICENSE).
