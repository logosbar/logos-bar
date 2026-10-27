# LogosBar

A small toolbar of one-click shortcuts for Logos Bible Software on the Mac, so you don't have to
hunt through Logos's dynamic ribbon. It can float anywhere or sit in the menu bar just after
Logos's **Help** menu.

| Button | What it does in Logos |
|---|---|
| Page numbers | Formatting → Markers → "Page numbers" |
| Table of contents | Home → Contents |
| Find in this panel | ⌘F |
| Visual filters | Formatting → Visual Filters → "Show Visual Filters" |
| Parallel text | ⇧⌘M |
| Interlinear | ⌘I (inline reverse interlinear) |
| Copy Bible Verses | Types "Copy Bible Verses" into the Go box |

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
- **Screen & System Audio Recording**: only the ribbon buttons (Page numbers, Table of contents,
  Visual filters) use it, to read the words on Logos's ribbon.

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

- **Placement**: floating toolbar, or in the menu bar after Help.
- **In the menu bar**: dark pill with white icons, or light pill with dark icons.
- **Floating toolbar**: horizontal or vertical, size (Default, Large 1.5×, Giant 2×), and whether
  it shows only while Logos is in front. Drag the tinted handle to move it.
- **Logos toolbar**: close the ribbon row again after a button had to open it.
- **Buttons**: tick to show, drag to reorder.

Where things are stored:

- Button recipes, order and on/off: `~/Library/Application Support/LogosBar/actions.json`. It can be
  edited by hand (right-click → **Edit Actions…**, then **Reload Actions**).
  `LogosBar/my-actions.json` in this project is a backup copy of it.
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

## How it works

Logos draws its panel ribbons itself, so their buttons are invisible to Accessibility; only the
ribbon's outline is. LogosBar uses Accessibility to find the active panel's ribbon, reads the words
on it with Vision text recognition, and clicks the matching word. Keyboard shortcuts and the Go box
need no screen reading.

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
- `--dump`: write what LogosBar can see of the active panel to `what-logosbar-sees.txt` there.

Quit LogosBar first (`pkill -x LogosBar`), since launch options only apply to a fresh launch.
