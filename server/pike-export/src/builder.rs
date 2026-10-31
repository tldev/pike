use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::File;
use std::path::Path;

use anyhow::{bail, Context};
use chrono::{SecondsFormat, Utc};
use csv::ReaderBuilder;
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::Value;

use crate::Cli;

/// Current SQLite pack schema version. Keep in sync with `BundledPack.supportedSchema`.
const SCHEMA_VERSION: i32 = 5;

const ANCHOR_STEP_POINTS: usize = 40;

#[derive(Debug, Deserialize)]
struct ReleaseManifest {
    release_id: String,
}

#[derive(Debug, Deserialize)]
struct CorridorEdgeCsvRow {
    edge_id: String,
    corridor_id: i32,
    interstate_name: String,
    geometry_geojson: String,
}

#[derive(Debug, Deserialize)]
struct CorridorExitCsvRow {
    exit_id: String,
    corridor_id: i32,
    sequence_index: i32,
    exit_number: String,
    exit_name: String,
    lat: String,
    lon: String,
}

#[derive(Debug, Deserialize)]
struct PlaceCsvRow {
    place_id: String,
    category: String,
    name: String,
    display_name: String,
    geometry_geojson: String,
}

#[derive(Debug, Deserialize)]
struct ExitPlaceLinkCsvRow {
    exit_id: String,
    place_id: String,
    category: String,
    distance_m: i64,
    rank: i32,
}

#[derive(Debug, Deserialize)]
struct ReferenceRouteCsvRow {
    reference_route_id: String,
    interstate_name: String,
    direction_code: String,
    direction_label: String,
    distance_m: String,
    duration_s: String,
    geometry_geojson: String,
}

#[derive(Debug, Deserialize, Clone)]
struct ReachabilitySnapshotRow {
    exit_id: String,
    place_id: String,
    #[serde(default)]
    route_distance_m: Option<i64>,
    #[serde(default)]
    route_duration_s: Option<i64>,
}

type ReachabilitySnapshot = HashMap<(String, String), ReachabilitySnapshotRow>;

#[derive(Debug)]
struct PackData {
    manifest: ReleaseManifest,
    build_generated_at: String,
    pois: Vec<PoiRow>,
    exit_pois: Vec<ExitPoiRow>,
    corridor_exits: Vec<CorridorExitRow>,
    edges: Vec<EdgeRow>,
    test_drive_routes: Vec<TestDriveRouteRow>,
    test_drive_route_anchors: Vec<TestDriveRouteAnchorRow>,
}

#[derive(Debug, Clone)]
struct PoiRow {
    id: String,
    category: Option<String>,
    name: Option<String>,
    display_name: Option<String>,
    lat: f64,
    lon: f64,
}

#[derive(Debug, Clone)]
struct ExitPoiRow {
    exit_id: String,
    poi_id: String,
    category: String,
    distance_m: i64,
    rank: i32,
    estimated_drive_m: Option<i64>,
    estimated_drive_s: Option<i64>,
}

#[derive(Debug, Clone)]
struct CorridorExitRow {
    corridor_id: i32,
    corridor_index: i32,
    exit_id: String,
    reference: Option<String>,
    name: Option<String>,
    lat: f64,
    lon: f64,
}

#[derive(Debug, Clone)]
struct EdgeRow {
    highway: String,
    corridor_id: i32,
    bounds: Bounds,
    polyline_json: String,
}

#[derive(Debug, Clone)]
struct TestDriveRouteRow {
    id: String,
    highway: String,
    direction_code: String,
    direction_label: String,
    variant_rank: i32,
    distance_m: f64,
    interval_s: f64,
    waypoints: Vec<[f64; 2]>,
}

#[derive(Debug, Clone)]
struct TestDriveRouteAnchorRow {
    route_id: String,
    anchor_index: i32,
    lat: f64,
    lon: f64,
}

#[derive(Debug, Clone)]
struct Bounds {
    min_lat: f64,
    max_lat: f64,
    min_lon: f64,
    max_lon: f64,
}

pub fn run(cli: Cli) -> anyhow::Result<()> {
    let pack = build_pack(&cli)?;

    if cli.output.exists() {
        std::fs::remove_file(&cli.output)
            .with_context(|| format!("removing previous output {}", cli.output.display()))?;
    }

    write_sqlite(&pack, &cli.output)?;
    tracing::info!(
        "Pack build complete: file={} size_bytes={}",
        cli.output.display(),
        std::fs::metadata(&cli.output)?.len()
    );

    Ok(())
}

