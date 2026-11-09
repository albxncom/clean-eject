# Command line

The app bundle carries a command-line tool, `CleanEject.app/Contents/Helpers/cleaneject`, signed like the app. It cleans the same targets with the same rules and refusals, through the same code path as the app.

Install it from Settings > General > Command Line Tool ("Install Command Line Tool"), or with `make install`. Both create the symbolic link `~/.local/bin/cleaneject` and only ever create or replace a link to a CleanEject helper; a file, folder or other link at that path is left alone and reported. `~/.local/bin` must be on your `PATH`.

```sh
cleaneject list                          # mounted external volumes
cleaneject preview /Volumes/SD           # everything that would be removed, grouped by rule; changes nothing
cleaneject clean /Volumes/SD --eject     # remove it, print a per-rule summary, then eject
cleaneject clean ~/Downloads/photos.zip --skip ds-store -v
cleaneject eject /Volumes/SD
cleaneject --help                        # every command, option and rule name
```

- Paths resolve like a drop on the window: a volume's mount point is the volume, a folder is a folder, a `.zip` file is the archive, and any other file stands for its folder. Every path is checked before anything runs; if one is refused (system locations, the startup volume, internal disks, symbolic links), every refusal is printed and nothing changes. Targets then run one after the other in the order given.
- The tool is stateless and never reads the app's settings: every rule starts at the defaults of a fresh install, and `--skip <rule>[,<rule>...]` (`ds-store`, `appledouble`, `spotlight`, `fseventsd`, `trashes`, `temporary-items`, `apdisk`), `--merge-appledouble` and `--prevent-recreation` change them. `clean` removes immediately; `preview` or `clean --dry-run` only lists. `--eject` and `eject` accept only volumes, and `--eject` cannot be combined with `--dry-run`.
- Results go to standard output, errors and hints to standard error. With `--json`, standard output carries exactly one JSON document: `{"results":[{"path","kind","dryRun","removedCount","removedBytes","removals":[{"path","rule","bytes","merged"}],"failures":[{"path","message","needsFullDiskAccess"}],"eject":null|{"ejected","error"}}],"refusals":[{"path","message"}]}` with absolute paths, or `{"volumes":[{"name","path","refusal"}]}` for `list`.
- Exit status: 0 everything succeeded, 1 a path was refused or a removal or eject failed, 2 usage error (nothing ran).

