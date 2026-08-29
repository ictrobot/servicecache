fn main() {
    if let Err(error) = servicecache::run_cli() {
        eprintln!("error: {error:#}");
        std::process::exit(1);
    }
}