fn build_pack(cli: &Cli) -> anyhow::Result<PackData> {
    let manifest_path = cli.release_dir.join("manifest.json");
    let csv_dir = cli.release_dir.join("csv");
    if !manifest_path.is_file() {
        bail!("missing release manifest: {}", manifest_path.display());
    }
    if !csv_dir.is_dir() {
        bail!("missing release csv directory: {}", csv_dir.display());
    }

    let manifest: ReleaseManifest = serde_json::from_reader(
        File::open(&manifest_path).with_context(|| manifest_path.display().to_string())?,
    )
    .context("parsing release manifest.json")?;

    let snapshot = load_snapshot(&cli.reachability_snapshot_csv)?;

    let corridor_exits = load_corridor_exits(&csv_dir.join("corridor_exits.csv"))?;
    let edges = load_edges(&csv_dir.join("corridor_edges.csv"))?;
    let mut pois = load_places(&csv_dir.join("places.csv"))?;
    let mut exit_pois = load_exit_place_links(&csv_dir.join("exit_place_links.csv"), &snapshot)?;

    let known_exits: HashSet<&str> = corridor_exits.iter().map(|ce| ce.exit_id.as_str()).collect();
    if let Some(link) = exit_pois.iter().find(|ep| !known_exits.contains(ep.exit_id.as_str())) {
        bail!("exit_place_links references unknown exit {}", link.exit_id);
    }

    // Drop POIs with no usable name (both name and display_name are NULL).
    let before_nameless = pois.len();
    let nameless_ids: std::collections::HashSet<String> = pois
        .iter()
        .filter(|p| p.display_name.is_none() && p.name.is_none())
        .map(|p| p.id.clone())
        .collect();
    if !nameless_ids.is_empty() {
        pois.retain(|p| !nameless_ids.contains(&p.id));
        exit_pois.retain(|ep| !nameless_ids.contains(&ep.poi_id));
        tracing::info!(
            "Dropped {} nameless POIs ({} → {})",
            nameless_ids.len(),
            before_nameless,
            pois.len()
        );
    }

    // Same-name dedup MUST run before cross-exit dedup: it rewrites poi_ids so
    // that node+way duplicates share a single canonical ID, which cross-exit
    // dedup then uses to detect shared POIs across exits on the same corridor.
    dedup_same_name_pois(&mut pois, &mut exit_pois);
    dedup_cross_exit_pois(&mut exit_pois, &corridor_exits);

    let test_drive_routes = load_reference_routes(&csv_dir.join("reference_routes.csv"))?;
    let test_drive_route_anchors = build_route_anchors(&test_drive_routes);

    Ok(PackData {
        manifest,
        build_generated_at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
        pois,
        exit_pois,
        corridor_exits,
        edges,
        test_drive_routes,
        test_drive_route_anchors,
    })
}

fn load_snapshot(path: &Path) -> anyhow::Result<ReachabilitySnapshot> {
    let rows = load_csv::<ReachabilitySnapshotRow>(path)?;
    let by_pair: ReachabilitySnapshot = rows
        .into_iter()
        .map(|row| ((row.exit_id.clone(), row.place_id.clone()), row))
        .collect();

    tracing::info!("Loaded reachability snapshot: rows={}", by_pair.len());

    Ok(by_pair)
}

fn load_corridor_exits(path: &Path) -> anyhow::Result<Vec<CorridorExitRow>> {
    load_csv::<CorridorExitCsvRow>(path)?
        .into_iter()
        .map(|row| {
            Ok(CorridorExitRow {
                corridor_id: row.corridor_id,
                corridor_index: row.sequence_index,
                reference: normalized_option(&row.exit_number),
                name: normalized_option(&row.exit_name),
                lat: parse_f64(&row.lat, "corridor_exits.lat")?,
                lon: parse_f64(&row.lon, "corridor_exits.lon")?,
                exit_id: row.exit_id,
            })
        })
        .collect()
}

fn load_edges(path: &Path) -> anyhow::Result<Vec<EdgeRow>> {
    let rows = load_csv::<CorridorEdgeCsvRow>(path)?;
    let mut out = Vec::with_capacity(rows.len());

    for row in rows {
        let waypoints = parse_line_geometry(&row.geometry_geojson)
            .with_context(|| format!("parsing edge geometry {}", row.edge_id))?;
        out.push(EdgeRow {
            highway: row.interstate_name,
            corridor_id: row.corridor_id,
            bounds: bounds_for_points(&waypoints)?,
            polyline_json: serde_json::to_string(&waypoints)?,
        });
    }

    Ok(out)
}

fn load_places(path: &Path) -> anyhow::Result<Vec<PoiRow>> {
    let rows = load_csv::<PlaceCsvRow>(path)?;
    let mut pois_by_id = BTreeMap::new();

    for row in rows {
        let [lat, lon] = parse_point_geometry(&row.geometry_geojson)
            .with_context(|| format!("parsing place geometry {}", row.place_id))?;

        pois_by_id.entry(row.place_id.clone()).or_insert_with(|| PoiRow {
            id: row.place_id.clone(),
            category: normalized_option(&row.category),
            name: normalized_option(&row.name),
            display_name: normalized_option(&row.display_name),
            lat,
            lon,
        });
    }

    Ok(pois_by_id.into_values().collect())
}

fn load_exit_place_links(
    path: &Path,
    snapshot: &ReachabilitySnapshot,
) -> anyhow::Result<Vec<ExitPoiRow>> {
    let rows = load_csv::<ExitPlaceLinkCsvRow>(path)?;
    let mut deduped: BTreeMap<(String, String), ExitPoiRow> = BTreeMap::new();

    for row in rows {
        let snapshot_row = snapshot.get(&(row.exit_id.clone(), row.place_id.clone()));
        let candidate = ExitPoiRow {
            estimated_drive_m: snapshot_row.and_then(|it| it.route_distance_m),
            estimated_drive_s: snapshot_row.and_then(|it| it.route_duration_s),
            exit_id: row.exit_id,
            poi_id: row.place_id,
            category: row.category,
            distance_m: row.distance_m,
            rank: row.rank,
        };

        let key = (candidate.exit_id.clone(), candidate.poi_id.clone());
        match deduped.get(&key) {
            Some(existing) if !candidate_is_better(&candidate, existing) => {}
            _ => {
                deduped.insert(key, candidate);
            }
        }
    }

    let out: Vec<ExitPoiRow> = deduped.into_values().collect();
    let matched = out
        .iter()
        .filter(|row| row.estimated_drive_m.is_some() || row.estimated_drive_s.is_some())
        .count();

    tracing::info!(
        "Merged exit/place links with reachability snapshot: matched={} unmatched={}",
        matched,
        out.len() - matched
    );

    Ok(out)
}

fn candidate_is_better(candidate: &ExitPoiRow, existing: &ExitPoiRow) -> bool {
    candidate
        .rank
        .cmp(&existing.rank)
        .then_with(|| candidate.distance_m.cmp(&existing.distance_m))
        .then_with(|| candidate.category.cmp(&existing.category))
        == Ordering::Less
}

