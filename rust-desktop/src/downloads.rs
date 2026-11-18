use std::io::{self, ErrorKind};
use std::path::{Path, PathBuf};

pub fn save(
    mut file: tempfile::NamedTempFile,
    folder: &Path,
    stem: &str,
    extension: &str,
) -> io::Result<PathBuf> {
    for number in 0..=999 {
        let name = if number == 0 {
            format!("{stem}.{extension}")
        } else {
            format!("{stem} ({number}).{extension}")
        };
        let path = folder.join(name);
        match file.persist_noclobber(&path) {
            Ok(_) => return Ok(path),
            Err(error) if error.error.kind() == ErrorKind::AlreadyExists => file = error.file,
            Err(error) => return Err(error.error),
        }
    }
    Err(ErrorKind::AlreadyExists.into())
}
