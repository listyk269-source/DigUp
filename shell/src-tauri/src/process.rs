//! Own a helper and its Windows job. Closing the job also terminates decoder descendants (FFmpeg).

use std::ops::{Deref, DerefMut};
use std::process::Child;

pub struct HelperProcess {
    child: Child,
    #[cfg(windows)]
    _job: std::os::windows::io::OwnedHandle,
}

impl HelperProcess {
    pub fn new(mut child: Child) -> Result<Self, String> {
        #[cfg(windows)]
        {
            match job(&child) {
                Ok(job) => Ok(Self { child, _job: job }),
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    Err(format!("Can't supervise DigUp's helper: {error}"))
                }
            }
        }
        #[cfg(not(windows))]
        {
            let _ = &mut child;
            Ok(Self { child })
        }
    }
}

impl Deref for HelperProcess {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.child
    }
}

impl DerefMut for HelperProcess {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.child
    }
}

impl Drop for HelperProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(windows)]
fn job(child: &Child) -> std::io::Result<std::os::windows::io::OwnedHandle> {
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::System::JobObjects::*;
    // SAFETY: no attributes/name means a new, non-inheritable job. Each returned handle is owned once and closed
    // automatically. The information buffer is initialized, correctly sized, and valid for the duration of the call.
    unsafe {
        let raw = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if raw.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let handle = OwnedHandle::from_raw_handle(raw);
        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            raw,
            JobObjectExtendedLimitInformation,
            (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of_val(&info) as u32,
        ) == 0
            || AssignProcessToJobObject(raw, child.as_raw_handle()) == 0
        {
            return Err(std::io::Error::last_os_error());
        }
        Ok(handle)
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::process::{Command, Stdio};
    use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE,
    };

    fn child_command(mode: &str) -> Command {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", "process::tests::child_process", "--nocapture"])
            .env("DIGUP_TEST_PROCESS", mode)
            .stdin(Stdio::null())
            .stderr(Stdio::null());
        command
    }

    #[test]
    fn child_process() {
        match std::env::var("DIGUP_TEST_PROCESS").as_deref() {
            Ok("parent") => {
                // The test models a helper spawning a decoder, with a real child process and real Windows job.
                let mut child = child_command("descendant")
                    .stdout(Stdio::null())
                    .spawn()
                    .unwrap();
                println!("descendant={}", child.id());
                let _ = child.wait();
            }
            Ok("descendant") => std::thread::sleep(std::time::Duration::from_secs(60)),
            _ => {}
        }
    }

    #[test]
    fn dropping_helper_terminates_decoder_descendants() {
        let mut child = HelperProcess::new(
            child_command("parent")
                .stdout(Stdio::piped())
                .spawn()
                .unwrap(),
        )
        .unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let descendant = stdout
            .lines()
            .map(Result::unwrap)
            .find_map(|line| {
                line.split("descendant=")
                    .nth(1)
                    .and_then(|pid| pid.parse::<u32>().ok())
            })
            .expect("child didn't start its decoder");
        // SAFETY: OpenProcess returns a fresh owned handle to our child; it is used only for waiting and closed once.
        let handle = unsafe {
            let raw = OpenProcess(PROCESS_SYNCHRONIZE, 0, descendant);
            assert!(!raw.is_null());
            OwnedHandle::from_raw_handle(raw)
        };
        // SAFETY: handle remains valid for both waits.
        assert_eq!(
            unsafe { WaitForSingleObject(handle.as_raw_handle(), 0) },
            WAIT_TIMEOUT
        );
        drop(child);
        assert_eq!(
            unsafe { WaitForSingleObject(handle.as_raw_handle(), 5000) },
            WAIT_OBJECT_0
        );
    }
}
