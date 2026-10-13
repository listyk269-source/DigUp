//! Installed resources are resolved relative to the app, never by searching the user's PATH.

use std::path::{Path, PathBuf};

pub fn helper_candidates(
    executable: &Path,
    resources: Option<&Path>,
    windows: bool,
) -> Vec<PathBuf> {
    let name = if windows { "digup.exe" } else { "digup" };
    let mut candidates = Vec::new();
    if let Some(resources) = resources {
        candidates.push(resources.join("helper").join(name));
    }
    if let Some(folder) = executable.parent() {
        candidates.push(folder.join("helper").join(name));
        // DigUp.exe is the GUI on Windows. A sibling named digup.exe is the same file there.
        if !windows {
            candidates.push(folder.join(name));
        }
    }
    candidates.dedup();
    candidates
}

pub fn resolve_helper(
    explicit: Option<&Path>,
    executable: &Path,
    resources: Option<&Path>,
) -> PathBuf {
    if let Some(explicit) = explicit {
        return std::path::absolute(explicit).unwrap_or_else(|_| explicit.to_path_buf());
    }
    let candidates = helper_candidates(executable, resources, cfg!(windows));
    candidates
        .iter()
        .find(|candidate| candidate.is_file())
        .cloned()
        .or_else(|| candidates.into_iter().next())
        .unwrap_or_else(|| {
            executable
                .join("helper")
                .join(if cfg!(windows) { "digup.exe" } else { "digup" })
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_never_resolves_the_gui_as_its_own_helper() {
        let exe = Path::new("/Program Files/DigUp/DigUp.exe");
        let candidates = helper_candidates(exe, None, true);
        assert_eq!(
            candidates,
            vec![PathBuf::from("/Program Files/DigUp/helper/digup.exe")]
        );
        assert!(!candidates.iter().any(|path| path
            .to_string_lossy()
            .eq_ignore_ascii_case(&exe.to_string_lossy())));
    }

    #[test]
    fn resource_directory_is_preferred_and_unicode_is_preserved() {
        let candidates = helper_candidates(
            Path::new("/Программы/DigUp 🚀/DigUp.exe"),
            Some(Path::new("/Ресурсы с пробелами/日本語")),
            true,
        );
        assert_eq!(
            candidates[0],
            Path::new("/Ресурсы с пробелами/日本語/helper/digup.exe")
        );
        assert_eq!(
            candidates[1],
            Path::new("/Программы/DigUp 🚀/helper/digup.exe")
        );
    }

    #[test]
    fn unix_development_layout_remains_supported() {
        assert_eq!(
            helper_candidates(Path::new("/opt/digup/digup-shell"), None, false),
            vec![
                PathBuf::from("/opt/digup/helper/digup"),
                PathBuf::from("/opt/digup/digup")
            ]
        );
    }

    #[cfg(windows)]
    #[test]
    fn unc_and_extended_length_paths_keep_their_prefix() {
        for folder in [r"\\server\Общие документы", r"\\?\C:\Каталог с пробелами"]
        {
            let exe = Path::new(folder).join("DigUp.exe");
            assert_eq!(
                helper_candidates(&exe, None, true)[0],
                Path::new(folder).join("helper").join("digup.exe")
            );
        }
    }
}
