use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn find_file(root: &Path, name: &str) -> Option<PathBuf> {
    let mut stack = vec![root.to_path_buf()];
    while let Some(path) = stack.pop() {
        let entries = fs::read_dir(&path).ok()?;
        for entry in entries.flatten() {
            let entry_path = entry.path();
            if entry_path.file_name().and_then(|s| s.to_str()) == Some(name) {
                return Some(entry_path);
            }
            if entry_path.is_dir() {
                stack.push(entry_path);
            }
        }
    }
    None
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set"));
    let build_dir = out_dir
        .parent()
        .and_then(Path::parent)
        .expect("crate build directory has parent build dir");

    let mut archives = Vec::new();
    for name in ["libcustom_capi.a", "libtesseract.a"] {
        if let Some(path) = find_file(build_dir, name) {
            archives.push(path);
        }
    }

    if !archives.is_empty() {
        println!("cargo:rustc-link-arg=-Wl,--whole-archive");
        for archive in archives {
            println!("cargo:rustc-link-arg={}", archive.display());
        }
        println!("cargo:rustc-link-arg=-Wl,--no-whole-archive");
    }
}
