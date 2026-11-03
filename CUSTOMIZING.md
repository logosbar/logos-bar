# Making your own version of LogosBar with Claude Code

These steps copy LogosBar from GitHub to your Mac and set it up so that Claude Code can change it
for you: new buttons, a different look, a button that does something only you need. You describe
the change in plain words; Claude edits the code, rebuilds the app and tests it.

You don't need to know Swift. You do need about twenty minutes the first time.

## What you need

- A Mac with macOS 13 (Ventura) or later, and Logos Bible Software for Mac.
- Apple's command-line tools (they include `git` and the Swift compiler). In the **Terminal** app
  (Applications → Utilities → Terminal):

  ```bash
  xcode-select --install
  ```

- Claude Code, which needs a paid Claude plan (Pro or higher). Either the **Claude desktop app**
  (download it from [claude.ai/download](https://claude.ai/download) and open its **Code** tab), or
  the `claude` command in Terminal (see [Claude Code's setup page](https://docs.claude.com/en/docs/claude-code/setup)).
  Either works; these steps say "Claude" for both.
- A free GitHub account is optional. It lets you keep your changes online and back them up; see
  step 1.

## 1. Copy LogosBar to your Mac

Pick one of these.

**A. Just a copy on your Mac (simplest).** No GitHub account needed:

```bash
git clone https://github.com/logosbar/logos-bar.git ~/logos-bar
```

**B. Your own copy on GitHub too (a "fork").** Sign in to GitHub, open
[github.com/logosbar/logos-bar](https://github.com/logosbar/logos-bar), and click **Fork**, then
**Create fork**. GitHub makes `github.com/YOUR-NAME/logos-bar`. Copy that to your Mac, using your
GitHub user name in place of `YOUR-NAME`:

```bash
git clone https://github.com/YOUR-NAME/logos-bar.git ~/logos-bar
```

Then tell your copy where the original lives, so you can bring in later updates:

```bash
git -C ~/logos-bar remote add upstream https://github.com/logosbar/logos-bar.git
```

Either way you now have a `logos-bar` folder in your home folder with everything in it: the app's
source in `LogosBar/`, the build script, and the guides. These steps use `~/logos-bar`; you can put
it anywhere.

## 2. Install the original once, by hand

Follow steps 2 to 5 of [INSTALL.md](INSTALL.md): make the signing certificate, build, grant the two
permissions, and check that the buttons work. Do this yourself before asking Claude for changes.
The certificate and permissions involve your password and System Settings, which Claude can't do
for you, and once they're done every later rebuild keeps them.

If LogosBar already works on this Mac (installed from another folder), you can skip this: the
certificate and permissions carry over.

## 3. Open the folder in Claude Code

- **Desktop app:** open the **Code** tab, start a new session, and choose the `logos-bar` folder as
  its folder.
- **Terminal:**

  ```bash
  cd ~/logos-bar && claude
  ```

Claude can now read and change everything in the folder. It asks before running commands or
editing files, unless you tell it otherwise.

## 4. Give Claude its bearings

Start your first session with something like this, so Claude learns how LogosBar works before it
changes anything:

> Read README.md and INSTALL.md and look through the Swift files in LogosBar/. This is a toolbar
> for Logos Bible Software that I want to customize. Then run /init to write a CLAUDE.md with what
> you learned, including how to build (`LogosBar/build.sh`) and how to test with the launch
> options in the README's "Testing from the command line" section.

`/init` writes a `CLAUDE.md` file that Claude reads at the start of every later session, so you
don't have to explain the project again. Add your own notes to it any time ("I use Obsidian for
notes", "keep the toolbar small").

A few things worth knowing, which you can pass on to Claude if it gets stuck:

- Logos draws its ribbon buttons itself, so LogosBar finds them by reading the words on screen
  (Apple's Vision text recognition) and clicking them. Keyboard shortcuts are simpler and more
  reliable wherever Logos has one, so prefer them for new buttons.
- Claude's screenshot tools can't see LogosBar's own windows. To check its work, Claude should
  relaunch the app with the launch options in the README (`--snapshot`, `--settings`, `--run <id>`,
  `--dump`) and read the files they write in `~/Library/Application Support/LogosBar/`.
- `./build.sh` in `LogosBar/` rebuilds and reinstalls the app; open it again afterwards.

## 5. Ask for changes

Describe what you want the way you'd describe it to a person. For example:

- "Add a button that opens the Passage Guide for the verse in the active panel."
- "Make the toolbar icons bigger and put a little space between them."
- "Add a button that runs Logos's ⌘⇧E shortcut, with a pencil icon."
- "Change Copy quote so it puts the page number before the title."
- "The Visual filters button doesn't work on my Mac. Here is the log: …" (right-click a LogosBar
  icon → **Show Log**, and paste what it shows).

Then let Claude build and test. When it says it's done, try the change yourself in Logos. If
something's off, say what you saw; it's normal to go back and forth a few times.

Some changes need no code at all: buttons that only press keys or click ribbon words are recipes in
`~/Library/Application Support/LogosBar/actions.json` (see "Action recipes" in the README). Claude
can edit that file for you, then right-click a LogosBar icon → **Reload Actions**.

## 6. Save your changes

Ask Claude to **commit** after each change that works ("commit this"). A commit is a saved
checkpoint: if a later change goes wrong, you can ask Claude to go back to it.

If you made a fork (step 1B), ask Claude to **push** as well, which uploads your commits to your
GitHub copy as a backup. The first push may ask you to sign in to GitHub; the desktop app or the
`gh` command (`brew install gh`, then `gh auth login`) handles that.

If you cloned without a fork (step 1A), your changes stay on your Mac only. You can make a fork
later and ask Claude to switch the folder over to it.

## 7. Bring in updates to the original

When the original LogosBar gains new features, you can merge them into your version. Ask Claude:

> Bring in the latest changes from the original LogosBar (logosbar/logos-bar on GitHub), keep my
> changes, rebuild, and tell me if anything clashed.

Behind the scenes that is roughly:

```bash
cd ~/logos-bar
git pull upstream main    # if you made a fork (step 1B)
git pull                  # if you cloned the original (step 1A)
```

If the original and your version changed the same lines, Git calls it a conflict; Claude can
resolve it with you, explaining each choice.

## Sharing an improvement back

If you make something others might like, you can offer it to the original: with a fork, ask Claude
to "open a pull request to logosbar/logos-bar with this change". The maintainer can then review it
and add it for everyone.

## If something goes wrong

- **A change broke the app.** Ask Claude to undo it ("go back to the last commit and rebuild").
- **Permissions keep resetting, or a button says a permission is missing.** See Troubleshooting in
  [INSTALL.md](INSTALL.md).
- **Claude seems lost about how LogosBar works.** Ask it to reread README.md and CLAUDE.md, or
  start a fresh session.
