# Codex Usage Viewer

- Native SwiftUI/WidgetKit, macOS, three accounts, Liquid Glass. Use semantic colors, system type, and accessible controls. No menu bar tray icon.
- Each account uses a private app-owned `CODEX_HOME`. Never copy, log, or commit credentials. Widgets receive only sanitized snapshots.
- Use Codex app-server account methods, without inference. Read the default local identity through read-only `account/read`; never login, logout, or refresh its tokens.
- Read full names only from app-owned logins, matched to the official account email. Fall back to email; never read normal Codex tokens for names.
- Missing, stale, or expired limits are unknown. A reset timestamp does not prove quota recovery.
- Widgets: weekly usage, seven-day reset bar, numeric countdown; no header or "left" text. Small/medium show the subscription before the bar. All sizes use a computer icon for the local account.
- Keep the subscription and **Logged In** badge visible together in the app. Map Prolite → 100, Pro → 200, Promax → 500; preserve other names and missing values.
- Validate code with Swift tests, a native build, and UI/visual checks. Distinguish fixture renders from live-account and desktop widget checks.
- Finish every task involving code changes by building the current source, stopping all existing app/widget instances and their child workers, installing in `/Applications`, restarting, and verifying the running executable and version match the new build.
- `VERSION` is the release number. Tagged builds display it alone; development builds append commits since the nearest numeric release tag. Use `scripts/release.py`; never move a published tag.
