# Client checks

Runs at_client_sdk's live packs against an atServer built from this
checkout, so a change that breaks the reference SDK shows up before it
reaches trunk.

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
project name and ports. The `onboarding_cli_proxy` pack needs a base port.
The header of [`runLocal.sh`](runLocal.sh) says what each step does and what
the proxy pack needs from the host.
