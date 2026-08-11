<a href="https://atsign.com#gh-light-mode-only"><img width=250px src="https://atsign.com/wp-content/uploads/2022/05/atsign-logo-horizontal-color2022.svg#gh-light-mode-only" alt="The Atsign Foundation"></a><a href="https://atsign.com#gh-dark-mode-only"><img width=250px src="https://atsign.com/wp-content/uploads/2023/08/atsign-logo-horizontal-reverse2022-Color.svg#gh-dark-mode-only" alt="The Atsign Foundation"></a>

# at_end2end_test

Runs end to end tests on Atsign Protocol server.

## Running locally

In CI this pack runs against the long-lived `@cicd` atSigns. To run it against
a virtualenv built from your working tree instead:

```sh
./runLocal.sh
```

That builds the atDirectory and atServer binaries, builds and starts the
virtualenv container, installs the demo atSigns' PKAM keys, and runs the pack
between the VE's `@alice🛠` and `@bob🛠` — two separate atServers, so the
cross-atSign paths (notify, plookup, cached keys, pol-authenticated
`lookup:all`) are genuinely exercised.

Pass a base port to shift the whole VE port range, so it doesn't clash with
another virtualenv already running (`at_functional_test/runLocal.sh` takes the
same argument):

```sh
./runLocal.sh 30000
```

`config/config.yaml` and `test/at_demo_data.dart` are rewritten for the run and
restored when it exits — the same two files the CI job swaps.