# Client checks

Runs at_client_sdk's live packs against an atServer built from this
checkout, so an atServer change that breaks the reference SDK shows up
before it reaches trunk. The packs' other dependencies, this repo's
at_persistence packages among them, come from pub.dev.

```sh
./runLocal.sh                    # functional and e2e, on each pack's default ports
./runLocal.sh 27000              # the same, on ports 27000-27099
./runLocal.sh 27000 functional e2e onboarding_cli onboarding_cli_proxy
```

The packs come from an at_client_sdk clone, `AT_CLIENT_SDK_DIR` (default:
`at_client_sdk` beside this checkout), at `AT_CLIENT_SDK_REF` (default:
`origin/trunk`). Set `AT_CLIENT_SDK_REF` to an earlier commit to test the SDK
as it was then; one whose pack runners do not take `VIRTUALENV_IMAGE`, and
name their compose project after the base port, is refused. Pass a base port
to keep a run apart from others: with none, each pack uses its default
project name and ports, and with one, a pack whose compose project another
run is using fails without starting. The `onboarding_cli_proxy` pack needs a
base port, and every pack needs the host to resolve `vip.ve.atsign.zone` to
127.0.0.1.

A pack passes only if it finishes within `CLIENT_CHECKS_PACK_MINUTES`
(default 45), and its virtualenv ran the image built for the run, by id where
compose records one, in the compose project named after the base port when
there is one. That checks the pack's own containers, not which atServer each
test reached. The header of [`runLocal.sh`](runLocal.sh) says what each step
does.

CI runs the functional and e2e packs from at_client_sdk's trunk, in the
`client_checks` job of
[`at_server.yaml`](../../.github/workflows/at_server.yaml). When
`GITHUB_STEP_SUMMARY` is set, the runner appends to it, as each becomes
known, what it is testing, each pack's result, and why the run was refused,
stopped or ended early. What it is testing includes the at_ packages the
packs took from pub.dev, since a re-run tests at_client_sdk's trunk as it is
then and resolves those afresh.
