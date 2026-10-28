# LogosBar

A small toolbar of one-click shortcuts for Logos Bible Software on the Mac, so you don't have to
hunt through Logos's dynamic ribbon. It can float anywhere, float just above the Logos panel
you're working in, or sit in the menu bar just after Logos's **Help** menu.

| Button | What it does in Logos |
|---|---|
| Page numbers | Formatting → Markers → "Page numbers" |
| Table of contents | Home → Contents |
| Find in this panel | ⌘F |
| Visual filters | Formatting → Visual Filters → "Show Visual Filters" |
| Parallel text | ⇧⌘M |
| Interlinear | ⌘I (inline reverse interlinear) |
| Copy Bible Verses | Types "Copy Bible Verses" into the Go box |
| Layouts | Asks whether to save the open panels as a layout or open a saved one, then does it in the sidebar's Layouts menu |

Buttons act on the Logos panel you last clicked in.

## Building

```bash
cd LogosBar
./build.sh
```

This compiles the app and installs it as `~/Applications/LogosBar.app`, replacing and restarting
any running copy. It needs Apple's command-line tools (`xcode-select --install`).

## Permissions and the signing certificate

LogosBar needs two permissions in System Settings → Privacy & Security:

- **Accessibility**: to find Logos's panels and menus, press keys and click.
- **Screen & System Audio Recording**: to read the words on Logos's ribbon and Layouts menu (Page
  numbers, Table of contents, Visual filters, Layouts) and to find the active panel's tab for the
  "above the active panel" placement.

macOS ties these permissions to the app's signature. `build.sh` signs with a self-signed
certificate named **LogosBar Signing** in the login keychain, so rebuilds keep their permissions.
If that certificate is missing (a new Mac, or the keychain was reset), `build.sh` falls back to
ad hoc signing and prints a warning. Permissions then reset on every rebuild until a new
certificate is made. After making a new one, approve both permissions once more.

To make a new certificate:

```bash
cat > /tmp/cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = LogosBar Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/key.pem -out /tmp/cert.pem -days 3650 -config /tmp/cert.cnf
openssl pkcs12 -export -legacy -inkey /tmp/key.pem -in /tmp/cert.pem -name "LogosBar Signing" -out /tmp/id.p12 -passout pass:temp
security import /tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
rm /tmp/cert.cnf /tmp/key.pem /tmp/cert.pem /tmp/id.p12
```

(`-legacy` is for Homebrew's OpenSSL 3; leave it out with the system's LibreSSL.)

If a permission gets stuck after a re-sign, clear it and approve again:

```bash
tccutil reset Accessibility local.logosbar
```

```bash
tccutil reset ScreenCapture local.logosbar
```

## Settings

Right-click any LogosBar icon → **Settings…**:

- **Placement**: floating toolbar, in the menu bar after Help, or floating above the active Logos
  panel. The last follows the orange strip on the active panel's tab as you switch panels. When a
  panel's tabs are at the top of the screen, with no room above, it sits just below that panel's
  tab row instead.
- **In the menu bar**: dark pill with white icons, or light pill with dark icons.
- **Floating toolbar** (also used above the active panel): horizontal or vertical, size (Default,
  Large 1.5×, Giant 2×), and whether it shows only while Logos is in front. Drag the tinted handle
  to move it; above the active panel LogosBar places it, so there's no handle.
- **Logos toolbar**: close the ribbon row again after a button had to open it.
- **Buttons**: tick to show, drag to reorder.

Where things are stored:

- Button recipes, order and on/off: `~/Library/Application Support/LogosBar/actions.json`. It can be
  edited by hand (right-click → **Edit Actions…**, then **Reload Actions**).
  `LogosBar/my-actions.json` in this project is a backup copy of it. Buttons added in later
  versions of LogosBar are added to the end of an existing file.
- Other settings: the app's preferences (`defaults read local.logosbar`).
- Log: `~/Library/Application Support/LogosBar/LogosBar.log`.

### Action recipes

Each button in `actions.json` has an `id`, `label`, SF Symbol `symbol`, optional `enabled`, and a
list of `steps`. A step can have:

- `tab` + `press`: click `press` on the active panel's ribbon, opening ribbon tab `tab` first if needed.
- `menuItem`: choose an item from the dropdown the previous step opened.
- `keys`: send a keystroke to Logos, such as `"cmd+f"` or `"shift+cmd+m"`.
- `go`: type text into the Go box and press Return.
- `wait`: pause for that many seconds first.
- `layoutPrompt`: ask whether to save or open a layout (used by the Layouts button).
- `layout`: open the saved layout with this name.
- `saveLayout`: save the open panels as a layout with this name.

### Layouts

**Open Layout…** asks for a name (the drop-down remembers the last 10), searches for it in Logos's
Layouts menu and opens the newest save with that name. **Save Current Layout** offers the active
layout's name: keep it to update that layout, or type a new name. Logos keeps every save, so
older versions stay in the Layouts menu's history.

## How it works

Logos draws its panel ribbons itself, so their buttons are invisible to Accessibility; only the
ribbon's outline is. LogosBar uses Accessibility to find the active panel's ribbon, reads the words
on it with Vision text recognition, and clicks the matching word. Keyboard shortcuts and the Go box
need no screen reading.

Layouts go through the Layouts menu rather than the Go box, whose "Open {name}" command can pick
a book or Factbook article with a similar name first. LogosBar searches the menu and clicks the
first result's thumbnail. Clicking the name instead only offers Rename and Delete.

To follow the active panel, LogosBar looks along the top of each panel's tab row for the orange
strip Logos draws on the active tab.

- `LogosBar/main.swift`: the toolbar window, its placement and look, and the action recipes.
- `LogosBar/Driver.swift`: finding Logos's panels, reading the ribbon, and clicking and typing.
- `LogosBar/Settings.swift`: the stored preferences and the Settings window.
- `LogosBar/build.sh`: build, sign and install.

## Testing from the command line

These launch options help check changes without clicking:

```bash
open ~/Applications/LogosBar.app --args --run contents
```

- `--run <id>`: run one button by its `id` shortly after launch, and log the result.
- `--snapshot`: save a picture of the toolbar to `snapshot.png` in the app's support folder.
- `--settings`: open Settings and save a picture of it to `settings.png` there.
- `--dump`: write what LogosBar can see of the active panel, including where the active tab's
  orange strip is, to `what-logosbar-sees.txt` there.
- `--layout <name>` and `--save-layout <name>`: with `--run layouts`, answer the Layouts prompts
  with that name instead of showing them. Opening a layout replaces the open panels, and saving
  adds a layout, so test with names you don't mind.

Quit LogosBar first (`pkill -x LogosBar`), since launch options only apply to a fresh launch.
