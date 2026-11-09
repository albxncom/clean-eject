# Development

CleanEject is built with SwiftPM and a Makefile; there is no Xcode project to maintain.

Requirements: macOS 14 or newer, Xcode 16 or newer (Swift 6 toolchain; developed with Xcode 27 / Swift 6.4).

```sh
make            # swift build -c release, assembles build/CleanEject.app with the cleaneject tool inside, codesigns both
make run        # builds and opens the app
make test       # unit tests plus hdiutil-based integration tests (creates and detaches throwaway ExFAT images)
make install    # copies build/CleanEject.app to /Applications, registers the Finder service, links ~/.local/bin/cleaneject
make icon       # regenerates Resources/AppIcon.icns from Scripts/make-icon.swift
make clean
```

`swift build`, `swift test` and `open Package.swift` (Xcode) work as well. `Scripts/cli-smoke.sh build/CleanEject.app/Contents/Helpers/cleaneject` runs the bundled command-line tool end to end against a fixture folder under `build/cli-smoke/` and a throwaway ExFAT image, and removes both afterwards.

