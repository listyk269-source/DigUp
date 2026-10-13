fn main() {
    // The pages are embedded at compile time; without this a change to them alone wouldn't rebuild the app.
    println!("cargo:rerun-if-changed=../ui");
    println!("cargo:rerun-if-changed=windows-app-manifest.xml");
    tauri_build::try_build(
        tauri_build::Attributes::new().windows_attributes(
            tauri_build::WindowsAttributes::new()
                .app_manifest(include_str!("windows-app-manifest.xml")),
        ),
    )
    .expect("failed to prepare Tauri resources")
}
