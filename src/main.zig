const std = @import("std");
const vaxis = @import("vaxis");
const known_folders = @import("known-folders");
const gb = @import("gap_buffer");

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

    .logFn = log_to_file,
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

const Task = struct {
    title: std.ArrayList(u8),
    /// All tags are currently stored as a single string.
    tags: std.ArrayList(u8),
    details: std.ArrayList(u8),
    file_path: std.ArrayList(u8),
};

const Layout = union(enum) { TaskList, TaskDetails };

/// The application state
const TodoApp = struct {
    allocator: std.mem.Allocator,
    // Arena allocator for easy event loops, see https://github.com/rockorager/libvaxis/blob/main/examples/table.zig#L110.
    arena_allocator: std.heap.ArenaAllocator,
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
    /// Task table context.
    task_table_ctx: vaxis.widgets.Table.TableContext,
    /// currently active layout.
    active_layout: Layout,
    /// Currently detailed task.
    active_task: ?Task,
    //== Task details ==//
    /// The title input.
    details_title_input: vaxis.widgets.TextInput,
    /// The details input.
    details_details_input: vaxis.widgets.TextInput,

    pub fn init(allocator: std.mem.Allocator) !TodoApp {
        var vx = try vaxis.init(allocator, .{});
        return .{
            .allocator = allocator,
            .arena_allocator = std.heap.ArenaAllocator.init(allocator),
            .should_quit = false,
            .tty = try vaxis.Tty.init(),
            .vx = vx,
            .mouse = null,
            .tasks = std.ArrayList(Task).init(allocator),
            .task_table_ctx = .{
                .active = true,
                .col = 0,
                .row = 0,
                .selected_bg = .{ .rgb = .{ 50, 50, 50 } },
                .row_bg_1 = .{ .rgb = .{ 0, 0, 0 } },
                .row_bg_2 = .{ .rgb = .{ 0, 0, 0 } },
                .hdr_bg_1 = .{ .rgb = .{ 0, 0, 0 } },
                .hdr_bg_2 = .{ .rgb = .{ 0, 0, 0 } },
            },
            .active_layout = .TaskList,
            .active_task = null,
            .details_title_input = vaxis.widgets.TextInput.init(allocator, &vx.unicode),
            .details_details_input = vaxis.widgets.TextInput.init(allocator, &vx.unicode),
        };
    }

    pub fn deinit(self: *TodoApp) void {
        // Deinit takes an optional allocator. You can choose to pass an allocator to clean up
        // memory, or pass null if your application is shutting down and let the OS clean up the
        // memory
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();

        // Free any memory used by the arena allocator.
        self.arena_allocator.deinit();

        // Free any memory used by the text inputs.
        self.details_title_input.deinit();
        self.details_details_input.deinit();

        // Make sure all the individual task structs are properly cleaned and freed before we
        // free the main task list.
        self.clear_tasks();
        self.tasks.deinit();
    }

    fn load_tasks(self: *TodoApp) !void {
        const todo_folder_path = try get_todo_file_storage_path_caller_should_free(self.allocator);
        defer self.allocator.free(todo_folder_path);

        // FIXME: Handle file not found errors by creating the todo data folder.
        var todo_dir = try std.fs.openDirAbsolute(todo_folder_path, .{});
        defer todo_dir.close();

        var iterator = todo_dir.iterate();

        while (try iterator.next()) |f| {
            if (f.kind != std.fs.Dir.Entry.Kind.file) {
                continue;
            }

            // FIXME: only include .todo files.
            var task: Task = Task{
                .title = std.ArrayList(u8).init(self.allocator),
                .tags = std.ArrayList(u8).init(self.allocator),
                .details = std.ArrayList(u8).init(self.allocator),
                .file_path = std.ArrayList(u8).init(self.allocator),
            };

            const file_path = try std.fs.path.join(self.allocator, &.{ todo_folder_path, f.name });
            try task.file_path.appendSlice(file_path);

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
                } else if (line_no == 2) {
                    try task.tags.appendSlice(line.items);
                } else if (line_no > 3) {
                    try task.details.appendSlice(line.items);
                    try task.details.appendSlice("\n");
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

    fn clear_tasks(self: *TodoApp) void {
        // Cleanup the ArrayLists in the Task struct.
        for (self.tasks.items) |t| {
            t.title.deinit();
            t.tags.deinit();
            t.details.deinit();
            t.file_path.deinit();
        }

        self.active_task = null;

        self.tasks.clearRetainingCapacity();
    }

    fn reload_tasks(self: *TodoApp) !void {
        self.clear_tasks();
        try self.load_tasks();
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
                try self.update(&loop, event);
            }
            // Draw our application after handling events
            try self.draw();

            // It's best to use a buffered writer for the render method. TTY provides one, but you
            // may use your own. The provided bufferedWriter has a buffer size of 4096
            var buffered = self.tty.bufferedWriter();
            // Render the application to the screen
            try self.vx.render(buffered.writer().any());
            try buffered.flush();
        }
    }

    /// Update our application state from an event
    pub fn update(self: *TodoApp, loop: *vaxis.Loop(Event), event: Event) !void {
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

                switch (self.active_layout) {
                    .TaskList => {
                        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
                            if (self.task_table_ctx.row > 0) {
                                self.task_table_ctx.row -= 1;
                            }
                        }
                        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
                            if (self.task_table_ctx.row < self.tasks.items.len) {
                                self.task_table_ctx.row += 1;
                            }
                        }
                        // Make sure the active table row never exceeds the number of tasks.
                        if (self.tasks.items.len == 0) {
                            self.task_table_ctx.row = 0;
                        } else if (self.task_table_ctx.row >= self.tasks.items.len) {
                            self.task_table_ctx.row = self.tasks.items.len - 1;
                        }

                        if (key.matchesAny(&.{ vaxis.Key.enter, 'l' }, .{})) {
                            self.active_layout = .TaskDetails;
                            self.active_task = self.tasks.items[self.task_table_ctx.row];
                        }

                        if (key.matches('c', .{})) {
                            // Get the currently highlighted task.
                            const task_file = self.tasks.items[self.task_table_ctx.row].file_path.items;

                            // Get the completed storage directory.
                            const completed_storage = try get_completed_todo_file_storage_path_caller_should_free(self.allocator);
                            defer self.allocator.free(completed_storage);

                            // Get current date.
                            const res = try std.process.Child.run(.{
                                .allocator = self.allocator,
                                .argv = &.{ "date", "+%Y-%m-%d" },
                            });
                            defer self.allocator.free(res.stdout);
                            defer self.allocator.free(res.stderr);

                            const date_str = try std.mem.replaceOwned(u8, self.allocator, res.stdout, "\n", "");
                            defer self.allocator.free(date_str);

                            // Hash the file path.
                            var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
                            sha256.update(task_file);
                            const hash = sha256.finalResult();

                            const hex_digest = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
                            defer self.allocator.free(hex_digest);

                            // Construct new path as yyyy-mm-dd-<hash>.
                            const new_file_name = try std.fmt.allocPrint(self.allocator, "{s}-{s}.todo", .{ date_str, hex_digest });
                            defer self.allocator.free(new_file_name);

                            const new_file_path = try std.fs.path.join(self.allocator, &.{ completed_storage, new_file_name });
                            defer self.allocator.free(new_file_path);

                            // Move file to completed path.
                            try std.fs.renameAbsolute(task_file, new_file_path);

                            try self.reload_tasks();
                        }

                        if (key.matches('n', .{})) {
                            // Halt the loop.
                            loop.stop();

                            // Get the storage path.
                            const storage_path = try get_todo_file_storage_path_caller_should_free(self.allocator);
                            defer self.allocator.free(storage_path);

                            // Get a handle to the storage directory.
                            // FIXME: Create storage directory if it does not exist.
                            const storage_dir = try std.fs.openDirAbsolute(storage_path, .{});

                            // Store the number for the last file.
                            // Default to 1 because that's what we want if there are no files stored.
                            var last_file_number: []const u8 = "1";

                            // Find the last file if it exists.
                            var it = storage_dir.iterate();
                            while (try it.next()) |f| {
                                // We're only interested in files, not directories.
                                if (f.kind != std.fs.Dir.Entry.Kind.file) {
                                    continue;
                                }

                                // FIXME: only include .todo files.

                                last_file_number = std.fs.path.stem(f.name);
                            }

                            // Parse the file number into an i32.
                            const list_file_i32 = try std.fmt.parseInt(i32, last_file_number, 10);

                            // Create the full file path for the new file.
                            const new_file_name = try std.fmt.allocPrint(self.allocator, "{d}.todo", .{list_file_i32 + 1});
                            defer self.allocator.free(new_file_name);

                            const new_file_path = try std.fs.path.join(self.allocator, &.{ storage_path, new_file_name });
                            defer self.allocator.free(new_file_path);

                            // Get the executable environment.
                            var env = try std.process.getEnvMap(self.allocator);
                            defer env.deinit();

                            // Use the $EDITOR environment variable if it's available; default to nano.
                            const editor = env.get("EDITOR") orelse "nano";

                            // Edit the todo file using $EDITOR.
                            var child = std.process.Child.init(&.{ editor, new_file_path }, self.allocator);
                            _ = try child.spawnAndWait();

                            // Switch back to the task list layout.
                            self.active_layout = .TaskList;

                            // Restart the loop.
                            try loop.start();
                            try self.vx.enterAltScreen(self.tty.anyWriter());
                            self.vx.queueRefresh();

                            // Once new task is created, reload all the tasks.
                            try self.reload_tasks();
                        }
                    },
                    .TaskDetails => {
                        if (self.active_task) |task| {
                            if (key.matchesAny(&.{ vaxis.Key.escape, 'h' }, .{})) {
                                self.active_layout = .TaskList;
                                self.active_task = null;
                            }

                            if (key.matches('e', .{})) {
                                // Halt the loop.
                                loop.stop();

                                // Retain a copy of the file path for after the tasks are reloaded.
                                const file_path_copy = try task.file_path.clone();
                                defer file_path_copy.deinit();

                                // Get the executable environment.
                                var env = try std.process.getEnvMap(self.allocator);
                                defer env.deinit();

                                // Use the $EDITOR environment variable if it's available; default to nano.
                                const editor = env.get("EDITOR") orelse "nano";

                                // Edit the todo file using $EDITOR.
                                var child = std.process.Child.init(&.{ editor, task.file_path.items }, self.allocator);
                                _ = try child.spawnAndWait();

                                // Restart the loop.
                                try loop.start();
                                try self.vx.enterAltScreen(self.tty.anyWriter());
                                self.vx.queueRefresh();

                                // Reload the tasks.
                                // FIXME: there is a crash here.
                                try self.reload_tasks();

                                for (self.tasks.items) |t| {
                                    if (std.mem.eql(u8, t.file_path.items, file_path_copy.items)) {
                                        self.active_task = t;
                                    }
                                }
                            }
                        } else {
                            self.active_layout = .TaskList;
                        }
                    },
                }
            },
            // FIXME: Add mouse interactions so you can click around the TUI.
            .mouse => |mouse| self.mouse = mouse,
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
            else => {},
        }

        self.task_table_ctx.active = self.active_layout == .TaskList;
    }

    /// Draw our current state
    pub fn draw(self: *TodoApp) !void {
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

        switch (self.active_layout) {
            .TaskList => try self.draw_task_list(),
            .TaskDetails => try self.draw_task_details(),
        }
    }

    fn draw_task_list(self: *TodoApp) !void {
        const draw_table_allocator = self.arena_allocator.allocator();

        var task_list = std.ArrayList(struct { title: []const u8, tags: []const u8 }).init(draw_table_allocator);

        for (self.tasks.items) |task| {
            try task_list.append(.{ .title = task.title.items, .tags = task.tags.items });
        }

        const window = vaxis.widgets.border.all(self.vx.window(), .{});
        try vaxis.widgets.Table.drawTable(draw_table_allocator, window, &.{ "Tasks", "Tags" }, task_list, &self.task_table_ctx);
    }

    fn draw_task_details(self: *TodoApp) !void {
        if (self.active_task) |task| {
            try self.draw_task_list();

            const win = self.vx.window();
            const overlay = win.child(.{
                .x_off = 2,
                .y_off = 2,
                .width = .{ .limit = win.width - 4 },
                .height = .{ .limit = win.height - 4 },
            });

            const window = vaxis.widgets.border.all(overlay, .{});
            window.clear();

            const title_box = window.child(.{
                .x_off = 1,
                .y_off = 1,
                .width = .{ .limit = window.width - 2 },
                .height = .{ .limit = 1 },
            });

            const tags_box = window.child(.{
                .x_off = 1,
                .y_off = 2,
                .width = .{ .limit = window.width - 2 },
                .height = .{ .limit = 1 },
            });

            const details_box = window.child(.{
                .x_off = 1,
                .y_off = 4,
                .width = .{ .limit = window.width - 2 },
                .height = .{ .limit = window.height - 2 },
            });

            _ = try title_box.printSegment(.{ .text = task.title.items }, .{ .col_offset = (title_box.width / 2) - (task.title.items.len / 2) });
            _ = try tags_box.printSegment(.{ .text = task.tags.items }, .{ .col_offset = (tags_box.width / 2) - (task.tags.items.len / 2) });
            _ = try vaxis.widgets.border.all(details_box, .{}).printSegment(.{ .text = task.details.items }, .{});
        } else {
            unreachable;
        }
    }
};

