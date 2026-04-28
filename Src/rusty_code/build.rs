fn main() {
	cxx_build::bridge("src/lib.rs")
        .compile("rusty_code");
    println!("Build-script is running.");
}