/// Deduplicate POIs with the same name and category within ~100m.
///
/// When OSM has both a node and a way for the same business (e.g. the building
/// polygon and a node inside it), they get separate POI IDs but are the same
/// place. Keep the one with the shorter ID (node IDs tend to be shorter) as a
/// tiebreaker. Rewrites exit_pois to point at the surviving POI.
///
/// Uses `name` (not `display_name`) for the dedup key to avoid false merges
/// where different businesses share a display name but have distinct OSM names.
///
/// To handle POIs that straddle a grid cell boundary, each POI checks its own
/// cell plus all 8 adjacent cells for existing matches.
fn dedup_same_name_pois(
    pois: &mut Vec<PoiRow>,
    exit_pois: &mut Vec<ExitPoiRow>,
) {
    // ~100m quantization grid (0.001° ≈ 111m at equator)
    const GRID: f64 = 0.001;

    // Build (name, category, lat_grid, lon_grid) → canonical poi_id.
    // A canonical POI is registered in its own cell; later POIs check
    // their cell plus all 8 neighbors for an existing canonical match.
    let mut canonical: HashMap<(String, String, i64, i64), String> = HashMap::new();
    // Map replaced poi_id → canonical poi_id
    let mut replacements: HashMap<String, String> = HashMap::new();

    // Sort so nodes come before ways: node POIs have more precise coordinates.
    // "node/" < "way/" lexicographically, so a plain alphabetical sort works.
    pois.sort_by(|a, b| a.id.cmp(&b.id));

    // Offsets for the cell itself plus 8 neighbors.
    const NEIGHBOR_OFFSETS: [(i64, i64); 9] = [
        (0, 0), (-1, -1), (-1, 0), (-1, 1),
        (0, -1),           (0, 1),
        (1, -1),  (1, 0),  (1, 1),
    ];

    for poi in pois.iter() {
        // Use `name` consistently for dedup key (not display_name) to avoid
        // false merges where different businesses share a formatted display name.
        let name = match poi.name.as_ref() {
            Some(n) if !n.is_empty() && n != "Unknown" => n.to_lowercase(),
            _ => continue,
        };
        // POIs without a category cannot be deduped (they won't appear in
        // exit_pois either, so this is harmless).
        let cat = match poi.category.as_ref() {
            Some(c) => c.clone(),
            None => continue,
        };
        let lat_key = (poi.lat / GRID).round() as i64;
        let lon_key = (poi.lon / GRID).round() as i64;

        // Check own cell + 8 neighbors for an existing canonical match.
        let existing = NEIGHBOR_OFFSETS.iter().find_map(|(dlat, dlon)| {
            let key = (name.clone(), cat.clone(), lat_key + dlat, lon_key + dlon);
            canonical.get(&key).cloned()
        });

        if let Some(canonical_id) = existing {
            replacements.insert(poi.id.clone(), canonical_id);
        } else {
            // Register this POI as canonical in its own cell.
            let key = (name, cat, lat_key, lon_key);
            canonical.insert(key, poi.id.clone());
        }
    }

    if replacements.is_empty() {
        return;
    }

    // Remove replaced POIs
    let replaced_ids: HashSet<&str> = replacements.keys().map(|s| s.as_str()).collect();
    pois.retain(|p| !replaced_ids.contains(p.id.as_str()));

    // Rewrite exit_pois to point at canonical POI, then dedup (exit, poi) pairs
    for ep in exit_pois.iter_mut() {
        if let Some(canonical_id) = replacements.get(&ep.poi_id) {
            ep.poi_id = canonical_id.clone();
        }
    }

    // After rewriting, we may have duplicate (exit_id, poi_id) pairs — keep the best.
    // Vec::retain visits elements in order (guaranteed by spec), so the index
    // counter stays synchronized with the keep flags.
    let mut seen: HashMap<(String, String), usize> = HashMap::new();
    let mut keep = vec![true; exit_pois.len()];
    for (i, ep) in exit_pois.iter().enumerate() {
        let key = (ep.exit_id.clone(), ep.poi_id.clone());
        match seen.entry(key) {
            std::collections::hash_map::Entry::Occupied(entry) => {
                let prev_idx = *entry.get();
                if candidate_is_better(ep, &exit_pois[prev_idx]) {
                    keep[prev_idx] = false;
                    *entry.into_mut() = i;
                } else {
                    keep[i] = false;
                }
            }
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(i);
            }
        }
    }
    let mut idx = 0;
    exit_pois.retain(|_| {
        let k = keep[idx];
        idx += 1;
        k
    });

    tracing::info!(
        "Same-name POI dedup: removed {} duplicate POIs (kept canonical versions)",
        replacements.len()
    );
}

