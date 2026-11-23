# Lastide for iOS

Lastide for iOS is the phone companion of Lastide, a desktop IDE for people who run coding agents.
The desktop drafts rules from your corrections of the agents. The phone shows each draft, and you approve, edit or reject it.
The phone and the desktop talk through a relay, and the relay sees only encrypted messages.
`docs/protocol.md` describes the pairing, the encryption and every message.

## Layout

| Path | Holds |
| --- | --- |
| `App` | The SwiftUI app. `App/Core` holds the model, the launch path, the relay socket, pairing and storage. `App/Platform` holds the UIKit, push, App Attest and Keychain move parts. `App/Views` holds the five screens. `App/Shared` holds the App Group store, the Keychain store and the widget's view, which the extensions compile too |
| `Extensions/Notifications` | The notification service extension, which opens each encrypted notice on the phone |
| `Extensions/Widget` | The widget, which shows how many rules wait for review |
| `Packages/LastideKit` | The Swift package with the protocol, the encryption and the sync messages, and its tests |
| `Tests/UnitTests` | The RFC 9180, Lastide and push test vectors through CryptoKit |
| `Tests/HostedTests` | Tests that run inside the app, because the Keychain and the App Group need the app's entitlements |
| `Tests/UITests` | Screenshot tests for every screen and state, in light and dark, on demo data or a synthetic paired PC, and seven at the accessibility text size AX3 |
| `project.yml` | The XcodeGen spec. `Config/Debug.xcconfig` reads the git-ignored `Local.xcconfig` |
| `docs/protocol.md` | The phone protocol |
| `scripts/ci` | The simulator picker, the ad hoc signing step, the export check of the three bundles' entitlements, and the plants that prove both checks fail on a bad build |
| `scripts/hooks` | The pre-commit and pre-push hooks and their installer |

## Hooks before a commit and a push

Run `sh scripts/hooks/install.sh` once after a clone, before you add a remote.
Then check that `git config core.hooksPath` prints `scripts/hooks`.
Create the GitHub repository with no push in the same step, and push only after that check passes.
The pre-commit hook scans the working tree, and the pre-push hook scans every outgoing commit and annotated tag.
Both hooks need the maintainers' private workspace, and they refuse when it is missing.

The hooks run only on a maintainer's machine.
A push with `--no-verify`, a clone without the hooks, and an edit or upload on the GitHub website skip them.
So make every change in a clone with the hooks installed, and never skip them.

## How CI builds the app

GitHub Actions builds the app on a GitHub-hosted macOS runner.
A workflow starts on a push to `main` or by hand, and never from a pull request.
XcodeGen writes the Xcode project from `project.yml`, so the repository does not hold an `.xcodeproj`.
The package tests also run on Linux with `swift test` in `Packages/LastideKit`.
`build.yml` runs on each push to `main`. It runs the package tests on Linux and the app tests on the newest iPhone simulator.
It captures every screen in light and dark, and builds an unsigned `.ipa` with both extensions.
It then signs that build ad hoc with a made-up Team ID and runs the signing and export checks, once on the good build and once on each planted fault.
`testflight.yml` starts only by hand, and only on a commit whose `build.yml` passed.
It signs the app and its two extensions with their entitlements, exports once, checks the three bundles' entitlements, and only then uploads.
A screenshot run starts the app with `-LastideScreen <screen> -LastideColorScheme light` or `dark`, and shows demo data or a synthetic paired PC. It never reads the disk, the Keychain or the network.
Signing keys live only in GitHub repository secrets.

## Rights

This repository is public so that GitHub can build and test it.
All rights are reserved. The repository does not grant a license to use, copy, change or share the code.
