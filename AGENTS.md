# AGENTS.md

Instructions for coding agents working on Pike.

## Philosophy

Only propose solutions you'd be proud of. If you know the right way to do something, commit to it and don't dilute it with a cheaper alternative.

## Project

Pike is an iOS app that shows upcoming highway exits while driving, mimicking interstate logo signs. A SQLite data pack ships inside the app bundle, so every lookup runs on the device and the app works without a connection. There is no backend.

- `Pike/`: iOS app
- `PikeTests/`: unit tests, including tests against the bundled pack
- `server/`: `pike-export`, which builds the data pack, and its release fetch script

## iOS Architecture

1. `LocationManager` provides GPS updates.
2. `ExitService.refreshFeed()` queries the bundled pack for upcoming exits through `GraphStrategy`.
3. `ExitBrowserView` displays exit cards in a horizontally swipeable carousel.
4. `MainMapView` manages the map camera and wires everything together.

Key types:

- `Exit`: highway exit with coordinate, exit number, distance from user
- `ExitCard`: groups POIs by category for one exit
- `POI`: individual point of interest near an exit
- `BundledPack`: opens and validates the pack in the app bundle
- `TestDrivePlayer`: plays back pack-provided routes as simulated driving

### Key Algorithms

**Corridor lock:** locks to a (corridorId, highway) pair with distance-based stickiness.

- `lockBonus = 15 + 85 * (1 - e^(-km/8))`
- `switchThreshold = min(3 + floor(km/10), 8)` consecutive signals needed to switch
- Gradual decay when not confirmed: half-life 60s after 30s staleness, hard expire at 300s

**Edge projection:** projects GPS onto highway edge polylines. If the polyline bearing differs from the user's course by 90 degrees or more, the edge is rejected as the wrong carriageway. The matched edge's `corridor_id` gives the ordered exit sequence from `corridor_exits`.

**Exit stabilization:** holds recently seen exits for up to 3 misses or 30 seconds. Evicts exits that are behind the user (bearing over 90 degrees) or very close (under 160m).

## Xcode Project

The project uses explicit file references, so a new file must be added to `PBXBuildFile`, `PBXFileReference`, the correct `PBXGroup`, and `PBXSourcesBuildPhase`.

## Data Pack

All OSM processing lives upstream. [`openinterstate`](https://github.com/tldev/openinterstate) publishes the interstate data release, [`openinterstate-reachability`](https://github.com/tldev/openinterstate-reachability) publishes drive-time scores, and `pike-export` combines them into `pike.sqlite`. To investigate raw data issues, work upstream. Durable POI filtering rules belong in openinterstate's derive stage, not in `pike-export` or the app.

Features that touch pack data need both sides:

- `pike-export`: SQLite schema in `builder.rs`
- iOS: `POICategory` and `POIPopulator`

`build.sh` pins the bundled pack with `PACK_TAG` and `PACK_SHA256`. To ship new data, update both, bump `BundledPack.supportedSchema` and `SCHEMA_VERSION` in `pike-export` together if the schema changed, and release a new app version.

New packs are built by the Build Pack workflow, which publishes a `pack-*` release. A new reachability release triggers it, or run it manually with pinned release tags.

## Rust

Rust runs in Docker only. Do not run `cargo` on the host.

```bash
docker run --rm -v "$PWD/server":/app -w /app rust:1.88-bookworm cargo test
```

## Workflow

Never commit or push until the user explicitly asks. After making changes:

1. Run `./build.sh --fetch-pack` once, then build for the simulator with `./build.sh`.
2. Run the tests in Xcode or with `xcodebuild test -project Pike.xcodeproj -scheme Pike -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Have the user check behavior with the in-app test drive.
4. Commit only when the user confirms.

## Releasing

`VERSION` and `BUILD_NUMBER` at the top of `build.sh` are the source of truth, and are passed to `xcodebuild` as build settings.

1. Bump `VERSION` and `BUILD_NUMBER` in `build.sh`, and sync `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.pbxproj`.
2. Commit, tag `v<version>`, and push.
3. Run `./build.sh --upload`, which needs the variables below.
4. Select the build in App Store Connect and submit it for review.

Release variables:

- `APP_STORE_CONNECT_API_KEY_ID` and `APP_STORE_CONNECT_API_ISSUER_ID`, with the matching `.p8` in `~/.appstoreconnect/private_keys/`
- `SENTRY_DSN` (optional; crash reporting is off without it)
- `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, and `SENTRY_PROJECT` for dSYM upload (optional)

## Guardrails

- Never commit credentials, or anything specific to one person's machine.
- If script flags or environment variables change, update the docs in the same change.
