# macOS development and delivery

These delivery instructions apply only when working on macOS. Other platforms
use their own build workflows.

## Installed application

- Build this fork as **Satra**, at `/Applications/Satra.app`, with bundle ID
  `com.satra.app`. Keep that path, name, and ID stable across updates.
- Never overwrite `/Applications/Plezy.app`; it is a separate upstream app.
- After changing the app, run `bash scripts/install-macos.sh` to build a release
  and update the same installed application. The user should be able to quit
  and reopen Satra from Applications or its existing Dock icon.
- The installer uses `.tools/flutter/bin/flutter` when available, otherwise
  Flutter on PATH. `FLUTTER_ROOT` can explicitly select a different SDK.
- Use the Flutter version pinned in `.github/workflows/build.yml`. This project
  needs full Xcode and CocoaPods. The installer selects
  `/Applications/Xcode.app/Contents/Developer` if DEVELOPER_DIR is unset.
- Request sandbox escalation for dependency downloads, Xcode build access,
  and installation into Applications when required.
- Do not force quit a running app or discard its state. If installation is
  blocked because Satra is running, finish the build and ask the user to quit
  before installing. Report clearly when installation remains pending.

## macOS icon

- Preserve Satra branding: `assets/satra.svg` is the source mark;
  `macos/satra.icon/Assets/satra-cropped.svg` is the macOS Icon Composer source.
- Keep `macos/satra.icon/icon.json`, the Xcode app-icon setting `satra`, and
  `CFBundleIconFile` (`satra`) consistent. The compiled bundle must contain
  `Contents/Resources/satra.icns` and its compiled asset catalog.
- Use Apple's asset compiler to compile the icon. Inspect a rendered preview
  after icon edits; verify a white Satra mark on the black rounded macOS icon.
- Before reporting delivery, verify the installed bundle's name, identifier,
  icon resources, and code signature, then perform a launch check when possible.
- Never claim Satra is installed merely because source/configuration changed.
  Report actual build or launch failures and resolve them when possible.
