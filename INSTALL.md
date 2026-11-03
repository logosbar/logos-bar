# Installing LogosBar

These steps set up LogosBar on a Mac that has never had it. They take about ten minutes. You'll build
the app from source, make a signing certificate so macOS remembers LogosBar's permissions, and
then grant those permissions.

## What you need

- macOS 13 (Ventura) or later.
- Logos Bible Software for Mac, installed and signed in.
- Apple's command-line tools, which include the Swift compiler and `git`. If you don't have them,
  run this command and click **Install** in the window that appears:

  ```bash
  xcode-select --install
  ```

  The full Xcode app is not needed.

All commands go in the **Terminal** app (Applications → Utilities → Terminal).

## 1. Download LogosBar

```bash
git clone https://github.com/pfrobbins/logos-bar.git ~/logos-bar
```

No GitHub account is needed. You can put the folder anywhere; these steps use `~/logos-bar`.

## 2. Make the signing certificate (once per Mac)

macOS grants Accessibility and Screen Recording to an app by its signature. LogosBar signs itself
with a personal certificate named **LogosBar Signing** so that the permissions you grant in step 4
survive every rebuild and update. Without it, the build still works, but macOS forgets both
permissions each time you rebuild, and you have to grant them again.

Paste this whole block into Terminal and press Return:

```bash
dir=$(mktemp -d)
cat > "$dir/cert.cnf" <<'EOF'
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
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem"
# OpenSSL 3 (from Homebrew) needs -legacy for macOS to read the bundle; macOS's own LibreSSL doesn't.
legacy=$(openssl version | grep -q '^OpenSSL 3' && echo -legacy)
openssl pkcs12 -export $legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -name "LogosBar Signing" -out "$dir/id.p12" -passout pass:temp
security import "$dir/id.p12" -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
rm -rf "$dir"
```

Check that it worked:

```bash
security find-identity -p codesigning | grep "LogosBar Signing"
```

You should see a line with a long hexadecimal ID and `"LogosBar Signing"`. It may also say
`CSSMERR_TP_NOT_TRUSTED`. That is expected and harmless: the certificate is only for signing your own
copy of LogosBar, so macOS doesn't need to trust it, and you shouldn't mark it as trusted.

The certificate lives in your login keychain and lasts ten years. It never leaves your Mac.

## 3. Build and install

```bash
cd ~/logos-bar/LogosBar
./build.sh
```

This compiles LogosBar, signs it, and installs it as `~/Applications/LogosBar.app` (the
Applications folder inside your home folder). The last line should read
`Installed ~/Applications/LogosBar.app`.

- If it prints **"LogosBar Signing certificate not found; signing ad hoc"**, step 2 didn't take. Run
  the check in step 2 again before going on.
- The first time it signs, macOS may ask whether `codesign` may use the "LogosBar Signing" key.
  Enter your Mac login password and click **Always Allow**, so later builds don't ask.

Then open it:

```bash
open ~/Applications/LogosBar.app
```

LogosBar has no Dock icon. It shows only its toolbar, and its menu is on a right-click of any
LogosBar icon.

## 4. Grant permissions

LogosBar needs two permissions, both in **System Settings → Privacy & Security**:

| Permission | Why LogosBar needs it |
|---|---|
| **Accessibility** | To find Logos's panels, menus and Layouts button, and to press keys and click in Logos. Every button needs this. |
| **Screen & System Audio Recording** | To read the words on a panel's ribbon and in the Layouts menu (Page numbers, Visual filters, Inline Search, Layouts), and to find the active panel for the "near the active panel" placement. LogosBar reads only small areas of Logos's window, keeps nothing, and records no audio. |

macOS asks for Screen Recording the first time a button needs it. It doesn't ask for
Accessibility: a button just reports that the permission is missing. Grant both yourself:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Turn on **LogosBar**. If it isn't listed, click **+**, press ⇧⌘G, type `~/Applications`, and
   choose **LogosBar.app**.
3. Open **Privacy & Security → Screen & System Audio Recording** and turn on **LogosBar** the same
   way.
4. If macOS offers **Quit & Reopen**, click it. Otherwise quit LogosBar (right-click a LogosBar icon
   → **Quit LogosBar**) and open it again as in step 3.

Screen Recording only takes effect after LogosBar restarts. Until then the ribbon buttons report
that they need the permission.

## 5. Check that it works

1. Open a Bible in Logos and click in its text.
2. Click LogosBar's **Table of contents** button. The panel's table of contents should open. This
   checks Accessibility.
3. Click **Page numbers**. Page markers should appear or disappear. This checks Screen Recording.

If a button does nothing, right-click a LogosBar icon → **Show Log** to see what happened.

The **Copy quote** button needs Logos's "copy with citation" setting turned on, so that copied text
arrives with its citation.

## 6. Start LogosBar at login (optional)

Open **System Settings → General → Login Items & Extensions**, click **+** under **Open at Login**,
press ⇧⌘G, type `~/Applications`, and choose **LogosBar.app**.

## Updating

```bash
cd ~/logos-bar
git pull
cd LogosBar
./build.sh
open ~/Applications/LogosBar.app
```

Because of the certificate, your permissions carry over. Your button order and settings are kept;
buttons added in a new version appear at the end of the toolbar.

## Troubleshooting

**A permission is on in System Settings, but LogosBar still asks for it.** This happens when the
app's signature changed, for example after a build without the certificate. Clear the old entries,
then grant both permissions again as in step 4:

```bash
tccutil reset Accessibility local.logosbar
```

```bash
tccutil reset ScreenCapture local.logosbar
```

**Permissions reset after every rebuild.** The certificate is missing, for instance on a new Mac or
after the login keychain was reset. Make a new one (step 2), rebuild (step 3), and grant the
permissions once more (step 4). Certificates can't be moved from another Mac with these steps; just
make a new one.

**`./build.sh` says `swiftc: command not found` or `xcrun: error`.** The command-line tools are
missing or out of date. Run `xcode-select --install`, or update them in System Settings → General →
Software Update.

**`security import` fails with "MAC verification failed" or a password error.** macOS couldn't read
the certificate bundle. Run `openssl version`: on OpenSSL 3 the bundle needs `-legacy`, which the
block in step 2 adds automatically; on OpenSSL 1.1 remove the `$legacy` part and run the block again.

**Remove LogosBar.** Quit it, then:

```bash
rm -rf ~/Applications/LogosBar.app ~/Library/Application\ Support/LogosBar
```

```bash
defaults delete local.logosbar
```

To remove the certificate too, open **Keychain Access**, search for "LogosBar Signing", and delete
both the certificate and its private key.
