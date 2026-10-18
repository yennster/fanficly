# Contributing to Fanficly for Windows

Thanks for wanting to help. This folder (`windows/`) is the native Windows app. The iPhone, iPad and Mac app lives in `apple/` and has its own [contributing guide](../apple/CONTRIBUTING.md). Pull requests for either app go against `main`.

## Setup

You need the [.NET 10 SDK](https://dotnet.microsoft.com/download). The unit tests run, and the app compiles, on Windows, macOS or Linux:

```bash
git clone https://github.com/yennster/fanficly.git
cd fanficly
cd windows
dotnet test tests/Fanficly.Core.Tests
dotnet build src/Fanficly.App -p:Platform=x64
```

To run the app, you need Windows 10 (version 2004 or later) or Windows 11. Build an unpackaged copy and start it in demo mode, which is offline and leaves your real data alone:

```powershell
dotnet build src/Fanficly.App -c Debug -p:Platform=x64 -p:WindowsPackageType=None `
  -p:WindowsAppSDKSelfContained=true -p:RuntimeIdentifier=win-x64 -o ../artifacts/app-x64
../artifacts/app-x64/Fanficly.exe -demoMode
```

A current Visual Studio with the **WinUI application development** workload can deploy the packaged app. You need the packaged app to test widgets, the background task, the share target and `fanficly://` links. Building the Store package also needs the **Desktop development with C++** workload. See the README's Development section and [AGENTS.md](AGENTS.md) for the architecture.

## Principles

1. **Be a good guest to AO3.**
   - Every request goes through `IAO3Client` and its one-request-a-second throttle.
   - Don't add requests you don't need, and don't scrape in parallel.
   - Never retry a POST.
   - If a feature needs more requests, say why in the PR.
2. **No telemetry, no analytics, no third-party SDKs.** Nothing leaves the PC except requests to AO3 and the user's own sync folder. If you change what's stored or sent, update [PRIVACY.md](PRIVACY.md); it's the Store listing's privacy policy.
3. **Never make search guess.**
   - Typed words stay keywords for AO3's own search.
   - Tags become filters only when the user picks a suggestion.
   - A new `key:value` token in `SearchSyntax` needs a round-trip test.
   - Add a phrase to its filter-only list only if it can never mean anything but that filter.
4. **Match AO3's terminology.** Use AO3's own names for fields and categories (relationships, freeforms, archive warnings).
5. **Follow the Swift app.** The Swift sources in this repository are the reference. Port behaviour and edge cases faithfully, and note any deliberate Windows difference in a comment.
6. **Keep dependencies minimal.** The runtime depends on AngleSharp, Microsoft.Data.Sqlite and the Windows App SDK. A new package needs a justification in the PR, and it must work under Native AOT.
7. **Keyboard, controller and Narrator users count.**
   - Icon-only buttons need a name.
   - New shortcuts go on the Keyboard shortcuts page.
   - See [ACCESSIBILITY.md](ACCESSIBILITY.md).

## What to work on

The backlog is [windows/ROADMAP.md](ROADMAP.md). Its items are small and scoped, with IDs from `RM-101` and a "Done when". Run `bin/roadmap.sh free windows` to see what's unclaimed. To claim an item, open a draft PR against `main` from a `roadmap/RM-1nn-slug` branch. AI agents follow the loop in [AGENTS.md](AGENTS.md#autonomous-roadmap-work), and a person always does the merge.

## Pull requests

- One feature or fix per PR, against `main`. Keep Windows changes inside `windows/` (and the Windows workflows), so the PR builds only the Windows app.
- Reference an issue if there is one.
- `dotnet test tests/Fanficly.Core.Tests` passes, with new tests for what you changed. They're fixture-based; never hit the network.
- The app builds for x64 and ARM64.
- If you changed the UI and you're on Windows, run the smoke tests (`dotnet test tests/Fanficly.UITests --filter "FullyQualifiedName~SmokeTests"`) and look at the change in demo mode. If you changed the reader's layout, pagination or text measuring, run `ReaderLayoutTests` too (`--filter "FullyQualifiedName~ReaderLayoutTests"`). Leave the mouse alone while they run.
- [Windows CI](../.github/workflows/windows-ci.yml) runs on every PR to `main` that touches `windows/`. It runs:
  - the unit tests
  - x64 and ARM64 builds
  - the UI tests: smoke, screenshots and reader layout
  - the Native AOT Store bundle, which is the only place trimming and AOT problems show up

  Check the `ui-screenshots` artifact for anything you changed on screen. Don't commit screenshots yourself: the maintainer refreshes `docs/screenshots/windows/` and the Store pictures with the **Windows screenshots** workflow.
- Don't reformat code you didn't touch, and don't edit the Apple app's sources in a Windows PR.
- Be kind in code review.

## Reporting bugs

Open an issue with:

- your Windows version and build (Settings → System → About)
- whether your PC is x64 or ARM64
- where you got the app (Microsoft Store or a build from source), and its version (Settings → About in Fanficly)
- steps to reproduce
- what you expected and what happened
- the log, if you have one

The log is `Logs\fanficly.log` in the app's data folder:

- From the Store, that's under `%LOCALAPPDATA%\Packages\`, in the folder whose name starts with Fanficly's package name, then `LocalState\Logs`.
- From a build, it's `%LOCALAPPDATA%\Fanficly\Logs`.

The log never holds passwords or cookies, but it can name works you opened. Read it before attaching it.

## Code of Conduct

See [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md).
