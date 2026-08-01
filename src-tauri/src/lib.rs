use serde::Serialize;
use std::{
    ffi::OsString,
    fs,
    io::Read,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
};
use tauri::{ipc::Response, AppHandle, Emitter, Manager};

const OPEN_PDF_EVENT: &str = "lattice://open-pdf";

#[derive(Default)]
struct OpenRequestState {
    pending: Mutex<Option<String>>,
    frontend_ready: AtomicBool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PdfOpenError {
    code: String,
    message: String,
}

impl PdfOpenError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_owned(),
            message: message.into(),
        }
    }

    fn from_io(error: std::io::Error, path: &Path) -> Self {
        let code = match error.kind() {
            std::io::ErrorKind::NotFound => "notFound",
            std::io::ErrorKind::PermissionDenied => "permissionDenied",
            _ => "readFailed",
        };
        Self::new(code, format!("Could not read {}: {error}", path.display()))
    }
}

fn is_pdf_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"))
}

fn validate_and_read_pdf(path: &Path) -> Result<Vec<u8>, PdfOpenError> {
    if !is_pdf_path(path) {
        return Err(PdfOpenError::new(
            "unsupportedType",
            "Lattice can only open PDF files.",
        ));
    }

    let canonical = fs::canonicalize(path).map_err(|error| PdfOpenError::from_io(error, path))?;
    let metadata =
        fs::metadata(&canonical).map_err(|error| PdfOpenError::from_io(error, &canonical))?;
    if !metadata.is_file() {
        return Err(PdfOpenError::new(
            "notAFile",
            format!("{} is not a file.", canonical.display()),
        ));
    }

    let mut file =
        fs::File::open(&canonical).map_err(|error| PdfOpenError::from_io(error, &canonical))?;
    let mut header = [0_u8; 1024];
    let bytes_read = file
        .read(&mut header)
        .map_err(|error| PdfOpenError::from_io(error, &canonical))?;
    if !header[..bytes_read]
        .windows(b"%PDF-".len())
        .any(|window| window == b"%PDF-")
    {
        return Err(PdfOpenError::new(
            "invalidPdf",
            "The selected file does not contain a valid PDF header.",
        ));
    }

    fs::read(&canonical).map_err(|error| PdfOpenError::from_io(error, &canonical))
}

#[tauri::command]
fn read_pdf(path: String) -> Result<Response, PdfOpenError> {
    validate_and_read_pdf(Path::new(&path)).map(Response::new)
}

#[tauri::command]
fn frontend_ready(state: tauri::State<'_, OpenRequestState>) -> Option<String> {
    state.frontend_ready.store(true, Ordering::Release);
    state.pending.lock().ok()?.take()
}

fn first_pdf_argument<I>(arguments: I) -> Option<PathBuf>
where
    I: IntoIterator<Item = OsString>,
{
    arguments
        .into_iter()
        .map(PathBuf::from)
        .find(|path| is_pdf_path(path))
}

fn first_pdf_string_argument<I>(arguments: I) -> Option<PathBuf>
where
    I: IntoIterator<Item = String>,
{
    first_pdf_argument(arguments.into_iter().map(OsString::from))
}

fn dispatch_open_path(app: &AppHandle, path: PathBuf) {
    if !is_pdf_path(&path) {
        return;
    }

    let path = path.to_string_lossy().into_owned();
    let Some(state) = app.try_state::<OpenRequestState>() else {
        return;
    };

    if state.frontend_ready.load(Ordering::Acquire) {
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.show();
            let _ = window.unminimize();
            let _ = window.set_focus();
        }
        let _ = app.emit(OPEN_PDF_EVENT, path);
    } else if let Ok(mut pending) = state.pending.lock() {
        pending.get_or_insert(path);
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if let Some(path) = first_pdf_string_argument(argv.into_iter().skip(1)) {
                dispatch_open_path(app, path);
            }
        }));
    }

    let app = builder
        .plugin(tauri_plugin_dialog::init())
        .manage(OpenRequestState::default())
        .invoke_handler(tauri::generate_handler![read_pdf, frontend_ready])
        .setup(|app| {
            if let Some(path) = first_pdf_argument(std::env::args_os().skip(1)) {
                dispatch_open_path(app.handle(), path);
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Lattice");

    app.run(|app, event| {
        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Opened { urls } = event {
            if let Some(path) = urls
                .into_iter()
                .filter_map(|url| url.to_file_path().ok())
                .find(|path| is_pdf_path(path))
            {
                dispatch_open_path(app, path);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn accepts_pdf_extension_case_insensitively() {
        assert!(is_pdf_path(Path::new("paper.PDF")));
        assert!(!is_pdf_path(Path::new("paper.txt")));
    }

    #[test]
    fn reads_a_pdf_with_a_header_in_the_first_kilobyte() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join("sample.pdf");
        let mut file = fs::File::create(&path).expect("sample file");
        file.write_all(b"prefix\n%PDF-1.7\nbody")
            .expect("sample PDF bytes");

        let bytes = validate_and_read_pdf(&path).expect("valid PDF");
        assert!(bytes.windows(5).any(|window| window == b"%PDF-"));
    }

    #[test]
    fn rejects_non_pdf_extensions_before_reading() {
        let error = validate_and_read_pdf(Path::new("notes.txt")).expect_err("must reject");
        assert_eq!(error.code, "unsupportedType");
    }

    #[test]
    fn rejects_files_without_a_pdf_header() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join("fake.pdf");
        fs::write(&path, b"not a pdf").expect("sample file");

        let error = validate_and_read_pdf(&path).expect_err("must reject");
        assert_eq!(error.code, "invalidPdf");
    }

    #[test]
    fn reports_missing_files() {
        let error = validate_and_read_pdf(Path::new("missing.pdf")).expect_err("must reject");
        assert_eq!(error.code, "notFound");
    }
}
