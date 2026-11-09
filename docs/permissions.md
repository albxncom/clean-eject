# Permissions

CleanEject is not sandboxed and not notarized; `make` signs it with your first valid Apple Development identity, falling back to an ad-hoc signature (`codesign --sign -`), which is why Gatekeeper may ask you to confirm the first launch (right-click, Open). The first time it reads an external volume macOS shows its one-time "CleanEject would like to access files on a removable volume" prompt. Allow it; without that permission the app cannot see the files it is meant to delete. You can change the decision later under System Settings > Privacy & Security > Files and Folders.

Notifications: the first run started from the menu bar while the window is closed asks for permission to post notifications. Deny it and the result is simply not shown; nothing else changes.

## Full Disk Access

macOS protects the Spotlight index folder `.Spotlight-V100` on every volume, including SD cards, behind the Full Disk Access permission (TCC). Without it the folder and its `._.Spotlight-V100` sidecar cannot even be opened, and CleanEject reports them as "Needs Full Disk Access (System Settings > Privacy & Security)". Everything else, `.DS_Store`, `._*` files, `.fseventsd`, `.Trashes`, `.TemporaryItems` and `.apdisk`, works without it.

To grant it: System Settings > Privacy & Security > Full Disk Access > "+" > choose /Applications/CleanEject.app, then quit and relaunch CleanEject. macOS attributes a `cleaneject` run to the terminal app it runs in, not to CleanEject, so for the command-line tool grant Full Disk Access to your terminal app (Terminal, iTerm, ...) and restart it; the tool prints that hint when a Spotlight index was refused. Settings > Rules, the findings and the result all offer an "Open Full Disk Access Settings" button that jumps to that pane. TCC keys the permission on the app's code signature. `make` signs the app with your first valid Apple Development identity when one exists, so the grant survives rebuilds; with the ad-hoc fallback every build changes the code hash and macOS silently stops honouring the grant while the toggle still shows on. In that case toggling is not enough: remove CleanEject from the list with "-" and add it again with "+".

