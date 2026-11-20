# Maintaining this repository

For the repository owner. Everything here can be done on github.com in a browser.

## First-time setup

1. **Create the repository:** github.com > **+** > **New repository**
   - Name: `bmw-carplay-hud`
   - Description: `Google Maps arrows from CarPlay on BMW NBT EVO head-up displays - step-by-step Windows wizard`
   - **Private** for now. Don't add a README, .gitignore or licence (they're included).
2. **Upload the files:** on the empty repository page click **uploading an existing file**. Drag in everything
   *inside* the project folder, including the `.github` folder and the `.gitattributes` and `.gitignore` files.
   (In Explorer: View > Show > Hidden items, if you don't see them.) Commit message: `v0.9.0`. Click **Commit changes**.
3. **Check the upload:**
   - `payload/libnbt_carplay_hud.so` shows 1.16 MB.
   - The `.github/ISSUE_TEMPLATE` folder exists.
   - Download ZIP from the **Code** button, extract it, and run
     `powershell -ExecutionPolicy Bypass -STA -File app\CarPlayHudWizard.ps1 -SelfTest`: it must end with
     `SELFTEST PASS`.
4. **Settings** (gear icon):
   - General > Features: tick **Issues**. Untick Wiki and Projects (not used).
   - General > Pull Requests: tick **Allow squash merging** only.
   - Security > **Private vulnerability reporting**: Enable (`SECURITY.md` points people there).
   - Branches > Add branch ruleset for `main`: require a pull request before merging, and block force pushes.
5. **About** (gear next to "About" on the main page): add topics `bmw`, `carplay`, `nbt-evo`, `idrive`, `hud`,
   `head-up-display`, `qnx`, `google-maps`.
6. **Labels** (Issues > Labels): make sure `bug` and `compatibility` exist (the issue forms use them).

## Releases (how users should download it)

1. Code > **Releases** > **Draft a new release**.
2. Choose a tag: type `v0.9.0`, create it on `main`. Title: `v0.9.0 - first public beta`.
3. Paste the matching section from `CHANGELOG.md` into the description, plus the release ZIP's SHA-256.
4. Attach the release ZIP (built by the maintainer; see below). Tick **Set as a pre-release** while it's a beta.
5. Publish.

The release ZIP is the same files as the repository. Users who download it get exactly what the SHA256SUMS
file lists.

## Before making the repository public

- [ ] One full or partial run of the wizard on a real car with this exact version (at least: sign in, Tools /
      Undo > Check status, Turn the bridge off, then Switch on again).
- [ ] `README.md` compatibility table is accurate; nothing personal anywhere (VIN, serial, Wi-Fi, MACs, names).
- [ ] Courtesy note to the bridge author (ftojke) that this wizard redistributes the unchanged prebuilt bridge
      under its PolyForm Noncommercial licence, with credit.
- [ ] Then: Settings > General > Danger Zone > **Change visibility** > Public.

## Updating

- Change files, bump the version in `CHANGELOG.md`, regenerate `SHA256SUMS`, run the self-test, upload the changed
  files (github.com: open the folder > **Add file** > **Upload files**), and make a new release.
- Never upload anything from `Documents\BMW-CarPlay-HUD-backups` or `%LOCALAPPDATA%\CarPlayHudWizard`.