/// For each corridor, if a POI is linked to multiple exits, keep only the link
/// with the best reachability (shortest drive time, or shortest distance if no
/// drive data). This prevents distant exits from showing the same POI with an
/// unreasonably long drive time.
///
/// Suppression is per-(corridor, poi) pair: a link is only removed if it loses
/// to a better link for EVERY corridor it participates in. A link that is the
/// best for any one corridor is preserved.
fn dedup_cross_exit_pois(
    exit_pois: &mut Vec<ExitPoiRow>,
    corridor_exits: &[CorridorExitRow],
) {
    // Build exit_id → set of corridor_ids
    let mut exit_corridors: HashMap<&str, HashSet<i32>> = HashMap::new();
    for ce in corridor_exits {
        exit_corridors
            .entry(&ce.exit_id)
            .or_default()
            .insert(ce.corridor_id);
    }

    // For each (corridor_id, poi_id), find the best exit-POI link index.
    let mut best_by_corridor_poi: HashMap<(i32, String), usize> = HashMap::new();

    for (i, ep) in exit_pois.iter().enumerate() {
        let corridors = match exit_corridors.get(ep.exit_id.as_str()) {
            Some(c) => c,
            None => continue,
        };

        for &corridor_id in corridors {
            let key = (corridor_id, ep.poi_id.clone());
            match best_by_corridor_poi.entry(key) {
                std::collections::hash_map::Entry::Occupied(mut entry) => {
                    let prev_idx = *entry.get();
                    let prev = &exit_pois[prev_idx];
                    if drive_score(ep) < drive_score(prev) {
                        entry.insert(i);
                    }
                }
                std::collections::hash_map::Entry::Vacant(entry) => {
                    entry.insert(i);
                }
            }
        }
    }

    // A link survives if it is the best for at least one corridor.
    let winners: HashSet<usize> = best_by_corridor_poi.values().copied().collect();

    // Build the set of links that participate in corridor competition at all.
    // Links whose exit has no corridor mapping are never suppressed.
    let mut competed: HashSet<usize> = HashSet::new();
    for (i, ep) in exit_pois.iter().enumerate() {
        if exit_corridors.contains_key(ep.exit_id.as_str()) {
            competed.insert(i);
        }
    }

    let suppress: HashSet<usize> = competed.difference(&winners).copied().collect();
    if suppress.is_empty() {
        return;
    }

    let original_len = exit_pois.len();
    // Vec::retain visits elements in order (guaranteed by spec), so the index
    // counter stays synchronized with the suppress set.
    let mut idx = 0;
    exit_pois.retain(|_| {
        let keep = !suppress.contains(&idx);
        idx += 1;
        keep
    });

    tracing::info!(
        "Cross-exit POI dedup: removed {} redundant exit-POI links ({} → {})",
        original_len - exit_pois.len(),
        original_len,
        exit_pois.len()
    );
}

/// Score for cross-exit dedup comparison. Lower is better.
/// Prefers shortest drive time, then shortest route distance, then shortest
/// straight-line distance as final tiebreaker.
fn drive_score(ep: &ExitPoiRow) -> (i64, i64, i64) {
    (
        ep.estimated_drive_s.unwrap_or(i64::MAX),
        ep.estimated_drive_m.unwrap_or(i64::MAX),
        ep.distance_m,
    )
}

fn load_reference_routes(path: &Path) -> anyhow::Result<Vec<TestDriveRouteRow>> {
    let rows = load_csv::<ReferenceRouteCsvRow>(path)?;
    let mut grouped: BTreeMap<(String, String), Vec<TestDriveRouteRow>> = BTreeMap::new();

    for row in rows {
        let waypoints = flatten_route_geometry(&row.geometry_geojson)
            .with_context(|| format!("parsing route geometry {}", row.reference_route_id))?;
        if waypoints.len() < 2 {
            continue;
        }

        let duration_s = parse_f64(&row.duration_s, "reference_routes.duration_s")?;

        grouped
            .entry((row.interstate_name.clone(), row.direction_code.clone()))
            .or_default()
            .push(TestDriveRouteRow {
                id: row.reference_route_id,
                highway: row.interstate_name,
                direction_code: row.direction_code,
                direction_label: row.direction_label,
                variant_rank: 0,
                distance_m: parse_f64(&row.distance_m, "reference_routes.distance_m")?,
                interval_s: duration_s / ((waypoints.len() - 1) as f64),
                waypoints,
            });
    }

    let mut routes = Vec::new();
    for (_, mut group) in grouped {
        group.sort_by(compare_routes);
        for (idx, mut route) in group.into_iter().enumerate() {
            route.variant_rank = (idx + 1) as i32;
            routes.push(route);
        }
    }

    Ok(routes)
}

fn compare_routes(left: &TestDriveRouteRow, right: &TestDriveRouteRow) -> Ordering {
    right
        .distance_m
        .partial_cmp(&left.distance_m)
        .unwrap_or(Ordering::Equal)
        .then_with(|| left.id.cmp(&right.id))
}

fn build_route_anchors(routes: &[TestDriveRouteRow]) -> Vec<TestDriveRouteAnchorRow> {
    let mut anchors = Vec::new();

    for route in routes {
        let mut seen = BTreeSet::new();
        let mut idx = 0usize;
        while idx < route.waypoints.len() {
            seen.insert(idx);
            idx += ANCHOR_STEP_POINTS;
        }
        seen.insert(route.waypoints.len() - 1);

        for anchor_index in seen {
            let point = route.waypoints[anchor_index];
            anchors.push(TestDriveRouteAnchorRow {
                route_id: route.id.clone(),
                anchor_index: anchor_index as i32,
                lat: point[0],
                lon: point[1],
            });
        }
    }

    anchors
}

fn write_sqlite(pack: &PackData, output_path: &Path) -> anyhow::Result<()> {
    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let conn = Connection::open(output_path)?;
    conn.execute_batch(SQLITE_SCHEMA_SQL)?;

    let tx = conn.unchecked_transaction()?;
    insert_meta(&tx, pack)?;
    insert_pois(&tx, &pack.pois)?;
    insert_exit_pois(&tx, &pack.exit_pois)?;
    insert_corridor_exits(&tx, &pack.corridor_exits)?;
    insert_edges(&tx, &pack.edges)?;
    insert_test_drive_routes(&tx, &pack.test_drive_routes)?;
    insert_test_drive_route_anchors(&tx, &pack.test_drive_route_anchors)?;
    tx.commit()?;

    Ok(())
}

fn insert_meta(tx: &rusqlite::Transaction<'_>, pack: &PackData) -> anyhow::Result<()> {
    let meta = [
        ("schema_version", SCHEMA_VERSION.to_string()),
        ("generated_at", pack.build_generated_at.clone()),
        ("source", format!("OpenInterstate {}", pack.manifest.release_id)),
        ("openinterstate_release_id", pack.manifest.release_id.clone()),
    ];

    let mut stmt = tx.prepare("INSERT INTO meta (key, value) VALUES (?1, ?2)")?;
    for (key, value) in meta {
        stmt.execute(rusqlite::params![key, value])?;
    }
    Ok(())
}

