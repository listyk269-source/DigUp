//! Opt-in startup for the current Windows user. No elevation, scripts, or PATH lookup.

#[cfg(windows)]
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

#[cfg(windows)]
fn startup_command(executable: &std::path::Path) -> String {
    format!("\"{}\"", executable.display())
}

pub fn enabled() -> bool {
    #[cfg(windows)]
    {
        let Ok(executable) = std::env::current_exe() else {
            return false;
        };
        let Ok(key) = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER).open_subkey(RUN_KEY)
        else {
            return false;
        };
        key.get_value::<String, _>("DigUp").ok() == Some(startup_command(&executable))
    }
    #[cfg(not(windows))]
    {
        false
    }
}

pub fn set(enabled: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        let (key, _) = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
            .create_subkey(RUN_KEY)
            .map_err(|error| format!("Can't change launch at sign-in: {error}"))?;
        if enabled {
            let executable = std::env::current_exe().map_err(|error| error.to_string())?;
            key.set_value("DigUp", &startup_command(&executable))
                .map_err(|error| error.to_string())
        } else {
            match key.delete_value("DigUp") {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error.to_string()),
            }
        }
    }
    #[cfg(not(windows))]
    {
        if enabled {
            Err("Launch at sign-in is currently available in the Windows shell.".into())
        } else {
            Ok(())
        }
    }
}

#[cfg(all(test, windows))]
mod tests {
    #[test]
    fn startup_path_with_spaces_and_unicode_is_quoted() {
        assert_eq!(
            super::startup_command(std::path::Path::new(r"C:\Программы\DigUp 🚀\DigUp.exe")),
            "\"C:\\Программы\\DigUp 🚀\\DigUp.exe\""
        );
    }
}
