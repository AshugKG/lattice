mod app;
mod camera;
mod core;
mod engine;
mod persist;

fn main() -> eframe::Result {
    let initial_path = std::env::args_os().nth(1).map(std::path::PathBuf::from);
    #[allow(unused_mut)]
    let mut options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("Lattice")
            .with_inner_size([1200.0, 840.0])
            .with_min_inner_size([640.0, 420.0]),
        ..Default::default()
    };

    #[cfg(target_os = "macos")]
    {
        use winit::platform::macos::{ActivationPolicy, EventLoopBuilderExtMacOS};
        options.event_loop_builder = Some(Box::new(|builder| {
            builder.with_activation_policy(ActivationPolicy::Regular);
        }));
    }

    eframe::run_native(
        "Lattice",
        options,
        Box::new(move |creation| Ok(Box::new(app::LatticeApp::new(creation, initial_path)))),
    )
}
