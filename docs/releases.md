# Community releases

## v0.1.0-beta.1 — September 29, 2026

Initial experimental community release of the direct local Hydrific Droplet Edge driver.

- Local discovery and pairing; runs on a compatible SmartThings hub without an MQTT broker or always-on computer.
- Flow in selectable L/min or US gal/min. Unit changes were verified in both directions on the paired hub without reconnecting.
- Volume change since the preceding report in mL, plus connection, cloud, and signal status.
- Numeric flow conditions available for user-created SmartThings routines.
- Physical testing on a SmartThings V3 hub and Droplet firmware v1.4.1. Broader hub and firmware compatibility has not been verified.
- 13 protocol/parser tests and 10 lifecycle tests passed during development. Screenshots demonstrate live readings and an enabled routine; they do not establish end-to-end notification reliability.

### Known limitations

High-flow and unusual-flow alert messages were absent during firmware v1.4.1 testing. Those statuses remain unavailable (—). A matching upstream report is linked in the README. Numeric flow reporting is separate from these alert statuses.

Volume is a per-report change, not a daily or lifetime total. Negative values are preserved. Flow unit selection does not change volume units. Older history entries retain their recorded units.

Development installs using the original `dropletflow` capability migrate to `dropletflowrate`. Any routines using the original capability must select the new Flow rate condition again. Review numeric thresholds whenever changing flow units.

### Published package

- Channel: Hydrific Droplet — Community (Experimental)
- Channel ID: `10bfb97f-cd3d-4b71-84b7-3a83090bd51f`
- Driver ID: `fa324980-8b98-41fe-952c-d500e8d8bce1`
- SmartThings package version: `2026-09-29T05:14:34.851119706`
- Driver source commit: `3c63e12`

Public releases are selected explicitly from tested driver versions. The community channel is separate from the development channel. No future updates or support are promised.