fn insert_pois(
    tx: &rusqlite::Transaction<'_>,
    rows: &[PoiRow],
) -> anyhow::Result<()> {
    let mut stmt = tx.prepare(
        "INSERT INTO pois (id, name, display_name, lat, lon) VALUES (?1, ?2, ?3, ?4, ?5)",
    )?;
    for row in rows {
        stmt.execute(rusqlite::params![
            row.id,
            row.name,
            row.display_name,
            row.lat,
            row.lon
        ])?;
    }
    Ok(())
}

fn insert_exit_pois(
    tx: &rusqlite::Transaction<'_>,
    rows: &[ExitPoiRow],
) -> anyhow::Result<()> {
    let mut stmt = tx.prepare(
        "INSERT INTO exit_pois
         (exit_id, poi_id, category, distance_m, rank, estimated_drive_m, estimated_drive_s)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )?;
    for row in rows {
        stmt.execute(rusqlite::params![
            row.exit_id,
            row.poi_id,
            row.category,
            row.distance_m,
            row.rank,
            row.estimated_drive_m,
            row.estimated_drive_s
        ])?;
    }
    Ok(())
}

fn insert_corridor_exits(
    tx: &rusqlite::Transaction<'_>,
    rows: &[CorridorExitRow],
) -> anyhow::Result<()> {
    let mut stmt = tx.prepare(
        "INSERT INTO corridor_exits (corridor_id, corridor_index, exit_id, ref, name, lat, lon)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )?;
    for row in rows {
        stmt.execute(rusqlite::params![
            row.corridor_id,
            row.corridor_index,
            row.exit_id,
            row.reference,
            row.name,
            row.lat,
            row.lon
        ])?;
    }
    Ok(())
}

fn insert_edges(tx: &rusqlite::Transaction<'_>, rows: &[EdgeRow]) -> anyhow::Result<()> {
    let mut edge_stmt = tx.prepare(
        "INSERT INTO highway_edges (highway, corridor_id, polyline_json) VALUES (?1, ?2, ?3)",
    )?;
    let mut rtree_stmt = tx.prepare(
        "INSERT INTO highway_edges_rtree(id, min_lat, max_lat, min_lon, max_lon)
         VALUES (?1, ?2, ?3, ?4, ?5)",
    )?;
    for row in rows {
        let rowid = edge_stmt.insert(rusqlite::params![
            row.highway,
            row.corridor_id,
            row.polyline_json
        ])?;
        rtree_stmt.execute(rusqlite::params![
            rowid,
            row.bounds.min_lat,
            row.bounds.max_lat,
            row.bounds.min_lon,
            row.bounds.max_lon
        ])?;
    }
    Ok(())
}

fn insert_test_drive_routes(
    tx: &rusqlite::Transaction<'_>,
    rows: &[TestDriveRouteRow],
) -> anyhow::Result<()> {
    let mut stmt = tx.prepare(
        "INSERT INTO test_drive_routes
         (id, highway, direction_code, direction_label, variant_rank, distance_m, interval_s, waypoints_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
    )?;
    for row in rows {
        stmt.execute(rusqlite::params![
            row.id,
            row.highway,
            row.direction_code,
            row.direction_label,
            row.variant_rank,
            row.distance_m,
            row.interval_s,
            serde_json::to_string(&row.waypoints)?
        ])?;
    }
    Ok(())
}

fn insert_test_drive_route_anchors(
    tx: &rusqlite::Transaction<'_>,
    rows: &[TestDriveRouteAnchorRow],
) -> anyhow::Result<()> {
    let mut stmt = tx.prepare(
        "INSERT INTO test_drive_route_anchors (route_id, anchor_index, lat, lon)
         VALUES (?1, ?2, ?3, ?4)",
    )?;
    for row in rows {
        stmt.execute(rusqlite::params![
            row.route_id,
            row.anchor_index,
            row.lat,
            row.lon
        ])?;
    }
    Ok(())
}

fn load_csv<T>(path: &Path) -> anyhow::Result<Vec<T>>
where
    T: for<'de> Deserialize<'de>,
{
    let mut reader = ReaderBuilder::new()
        .flexible(true)
        .from_path(path)
        .with_context(|| format!("opening csv {}", path.display()))?;
    let mut out = Vec::new();
    for row in reader.deserialize() {
        out.push(row.with_context(|| format!("parsing row in {}", path.display()))?);
    }
    Ok(out)
}

fn parse_f64(raw: &str, field_name: &str) -> anyhow::Result<f64> {
    raw.parse::<f64>()
        .with_context(|| format!("invalid {field_name}: {raw}"))
}

fn normalized_option(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn parse_point_geometry(raw: &str) -> anyhow::Result<[f64; 2]> {
    let value: Value = serde_json::from_str(raw)?;
    let geometry_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if geometry_type != "Point" {
        bail!("expected Point geometry, found {}", geometry_type);
    }
    let coordinates = value
        .get("coordinates")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("point geometry missing coordinates"))?;
    if coordinates.len() < 2 {
        bail!("point geometry must have lon/lat coordinates");
    }
    let lon = coordinates[0]
        .as_f64()
        .ok_or_else(|| anyhow::anyhow!("point lon is not numeric"))?;
    let lat = coordinates[1]
        .as_f64()
        .ok_or_else(|| anyhow::anyhow!("point lat is not numeric"))?;
    Ok([lat, lon])
}

fn parse_line_geometry(raw: &str) -> anyhow::Result<Vec<[f64; 2]>> {
    let value: Value = serde_json::from_str(raw)?;
    let geometry_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("LineString");
    if geometry_type != "LineString" {
        bail!("expected LineString geometry, found {}", geometry_type);
    }
    parse_line_coordinates(value.get("coordinates"))
}

fn flatten_route_geometry(raw: &str) -> anyhow::Result<Vec<[f64; 2]>> {
    let value: Value = serde_json::from_str(raw)?;
    let geometry_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();

    match geometry_type {
        "LineString" => parse_line_coordinates(value.get("coordinates")),
        "MultiLineString" => {
            let segments = value
                .get("coordinates")
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow::anyhow!("multilinestring missing coordinates"))?;
            let mut out = Vec::new();
            for segment in segments {
                let mut waypoints = parse_line_coordinates(Some(segment))?;
                if out.last().is_some() && waypoints.first() == out.last() {
                    waypoints.remove(0);
                }
                out.extend(waypoints);
            }
            if out.len() < 2 {
                bail!("flattened route must contain at least two points");
            }
            Ok(dedupe_consecutive_points(out))
        }
        other => bail!("unsupported route geometry type: {}", other),
    }
}

fn parse_line_coordinates(value: Option<&Value>) -> anyhow::Result<Vec<[f64; 2]>> {
    let coordinates = value
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("linestring missing coordinates"))?;
    let mut out = Vec::with_capacity(coordinates.len());
    for coordinate in coordinates {
        let pair = coordinate
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("coordinate must be an array"))?;
        if pair.len() < 2 {
            bail!("coordinate must contain lon/lat");
        }
        let lon = pair[0]
            .as_f64()
            .ok_or_else(|| anyhow::anyhow!("coordinate lon must be numeric"))?;
        let lat = pair[1]
            .as_f64()
            .ok_or_else(|| anyhow::anyhow!("coordinate lat must be numeric"))?;
        out.push([lat, lon]);
    }
    if out.len() < 2 {
        bail!("linestring must contain at least two points");
    }
    Ok(dedupe_consecutive_points(out))
}

