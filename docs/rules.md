# What it removes

| Item | Where | Default | What it is |
| --- | --- | --- | --- |
| `.DS_Store` | every folder | on | Finder view settings per folder |
| `._<name>` | every folder | on | AppleDouble sidecars holding extended attributes and resource forks for volumes that cannot store them natively (FAT, ExFAT, NTFS, SMB) |
| `.Spotlight-V100/` | top level | on | Spotlight index |
| `.fseventsd/` | top level | on | File system events journal |
| `.Trashes/` | top level | on | Per-user trash on the volume |
| `.TemporaryItems/` | top level | on | Scratch files from Finder copies |
| `.apdisk` | top level | on | AppleShare client metadata |

Every rule can be switched off in Settings > Rules (⌘,). Nothing else is ever touched: a regular file named `._` (exactly two characters), `.hidden`, `_foo`, `.DS_Store.bak` and a nested `.Spotlight-V100` folder all survive. Symbolic links are never followed: a link is never a match itself, and a link inside a junk folder such as `.Trashes` is removed as a link while its target stays untouched. A volume mounted inside the volume being cleaned is skipped.

Folders get only the per-folder rules, `.DS_Store` and `._*`: a folder's children are not the top level of a volume, so a `.Trashes` or `.Spotlight-V100` folder inside it survives and no prevention markers are written. Folders under `/System`, `/Library`, `/usr`, `/private`, `/bin`, `/sbin`, `/etc`, `/var`, `/dev` and `/tmp` are refused, as are symbolic links and volume roots (clean those as volumes).

ZIP archives are cleaned in place with the same rules, the archive root counting as the top level: `.DS_Store` entries anywhere, `._*` entries, the `__MACOSX` folder that Archive Utility fills with sidecars, and the top-level `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems` and `.apdisk`. The archive and its folder must be writable; nothing is extracted.

Two optional switches, both off by default:

- "Merge AppleDouble Data Back Into Files First": before a `._name` sidecar is removed, the resource fork and extended attributes it holds are copied into `name` where the volume can store them (APFS, HFS+). Attributes the file already has keep their values. It has no effect on FAT and ExFAT volumes, where the sidecar is that storage, nor on archives. A sidecar that cannot be merged is kept and listed as a failure; the result says how many were merged.
- "Prevent macOS from Recreating Them" writes two empty marker files to the volume root after cleaning: `.metadata_never_index`, which keeps Spotlight from indexing the volume, and `.fseventsd/no_log`, which stops the file system events journal. Without it macOS recreates `.fseventsd` the moment the volume is ejected; that is normal and harmless, and the folder is removed again on the next run.

