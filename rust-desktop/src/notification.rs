#[cfg(windows)]
pub fn show(message: String) {
    use windows::core::{w, HSTRING};
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::UI::Shell::{
        IQueryContinue, IUserNotification2, IUserNotificationCallback,
        SHQueryUserNotificationState, UserNotification, NIIF_NOSOUND, NIIF_RESPECT_QUIET_TIME,
        NIIF_WARNING, QUNS_ACCEPTS_NOTIFICATIONS,
    };

    // Show blocks until the notification closes. Keep Windows COM on this worker.
    std::thread::spawn(move || unsafe {
        if CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_err() {
            return;
        }
        let notify = || -> windows::core::Result<()> {
            if SHQueryUserNotificationState()? != QUNS_ACCEPTS_NOTIFICATIONS {
                return Ok(());
            }
            let balloon: IUserNotification2 =
                CoCreateInstance(&UserNotification, None, CLSCTX_INPROC_SERVER)?;
            balloon.SetBalloonInfo(
                w!("Claude 环境检查器"),
                &HSTRING::from(message),
                (NIIF_WARNING | NIIF_NOSOUND | NIIF_RESPECT_QUIET_TIME).0,
            )?;
            balloon.SetBalloonRetry(5_000, 0, 0)?;
            balloon.Show(
                None::<&IQueryContinue>,
                5_000,
                None::<&IUserNotificationCallback>,
            )
        };
        let _ = notify();
        CoUninitialize();
    });
}

#[cfg(not(windows))]
pub fn show(_message: String) {}
