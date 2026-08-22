const std = @import("std");
const example = @import("example");
const dvui = example.dvui;
const dvui_utils = example.dvui_utils;
pub const SDLBackend = @import("sdl-backend");
const libtess2 = example.libtess2;

pub fn main(init: std.process.Init) !void {
    const init_options: SDLBackend.InitOptions = .{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 600.0, .h = 800.0 },
        .min_size = .{ .w = 250.0, .h = 350.0 },
        .vsync = true,
        .title = "Tesselation Vizualizer",
    };
    try SDLBackend.initSDL();
    _ = SDLBackend.c.SDL_GL_SetAttribute(SDLBackend.c.SDL_GL_MULTISAMPLESAMPLES, 8);
    _ = SDLBackend.c.SDL_GL_SetAttribute(SDLBackend.c.SDL_GL_MULTISAMPLEBUFFERS, 1);
    var backend = try SDLBackend.initWindow(init_options);
    SDLBackend.c.SDL_QuitSubSystem(SDLBackend.c.SDL_INIT_VIDEO | SDLBackend.c.SDL_INIT_EVENTS);
    _ = SDLBackend.c.SDL_EnableScreenSaver();

    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .dark) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer win.deinit();

    var state: example.Context = .{};
    defer state.deinit(init.gpa);
    var interrupted = false;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        try backend.addAllEvents(&win);

        _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 24, 24, 24, 255);
        _ = SDLBackend.c.SDL_RenderClear(backend.renderer);

        const keep_running = state.gui_frame(init.gpa) catch blk: {
            state.deinit(init.gpa);
            state = .{};
            break :blk true;
        };
        if (!keep_running) break :main_loop;

        const end_micros = try win.end(.{});
        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}
