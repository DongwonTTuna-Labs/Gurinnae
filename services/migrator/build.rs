#![forbid(unsafe_code)]

fn main() {
    // SQLx tracks the files present during macro expansion, so make newly
    // added migrations invalidate a cached embedded migrator as well.
    println!("cargo:rerun-if-changed=../../db/migrations");
}
