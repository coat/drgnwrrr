# Building and releasing drgnwrrr

This guide is for the maintainer of this repository. It explains how to:

- [set up the repository once](#set-up-the-repository-once), before the first build
- [publish a release](#publish-a-release)
- [fix a release that failed](#fix-a-release-that-failed)
- [check a pull request](#check-a-pull-request)

## What the workflows do

| Workflow | Runs when | What it does |
|--|--|--|
| `ci.yml` | You open or update a pull request | Checks formatting, runs the tests, and builds every version of the game. |
| `release.yml` | You push a tag such as `v1.2.3` | Builds every version, publishes a GitHub release, and updates the web version. |
| `build.yml` | Only when one of the workflows above calls it | Contains the build steps, so that both workflows build the game the same way. |

A release contains these files:

| File | For |
|--|--|
| `drgnwrrr-v1.2.3-x86_64-linux.tar.gz` | Linux on most PCs |
| `drgnwrrr-v1.2.3-aarch64-linux.tar.gz` | Linux on ARM computers, such as a Raspberry Pi |
| `drgnwrrr-v1.2.3-x86_64-windows.zip` | Windows |
| `drgnwrrr-v1.2.3-aarch64-macos.tar.gz` | Macs with Apple silicon (M1 and later) |
| `drgnwrrr-v1.2.3-x86_64-macos.tar.gz` | Macs with Intel processors |
| `drgnwrrr-v1.2.3.apk` | Android phones and tablets |
| `drgnwrrr.zip` | Linux gaming handhelds that run PortMaster |
| `SHA256SUMS` | Checking that the downloads are complete and unchanged |

Each desktop package holds the native game (`drgnwrrr`), the CLI game
(`drgnwrrr-cli`), the README and the licenses.

The web version is published at <https://coat.github.io/drgnwrrr>.

## Set up the repository once

You need to do this only once. Without step 1, every build fails. Without
steps 2 to 4, the release workflow stops with an error.

### 1. Give the ROM to GitHub

Every build reads the maps and NPC tables from a Dragon Warrior (U) ROM, which
can't be committed. The whole ROM is too big for a GitHub secret, but the build
reads only its first 16400 bytes (the iNES header and bank 0), so the secret
holds just those. `tools/ci-rom.sh` checks them and rebuilds the file.

Run this in the repository, with the ROM at `dragon_warrior.nes`:

```sh
head -c 16400 dragon_warrior.nes | gzip -9n | base64 | tr -d '\n' | gh secret set ROM_BANK0
```

Pull requests from forks don't get the repository's secrets, so their builds
fail at the **Rebuild the ROM** step.

### 2. Create a signing key for Android

Android installs an update only if it is signed with the same key as the
version already installed. You create this key once and keep it for the life
of the game.

1. Run this command outside the repository, so that the key is never
   committed:

   ```sh
   nix shell nixpkgs#jdk -c keytool -genkeypair -keystore drgnwrrr-release.jks \
     -alias drgnwrrr -keyalg RSA -keysize 4096 -validity 10000
   ```

2. Enter a password when `keytool` asks for one.
   The key and the file that holds it use this same password.
   The build expects only one password.
3. Answer the questions about your name and organization.
   Android does not check these answers.
4. Back up `drgnwrrr-release.jks` and its password somewhere other than this
   computer.

> **Important:** If you lose the key or its password, you cannot publish
> updates. Players must uninstall the game and install it again, and they lose
> their saves.

### 3. Give the key to GitHub

The release workflow reads the key from two repository secrets.

1. Upload the key. GitHub stores secrets as text, so this command converts the
   file to base64 text first:

   ```sh
   base64 < drgnwrrr-release.jks | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64
   ```

2. Upload the password. The command asks you to type it, so it does not appear
   in your shell history:

   ```sh
   gh secret set ANDROID_KEYSTORE_PASSWORD
   ```

### 4. Turn on GitHub Pages

1. In the repository, go to **Settings** > **Pages**.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**.
3. Go to **Settings** > **Environments** > **github-pages**.
4. Under **Deployment branches and tags**, select **Add deployment branch or
   tag rule**.
5. Set **Ref type** to **Tag**, enter `v*` as the pattern, and select **Add
   rule**.

Step 5 is needed because GitHub lets only the main branch publish to Pages
by default, and releases publish from a tag.

## Publish a release

The version number is in `build.zig.zon`. The release workflow checks that it
matches the tag, and stops if it does not. The APK's version comes from the
same number, so every release installs over the one before it.

1. Change the version in `build.zig.zon`:

   ```zig
   .version = "1.2.3",
   ```

2. Commit the change and push it to `main`.
3. Tag that commit with the version number, starting with `v`, and push the
   tag:

   ```sh
   git tag v1.2.3
   git push origin v1.2.3
   ```

4. Wait for the **Release** workflow to finish on the **Actions** tab.

The workflow then:

- builds every version of the game
- publishes the release with the files listed in
  [What the workflows do](#what-the-workflows-do), and notes generated from the
  commits since the last release
- updates the web version, but only if the release succeeded

## Fix a release that failed

If the version in `build.zig.zon` does not match the tag, the workflow stops
before it publishes anything. To fix it:

1. Delete the tag on GitHub and on your computer:

   ```sh
   git push origin :refs/tags/v1.2.3
   git tag -d v1.2.3
   ```

2. Follow [Publish a release](#publish-a-release) again from step 1.

If a build fails for another reason, the error is in the workflow's log on the
**Actions** tab. After you fix the problem, delete the tag and tag the new
commit, as described above.

If the release was published but only the **pages** job failed, you do not
need a new tag:

1. Fix the cause, such as the
   [Pages settings](#4-turn-on-github-pages).
2. Open the failed workflow run on the **Actions** tab.
3. Select **Re-run failed jobs**.

If the **release** job failed after it created the release, delete the release
before you push the tag again. Otherwise the workflow stops, because the
release already exists:

```sh
gh release delete v1.2.3 --yes
```

## Check a pull request

The CI workflow builds every version of the game for each pull request.
It does not run for pull requests that change only Markdown files.
To try a build:

1. Open the pull request's **Checks** tab and select the **CI** workflow.
2. Download a file from the **Artifacts** section.
   GitHub keeps these files for 7 days.

GitHub puts every artifact in a zip file, so unzip it first.

The Android app in a pull request is signed with a temporary key, not the
release key. Android does not install this app over a released version, so
uninstall the released version first.

CI doesn't run `zig build romcheck`: its ROM holds only bank 0, and romcheck
needs the whole ROM. Run it locally before a release.
