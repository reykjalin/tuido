const std = @import("std");
const vaxis = @import("vaxis");
const known_folders = @import("known-folders");

/// Set known folders to use XDG paths on macOS.
pub const known_folders_config = .{
    .xdg_on_mac = true,
};

/// Set the default panic handler to the vaxis panic_handler. This will clean up the terminal if any
/// panics occur
pub const panic = vaxis.panic_handler;

/// Set some scope levels for the vaxis scopes
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
};

/// Tagged union of all events our application will handle. These can be generated by Vaxis or your
/// own custom events
const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    mouse: vaxis.Mouse,
    focus_in, // window has gained focus
    focus_out, // window has lost focus
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: vaxis.Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: vaxis.Color.Scheme, // light / dark OS theme changes
    winsize: vaxis.Winsize, // the window size has changed. This event is always sent when the loop
    // is started
};

const TaskTag = []u8;

const Task = struct {
    title: std.ArrayList(u8),
    tags: std.ArrayList(TaskTag),
    details: std.ArrayList(u8),
};

/// The application state
const TodoApp = struct {
    allocator: std.mem.Allocator,
    // A flag for if we should quit
    should_quit: bool,
    /// The tty we are talking to
    tty: vaxis.Tty,
    /// The vaxis instance
    vx: vaxis.Vaxis,
    /// A mouse event that we will handle in the draw cycle
    mouse: ?vaxis.Mouse,
    /// List of loaded tasks.
    tasks: std.ArrayList(Task),

    pub fn init(allocator: std.mem.Allocator) !TodoApp {
        return .{
            .allocator = allocator,
            .should_quit = false,
            .tty = try vaxis.Tty.init(),
            .vx = try vaxis.init(allocator, .{}),
            .mouse = null,
            .tasks = std.ArrayList(Task).init(allocator),
        };
    }

    pub fn deinit(self: *TodoApp) void {
        // Deinit takes an optional allocator. You can choose to pass an allocator to clean up
        // memory, or pass null if your application is shutting down and let the OS clean up the
        // memory
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();

        // Cleanup the ArrayLists in the Task struct.
        for (self.tasks.items) |t| {
            t.title.deinit();
            t.tags.deinit();
            t.details.deinit();
        }

        self.tasks.deinit();
    }

    fn load_tasks(self: *TodoApp) !void {
        const todo_folder_name = "todo";
        const data_path = known_folders.getPath(self.allocator, known_folders.KnownFolder.data) catch null;
        defer if (data_path) |path| self.allocator.free(path);

        const todo_folder_path = try std.fs.path.join(self.allocator, &[_][]const u8{ if (data_path) |p| p else "", todo_folder_name });
        defer self.allocator.free(todo_folder_path);

        // FIXME: Handle file not found errors by creating the todo data folder.
        var todo_dir = try std.fs.openDirAbsolute(todo_folder_path, .{});
        defer todo_dir.close();

        var iterator = todo_dir.iterate();

        while (try iterator.next()) |f| {
            if (f.kind != std.fs.Dir.Entry.Kind.file) {
                std.log.info("tagname {s}", .{@tagName(f.kind)});
                continue;
            }
            var task: Task = Task{
                .title = std.ArrayList(u8).init(self.allocator),
                .tags = std.ArrayList(TaskTag).init(self.allocator),
                .details = std.ArrayList(u8).init(self.allocator),
            };

            const file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ todo_folder_path, f.name });
            defer self.allocator.free(file_path);
            const file = try std.fs.openFileAbsolute(file_path, .{});
            defer file.close();

            var buf_reader = std.io.bufferedReader(file.reader());
            const reader = buf_reader.reader();

            var line = std.ArrayList(u8).init(self.allocator);
            defer line.deinit();

            const writer = line.writer();
            var line_no: usize = 0;

            while (reader.streamUntilDelimiter(writer, '\n', null)) {
                // Clear the line so we can reuse it.
                defer line.clearRetainingCapacity();
                line_no += 1;

                if (line_no == 1) {
                    try task.title.appendSlice(line.items);
                } else if (line_no > 3) {
                    try task.details.appendSlice(line.items);
                }
            } else |err| switch (err) {
                error.EndOfStream => { // end of file
                    line_no += 1;

                    if (line_no == 1) {
                        try task.title.appendSlice(line.items);
                    } else if (line_no > 3) {
                        try task.details.appendSlice(line.items);
                    }
                },
                else => return err, // Propagate error
            }

            try self.tasks.append(task);
        }
    }

    pub fn run(self: *TodoApp) !void {
        // Load tasks. Loading early so I can log things.
        try self.load_tasks();

        // Initialize our event loop. This particular loop requires intrusive init
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();

        // Start the event loop. Events will now be queued
        try loop.start();

        try self.vx.enterAltScreen(self.tty.anyWriter());

        // Query the terminal to detect advanced features, such as kitty keyboard protocol, etc.
        // This will automatically enable the features in the screen you are in, so you will want to
        // call it after entering the alt screen if you are a full screen application. The second
        // arg is a timeout for the terminal to send responses. Typically the response will be very
        // fast, however it could be slow on ssh connections.
        try self.vx.queryTerminal(self.tty.anyWriter(), 1 * std.time.ns_per_s);

        // Enable mouse events
        try self.vx.setMouseMode(self.tty.anyWriter(), true);

        // This is the main event loop. The basic structure is
        // 1. Handle events
        // 2. Draw application
        // 3. Render
        while (!self.should_quit) {
            // pollEvent blocks until we have an event
            loop.pollEvent();
            // tryEvent returns events until the queue is empty
            while (loop.tryEvent()) |event| {
                try self.update(event);
            }
            // Draw our application after handling events
            self.draw();

            // It's best to use a buffered writer for the render method. TTY provides one, but you
            // may use your own. The provided bufferedWriter has a buffer size of 4096
            var buffered = self.tty.bufferedWriter();
            // Render the application to the screen
            try self.vx.render(buffered.writer().any());
            try buffered.flush();
        }
    }

    /// Update our application state from an event
    pub fn update(self: *TodoApp, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                // key.matches does some basic matching algorithms. Key matching can be complex in
                // the presence of kitty keyboard encodings, this will generally be a good approach.
                // There are other matching functions available for specific purposes, as well
                if (key.matches('c', .{ .ctrl = true })) {
                    self.should_quit = true;
                } else if (key.matches('q', .{})) {
                    self.should_quit = true;
                }
            },
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
            else => {},
        }
    }

    /// Draw our current state
    pub fn draw(self: *TodoApp) void {
        // Window is a bounded area with a view to the screen. You cannot draw outside of a windows
        // bounds. They are light structures, not intended to be stored.
        const win = self.vx.window();

        // Clearing the window has the effect of setting each cell to it's "default" state. Vaxis
        // applications typically will be immediate mode, and you will redraw your entire
        // application during the draw cycle.
        win.clear();

        // In addition to clearing our window, we want to clear the mouse shape state since we may
        // be changing that as well
        self.vx.setMouseShape(.default);

        var offset: usize = 5;
        for (self.tasks.items) |t| {
            const title = win.child(.{
                .x_off = 5,
                .y_off = offset,
                .width = .{ .limit = t.title.items.len },
                .height = .{ .limit = 1 },
            });

            const sep = win.child(.{
                .x_off = 5 + t.title.items.len,
                .y_off = offset,
                .width = .{ .limit = t.title.items.len },
                .height = .{ .limit = 1 },
            });

            const details = win.child(.{
                .x_off = 5 + t.title.items.len + 3,
                .y_off = offset,
                .width = .{ .limit = t.details.items.len },
                .height = .{ .limit = 1 },
            });

            // mouse events are much easier to handle in the draw cycle. Windows have a helper method to
            // determine if the event occurred in the target window. This method returns null if there
            // is no mouse event, or if it occurred outside of the window
            var style: vaxis.Style = if (title.hasMouse(self.mouse)) |_| blk: {
                // We handled the mouse event, so set it to null
                self.mouse = null;
                self.vx.setMouseShape(.pointer);
                break :blk .{ .reverse = true };
            } else .{};

            // mouse events are much easier to handle in the draw cycle. Windows have a helper method to
            // determine if the event occurred in the target window. This method returns null if there
            // is no mouse event, or if it occurred outside of the window
            style = if (sep.hasMouse(self.mouse)) |_| blk: {
                // We handled the mouse event, so set it to null
                self.mouse = null;
                self.vx.setMouseShape(.pointer);
                break :blk .{ .reverse = true };
            } else style;

            // mouse events are much easier to handle in the draw cycle. Windows have a helper method to
            // determine if the event occurred in the target window. This method returns null if there
            // is no mouse event, or if it occurred outside of the window
            style = if (details.hasMouse(self.mouse)) |_| blk: {
                // We handled the mouse event, so set it to null
                self.mouse = null;
                self.vx.setMouseShape(.pointer);
                break :blk .{ .reverse = true };
            } else style;

            _ = try title.printSegment(.{ .text = t.title.items, .style = style }, .{});
            _ = try sep.printSegment(.{ .text = " - ", .style = style }, .{});
            _ = try details.printSegment(.{ .text = t.details.items, .style = style }, .{});

            offset += 1;
        }
    }
};

/// Keep our main function small. Typically handling arg parsing and initialization only
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    const todo_folder_name = "todo";
    const data_path = known_folders.getPath(allocator, known_folders.KnownFolder.data) catch null;
    defer if (data_path) |path| allocator.free(path);

    const todo_folder_path = try std.fs.path.join(allocator, &[_][]const u8{ if (data_path) |p| p else "", todo_folder_name });
    defer allocator.free(todo_folder_path);
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ todo_folder_path, "test" });
    defer allocator.free(file_path);
    std.log.info("local_data: {?s}", .{data_path});
    std.log.info("todo path: {s}", .{todo_folder_path});
    std.log.info("file path: {s}", .{todo_folder_path});

    // Initialize our application
    var app = try TodoApp.init(allocator);
    defer app.deinit();

    // Run the application
    try app.run();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