fn get_todo_file_storage_path_caller_should_free(allocator: std.mem.Allocator) ![]const u8 {
    const data_path = try known_folders.getPath(allocator, known_folders.KnownFolder.data);
    defer {
        if (data_path) |p| {
            allocator.free(p);
        }
    }

    if (data_path) |p| {
        return try std.fs.path.join(allocator, &.{ p, "todo" });
    }

    unreachable;
}

fn get_completed_todo_file_storage_path_caller_should_free(allocator: std.mem.Allocator) ![]const u8 {
    const data_path = try known_folders.getPath(allocator, known_folders.KnownFolder.data);
    defer {
        if (data_path) |p| {
            allocator.free(p);
        }
    }

    if (data_path) |p| {
        return try std.fs.path.join(allocator, &.{ p, "todo", "completed" });
    }

    unreachable;
}

fn get_todo_app_log_storage_path(allocator: std.mem.Allocator) ![]const u8 {
    const data_path = try known_folders.getPath(allocator, known_folders.KnownFolder.data);
    defer {
        if (data_path) |p| {
            allocator.free(p);
        }
    }

    if (data_path) |p| {
        return try std.fs.path.join(allocator, &.{ p, "todo", "logs" });
    }

    unreachable;
}

fn log_to_file(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    // Get level text and log prefix.
    // See https://ziglang.org/documentation/master/std/#std.log.defaultLog.
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Get an allocator to use for getting path to the log file.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak in custom logger", .{});
        }
    }

    const allocator = gpa.allocator();

    // Get the log directory.
    const log_directory_path = get_todo_app_log_storage_path(allocator) catch return;
    defer allocator.free(log_directory_path);

    // Make sure log directory exists.
    std.fs.makeDirAbsolute(log_directory_path) catch return;

    // Construct the absolute path to the log file.
    const log_file_path = std.fs.path.join(allocator, &.{ log_directory_path, "debug.log" }) catch return;
    defer allocator.free(log_file_path);

    // Open the log file, create it if doesn't already exist.
    const log = std.fs.openFileAbsolute(log_file_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => std.fs.createFileAbsolute(log_file_path, .{}) catch return,
        else => return,
    };

    // Get a writer.
    // See https://ziglang.org/documentation/master/std/#std.log.defaultLog.
    const log_writer = log.writer();
    var bw = std.io.bufferedWriter(log_writer);
    const writer = bw.writer();

    // Write to the log file.
    // See https://ziglang.org/documentation/master/std/#std.log.defaultLog.
    nosuspend {
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

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
