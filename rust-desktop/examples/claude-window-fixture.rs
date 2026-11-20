#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

#[cfg(windows)]
fn main() {
    use std::ptr::null_mut;
    use std::time::Duration;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DispatchMessageW, IsWindow, PeekMessageW, TranslateMessage, CW_USEDEFAULT,
        MSG, PM_REMOVE, WS_OVERLAPPEDWINDOW, WS_VISIBLE,
    };

    let class = wide("STATIC");
    let title = wide("Claude close fixture");
    let window = unsafe {
        CreateWindowExW(
            0,
            class.as_ptr(),
            title.as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            480,
            240,
            null_mut(),
            null_mut(),
            null_mut(),
            std::ptr::null(),
        )
    };
    if window.is_null() {
        std::process::exit(1);
    }
    let mut message: MSG = unsafe { std::mem::zeroed() };
    while unsafe { IsWindow(window) } != 0 {
        while unsafe { PeekMessageW(&mut message, null_mut(), 0, 0, PM_REMOVE) } != 0 {
            unsafe {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(not(windows))]
fn main() {}