fn dedupe_consecutive_points(points: Vec<[f64; 2]>) -> Vec<[f64; 2]> {
    let mut out = Vec::with_capacity(points.len());
    for point in points {
        if out.last().is_some_and(|last| *last == point) {
            continue;
        }
        out.push(point);
    }
    out
}

fn bounds_for_points(points: &[[f64; 2]]) -> anyhow::Result<Bounds> {
    let Some(first) = points.first().copied() else {
        bail!("cannot compute bounds for an empty point set");
    };

    let mut bounds = Bounds {
        min_lat: first[0],
        max_lat: first[0],
        min_lon: first[1],
        max_lon: first[1],
    };

    for point in points.iter().skip(1) {
        bounds.min_lat = bounds.min_lat.min(point[0]);
        bounds.max_lat = bounds.max_lat.max(point[0]);
        bounds.min_lon = bounds.min_lon.min(point[1]);
        bounds.max_lon = bounds.max_lon.max(point[1]);
    }

    Ok(bounds)
}

const SQLITE_SCHEMA_SQL: &str = "PRAGMA foreign_keys = ON;

CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE pois (
    id TEXT PRIMARY KEY,
    name TEXT,
    display_name TEXT,
    lat REAL NOT NULL,
    lon REAL NOT NULL
);

CREATE TABLE exit_pois (
    exit_id TEXT NOT NULL,
    poi_id TEXT NOT NULL,
    category TEXT NOT NULL,
    distance_m INTEGER NOT NULL,
    rank INTEGER NOT NULL,
    estimated_drive_m INTEGER,
    estimated_drive_s INTEGER,
    PRIMARY KEY (exit_id, poi_id),
    FOREIGN KEY(poi_id) REFERENCES pois(id)
);

CREATE TABLE corridor_exits (
    corridor_id INTEGER NOT NULL,
    corridor_index INTEGER NOT NULL,
    exit_id TEXT NOT NULL,
    ref TEXT,
    name TEXT,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    PRIMARY KEY (corridor_id, corridor_index)
);

CREATE TABLE highway_edges (
    highway TEXT NOT NULL,
    corridor_id INTEGER NOT NULL,
    polyline_json TEXT NOT NULL
);

CREATE VIRTUAL TABLE highway_edges_rtree USING rtree(
    id, min_lat, max_lat, min_lon, max_lon
);

CREATE TABLE test_drive_routes (
    id TEXT PRIMARY KEY,
    highway TEXT NOT NULL,
    direction_code TEXT NOT NULL,
    direction_label TEXT NOT NULL,
    variant_rank INTEGER NOT NULL,
    distance_m REAL NOT NULL,
    interval_s REAL NOT NULL,
    waypoints_json TEXT NOT NULL
);
CREATE INDEX test_drive_routes_highway_direction
    ON test_drive_routes(highway, direction_code, variant_rank);

