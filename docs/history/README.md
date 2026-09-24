# Design history

These are the plans, spikes and investigations behind flutter_cef's features. They are kept for the reasoning they record. None of them describes the current code; where one disagrees with the code, the code is right.

For how things work today, read [README](../../README.md), [PORTING](../../PORTING.md), [CONTRIBUTING](../../CONTRIBUTING.md) and the [wire protocol](../../packages/flutter_cef_windows/native/cef_host/PROTOCOL.md).

| Record | What it was | Outcome |
|---|---|---|
| [cross-platform/PLAN.md](cross-platform/PLAN.md) | The split into federated packages (`flutter_cef`, `_platform_interface`, `_macos`, `_windows`). | Done. |
| [persistent-profiles/PLAN.md](persistent-profiles/PLAN.md), [CONTRACT.md](persistent-profiles/CONTRACT.md) | Named, persistent, shared browser profiles: one `cef_host` per profile. | Shipped in 0.2.0. CONTRACT.md was frozen for the wire format of that time, which has since moved on (see `tool/protocol/spec.dart`). |
| [persistent-profiles/SECURITY-REVIEW.md](persistent-profiles/SECURITY-REVIEW.md) | A security review of the profile work. | Its fixes landed. One point is superseded: camera and microphone entitlements were later restored in release builds, once a deny-by-default permission handler shipped (camera/mic prompts). |
| [agent-control/PLAN.md](agent-control/PLAN.md) | Per-tile, opt-in Chrome DevTools Protocol access for agents. | Shipped, with the tile-isolation relay. |
| [prebuilt-cef-host/PLAN.md](prebuilt-cef-host/PLAN.md) | Shipping a prebuilt `cef_host` keyed by a hash of its native inputs. | Shipped, but hosted differently: prebuilts are GitHub Releases (`cef-host-<hash>`) published by hand with `make publish-cef-host`, not GCS or Codemagic. |
| [windows-port/PLAN.md](windows-port/PLAN.md), [SPIKES.md](windows-port/SPIKES.md) | The Windows port and the spikes that de-risked it (D3D11 shared textures, named pipes, the bootstrap executable). | Shipped. |
| [osr-many-views.md](osr-many-views.md), [osr-ecosystem-survey.md](osr-ecosystem-survey.md) | Why many animating off-screen views on one GPU process starve, and how other OSR embedders cope. | Led to host groups and create pacing. |
| [OSR_SCALE_MISMATCH.md](OSR_SCALE_MISMATCH.md) | A zoom scale mismatch that left a view frozen but still interactive. | Fixed. |
| [OSR_VISIBILITY_RESIZE_AUDIT.md](OSR_VISIBILITY_RESIZE_AUDIT.md) | An audit of visibility, resize, culling and lifecycle in the off-screen path. | Its fixes landed. |
