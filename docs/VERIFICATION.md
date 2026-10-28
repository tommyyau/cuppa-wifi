# Verification guide

Run checks against the revision you intend to use. Historical installation
logs and private visit records are not release acceptance for a new clone.
[CONTRIBUTING.md](../CONTRIBUTING.md) explains test selection.

| Check | What it establishes |
| --- | --- |
| `make parity-audit` | Frozen case inventory and existing native test mappings |
| Native Swift suites | Core, engine, portal and network contracts with synthetic inputs |
| `make js-test` | JavaScript form, consent and credential handling |
| `make swift-test` | UI/state, Persona and service regressions |
| `make webview-smoke` | Real WebKit fixture journeys; reports model skips explicitly |
| `make local-model-smoke` | Actual Apple on-device model calls on a supported Mac |
| `make app` | Release checks and local ad-hoc-signed bundle packaging |

A submitted form or successful fixture page is not evidence of internet access.
The browser fixtures validate the grant independently. Model passes require
actual recorded calls and validated decisions; a skip is not inference proof.
These automated checks do not establish fresh live venue compatibility.

For a release, also inspect production UI previews, verify the bundle signature
and running executable, and perform the [venue acceptance](FIELD_TEST.md)
scenarios. Report local builds, hosted CI, actual inference and live venue
checks separately. No signed or notarised public download is provided yet.