CREATE TABLE test_drive_route_anchors (
    route_id TEXT NOT NULL,
    anchor_index INTEGER NOT NULL,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    PRIMARY KEY (route_id, anchor_index),
    FOREIGN KEY(route_id) REFERENCES test_drive_routes(id)
);";

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn flatten_route_geometry_merges_multilinestring_segments() {
        let raw = r#"{
          "type":"MultiLineString",
          "coordinates":[
            [[-97.0,30.0],[-96.5,30.5]],
            [[-96.5,30.5],[-96.0,31.0]]
          ]
        }"#;

        let waypoints = flatten_route_geometry(raw).expect("flatten route");
        assert_eq!(waypoints, vec![[30.0, -97.0], [30.5, -96.5], [31.0, -96.0]]);
    }

    #[test]
    fn route_anchors_include_last_point() {
        let route = TestDriveRouteRow {
            id: "route-1".to_string(),
            highway: "I-10".to_string(),
            direction_code: "EB".to_string(),
            direction_label: "Eastbound".to_string(),
            variant_rank: 1,
            distance_m: 0.0,
            interval_s: 5.0,
            waypoints: (0..45)
                .map(|idx| [30.0, -97.0 + (idx as f64 * 0.01)])
                .collect(),
        };

        let anchors = build_route_anchors(&[route]);
        let anchor_indices: Vec<i32> = anchors.iter().map(|row| row.anchor_index).collect();
        assert_eq!(anchor_indices, vec![0, 40, 44]);
    }

    #[test]
    fn build_pack_writes_sqlite_and_merges_snapshot_rows() {
        let temp = tempdir().expect("tempdir");
        let release_dir = temp.path().join("release");
        let csv_dir = release_dir.join("csv");
        fs::create_dir_all(&csv_dir).expect("create release dir");

        fs::write(
            release_dir.join("manifest.json"),
            r#"{"release_id":"release-test"}"#,
        )
        .expect("write manifest");

        fs::write(
            csv_dir.join("corridor_edges.csv"),
            "edge_id,corridor_id,interstate_name,direction_code,length_m,geometry_geojson\n\
             edge/I-10/1/2,1,I-10,E,1234,\"{\"\"type\"\":\"\"LineString\"\",\"\"coordinates\"\":[[-97.0,30.0],[-96.0,31.0]]}\"\n",
        )
        .expect("write edges");
        fs::write(
            csv_dir.join("corridor_exits.csv"),
            "exit_id,corridor_id,interstate_name,direction_code,sequence_index,exit_number,exit_name,lat,lon,geometry_geojson\n\
             node/100,1,I-10,east,0,1A,Main St,30.0,-97.0,\"{\"\"type\"\":\"\"Point\"\",\"\"coordinates\"\":[-97.0,30.0]}\"\n",
        )
        .expect("write corridor exits");
        fs::write(
            csv_dir.join("places.csv"),
            "place_id,category,name,display_name,brand,geometry_geojson\n\
             node/200,gas,Shell,Shell,Shell,\"{\"\"type\"\":\"\"Point\"\",\"\"coordinates\"\":[-96.9,30.1]}\"\n",
        )
        .expect("write places");
        fs::write(
            csv_dir.join("exit_place_links.csv"),
            "exit_id,place_id,category,distance_m,rank\n\
             node/100,node/200,gas,500,1\n",
        )
        .expect("write links");
        fs::write(
            csv_dir.join("reference_routes.csv"),
            "reference_route_id,interstate_name,direction_code,direction_label,display_name,distance_m,duration_s,point_count,geometry_geojson\n\
             route-long,I-10,EB,Eastbound,I-10 Eastbound Long,1000,100,3,\"{\"\"type\"\":\"\"LineString\"\",\"\"coordinates\"\":[[-97.0,30.0],[-96.5,30.5],[-96.0,31.0]]}\"\n\
             route-short,I-10,EB,Eastbound,I-10 Eastbound Short,500,50,3,\"{\"\"type\"\":\"\"MultiLineString\"\",\"\"coordinates\"\":[[[-97.0,30.0],[-96.75,30.25]],[[-96.75,30.25],[-96.5,30.5]]]}\"\n",
        )
        .expect("write routes");

        let snapshot_path = temp.path().join("reachability.csv");
        fs::write(
            &snapshot_path,
            "exit_id,place_id,route_distance_m,route_duration_s,reachable,reachability_score,reachability_confidence,provider,provider_dataset_version,updated_at\n\
             node/100,node/200,700,80,true,92.5,0.95,osrm,conus-1,2026-03-14T20:00:00Z\n",
        )
        .expect("write snapshot");

        let cli = Cli {
            release_dir: release_dir.clone(),
            output: temp.path().join("pike.sqlite"),
            reachability_snapshot_csv: snapshot_path,
        };

        let pack = build_pack(&cli).expect("build pack data");
        write_sqlite(&pack, &cli.output).expect("write sqlite");

        let db = Connection::open(&cli.output).expect("open sqlite");
        let schema_version: String = db
            .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
            .expect("schema version meta");
        assert_eq!(schema_version, SCHEMA_VERSION.to_string());

        let route_rows: Vec<(String, i32, String)> = {
            let mut stmt = db
                .prepare(
                    "SELECT id, variant_rank, waypoints_json
                     FROM test_drive_routes
                     ORDER BY variant_rank ASC",
                )
                .expect("prepare route query");
            stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .expect("query route rows")
            .map(|row| row.expect("route row"))
            .collect()
        };

        assert_eq!(route_rows.len(), 2);
        assert_eq!(route_rows[0].0, "route-long");
        assert_eq!(route_rows[0].1, 1);
        assert!(route_rows[1].2.contains("[30.25,-96.75]"));

        let estimated_drive_m: Option<i64> = db
            .query_row(
                "SELECT estimated_drive_m FROM exit_pois WHERE exit_id = 'node/100' AND poi_id = 'node/200'",
                [],
                |row| row.get(0),
            )
            .expect("read exit_poi");
        assert_eq!(estimated_drive_m, Some(700));

        let polyline: String = db
            .query_row(
                "SELECT polyline_json FROM highway_edges WHERE corridor_id = 1",
                [],
                |row| row.get(0),
            )
            .expect("read edge polyline");
        assert_eq!(polyline, "[[30.0,-97.0],[31.0,-96.0]]");
    }

    fn make_poi(id: &str, name: &str, category: &str, lat: f64, lon: f64) -> PoiRow {
        PoiRow {
            id: id.to_string(),
            category: Some(category.to_string()),
            name: Some(name.to_string()),
            display_name: None,
            lat,
            lon,
        }
    }

    fn make_exit_poi(exit_id: &str, poi_id: &str, category: &str, distance_m: i64, drive_s: Option<i64>, drive_m: Option<i64>) -> ExitPoiRow {
        ExitPoiRow {
            exit_id: exit_id.to_string(),
            poi_id: poi_id.to_string(),
            category: category.to_string(),
            distance_m,
            rank: 1,
            estimated_drive_m: drive_m,
            estimated_drive_s: drive_s,
        }
    }

    fn make_corridor_exit(exit_id: &str, corridor_id: i32, idx: i32) -> CorridorExitRow {
        CorridorExitRow {
            corridor_id,
            corridor_index: idx,
            exit_id: exit_id.to_string(),
            reference: None,
            name: None,
            lat: 30.0,
            lon: -97.0,
        }
    }

    // --- same-name dedup tests ---

    #[test]
    fn same_name_dedup_merges_within_grid() {
        let mut pois = vec![
            make_poi("node/1", "Shell", "gas", 30.0001, -97.0001),
            make_poi("way/2", "Shell", "gas", 30.0002, -97.0002),
        ];
        let mut exit_pois = vec![
            make_exit_poi("exit/A", "node/1", "gas", 100, Some(60), Some(120)),
            make_exit_poi("exit/A", "way/2", "gas", 110, Some(65), Some(130)),
        ];

        dedup_same_name_pois(&mut pois, &mut exit_pois);

        assert_eq!(pois.len(), 1);
        assert_eq!(pois[0].id, "node/1");
        assert_eq!(exit_pois.len(), 1);
        assert_eq!(exit_pois[0].poi_id, "node/1");
    }

    #[test]
    fn same_name_different_category_no_merge() {
        let mut pois = vec![
            make_poi("node/1", "Shell", "gas", 30.0001, -97.0001),
            make_poi("way/2", "Shell", "food", 30.0002, -97.0002),
        ];
        let mut exit_pois = vec![
            make_exit_poi("exit/A", "node/1", "gas", 100, Some(60), Some(120)),
            make_exit_poi("exit/A", "way/2", "food", 110, Some(65), Some(130)),
        ];

        dedup_same_name_pois(&mut pois, &mut exit_pois);

        assert_eq!(pois.len(), 2);
        assert_eq!(exit_pois.len(), 2);
    }

    #[test]
    fn same_name_adjacent_grid_cell_merges() {
        // 85m apart, straddling a grid cell boundary — should still merge
        // via neighbor-cell check.
        let mut pois = vec![
            make_poi("node/1", "Super 8", "lodging", 30.7497284, -85.55292315),
            make_poi("way/2", "Super 8", "lodging", 30.7498659, -85.552045146),
        ];
        let mut exit_pois = vec![
            make_exit_poi("exit/A", "node/1", "lodging", 684, Some(120), Some(1187)),
            make_exit_poi("exit/A", "way/2", "lodging", 617, Some(110), Some(1095)),
        ];

        dedup_same_name_pois(&mut pois, &mut exit_pois);

        assert_eq!(pois.len(), 1);
        assert_eq!(exit_pois.len(), 1);
    }

    #[test]
    fn same_name_far_apart_no_merge() {
        // 0.003° apart ≈ 330m, beyond even neighbor cells — should not merge.
        let mut pois = vec![
            make_poi("node/1", "Shell", "gas", 30.0000, -97.0000),
            make_poi("way/2", "Shell", "gas", 30.0030, -97.0000),
        ];
        let mut exit_pois = vec![
            make_exit_poi("exit/A", "node/1", "gas", 100, Some(60), Some(120)),
            make_exit_poi("exit/A", "way/2", "gas", 110, Some(65), Some(130)),
        ];

        dedup_same_name_pois(&mut pois, &mut exit_pois);

        assert_eq!(pois.len(), 2);
        assert_eq!(exit_pois.len(), 2);
    }

    // --- cross-exit dedup tests ---

    #[test]
    fn cross_exit_dedup_keeps_shorter_drive_time() {
        let corridor_exits = vec![
            make_corridor_exit("exit/A", 1, 0),
            make_corridor_exit("exit/B", 1, 1),
        ];
        let mut exit_pois = vec![
            make_exit_poi("exit/A", "poi/1", "food", 500, Some(60), Some(2000)),
            make_exit_poi("exit/B", "poi/1", "food", 600, Some(900), Some(27000)),
        ];

        dedup_cross_exit_pois(&mut exit_pois, &corridor_exits);

        assert_eq!(exit_pois.len(), 1);
        assert_eq!(exit_pois[0].exit_id, "exit/A");
    }

    #[test]
    fn cross_exit_dedup_same_poi_two_corridors_both_survive() {
        // exit/A is on corridor 1, exit/B is on corridor 2.
        // Same POI linked to both exits — both should survive since they
        // are the best (only) link on their respective corridors.
        let corridor_exits = vec![
            make_corridor_exit("exit/A", 1, 0),
            make_corridor_exit("exit/B", 2, 0),
        ];
        let mut exit_pois = vec![
            make_exit_poi("exit/A", "poi/1", "food", 500, Some(60), Some(2000)),
            make_exit_poi("exit/B", "poi/1", "food", 600, Some(900), Some(27000)),
        ];

        dedup_cross_exit_pois(&mut exit_pois, &corridor_exits);

        assert_eq!(exit_pois.len(), 2);
    }

    #[test]
    fn cross_exit_dedup_no_drive_data_loses_to_drive_data() {
        let corridor_exits = vec![
            make_corridor_exit("exit/A", 1, 0),
            make_corridor_exit("exit/B", 1, 1),
        ];
        let mut exit_pois = vec![
            make_exit_poi("exit/A", "poi/1", "food", 500, Some(120), Some(2000)),
            make_exit_poi("exit/B", "poi/1", "food", 400, None, None),
        ];

        dedup_cross_exit_pois(&mut exit_pois, &corridor_exits);

        assert_eq!(exit_pois.len(), 1);
        assert_eq!(exit_pois[0].exit_id, "exit/A");
    }

    // --- drive_score tests ---

    #[test]
    fn drive_score_all_none_returns_max() {
        let ep = make_exit_poi("exit/A", "poi/1", "gas", 500, None, None);
        let score = drive_score(&ep);
        assert_eq!(score, (i64::MAX, i64::MAX, 500));
    }
}
