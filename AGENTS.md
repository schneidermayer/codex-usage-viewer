# Codex Usage Viewer

Native macOS 27 SwiftUI app and WidgetKit extension for three Codex accounts.

- Respect native Liquid Glass. Use system typography, semantic colors, accessible controls, and restrained account accents.
- Never copy, log, or commit the user's existing Codex or browser credentials. Each connected account gets an app-owned authentication directory. The user authorized detecting the normal local Codex identity: use only the official read-only account method in that context, never login/logout or inference.
- The widget reads only a sanitized usage snapshot. Credentials stay outside the shared app group.
- Missing or expired usage is unknown, never zero. Reset timestamps do not prove that a quota has recovered.
- No inference requests are needed to read limits. Use the documented Codex app-server account methods.
- Verify with Swift tests, a native Xcode build, and UI interaction/visual checks. State any live-account or widget-host checks that could not run.
- Display full account names, with email fallback. Read name claims only from app-owned logins and bind them to the official account email; never log tokens or read the normal Codex login for names.
- Widgets show only weekly usage and time until reset, with a seven-day time bar and numeric countdown. Keep subscription type visible beside the Logged In badge in the app.
- Do not add a menu bar tray icon.
- Visible versions use VERSION plus the number of commits since the nearest reachable numeric release tag. Releases create annotated numeric tags before building, so release 1.0 displays 1.0-0. Use scripts/release.py; never move an existing release tag.
