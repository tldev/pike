mod builder;

use clap::Parser;

#[derive(Parser, Debug)]
#[command(
    name = "pike-export",
    about = "Build Pike SQLite packs from OpenInterstate release artifacts"
)]
struct Cli {
    /// Extracted OpenInterstate release directory containing manifest.json and csv/*
    #[arg(long)]
    release_dir: std::path::PathBuf,

    /// Output SQLite file path
    #[arg(short, long, default_value = "pike.sqlite")]
    output: std::path::PathBuf,

    /// Reachability scores CSV from openinterstate-reachability
    #[arg(long)]
    reachability_snapshot_csv: std::path::PathBuf,
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "pike_export=info".into()),
        )
        .init();

    builder::run(Cli::parse())
}
