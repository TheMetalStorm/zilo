//bbaaimport/include
const std = @import("std");
const ascii = std.ascii;
const print = std.debug.print;
const time = std.time;
const ArrayList = std.ArrayList;
const allocator = std.heap.page_allocator;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("ctype.h");
    @cInclude("sys/ioctl.h");
});

//enum
const editorKey = enum(u32) { BACKSPACE = 127, ARROW_LEFT = 1000, ARROW_RIGHT, ARROW_UP, ARROW_DOWN, DEL_KEY, HOME_KEY, END_KEY, PAGE_UP, PAGE_DOWN };

const erow = struct {
    const Self = @This();

    rowData: std.ArrayList(u8),
    renderData: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) erow {
        return .{ .rowData = std.ArrayList(u8).init(alloc), .renderData = std.ArrayList(u8).init(alloc) };
    }

    pub fn deinit(self: Self) void {
        self.renderData.deinit();
        self.rowData.deinit();
    }
};

const editorConfig = struct {
    var orig_termios: c.termios = undefined;
    var cx: u32 = undefined;
    var cy: u32 = undefined;
    var rx: u32 = undefined;
    var rowoff: u32 = undefined;
    var coloff: u32 = undefined;
    var screenrows: u32 = undefined;
    var screencols: u32 = undefined;
    var numrows: u32 = undefined;
    var rows: ArrayList(erow) = undefined;
    var filename: ArrayList(u8) = undefined;
    var statusmsg: ArrayList(u8) = undefined;
    var statusmsg_time: i64 = undefined;
};

const E = editorConfig;
//const
const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();
const ZILO_VERSION = "0.0.1";
const KILO_TAB_STOP = 8;

//input
fn CTRL_KEY(k: u8) u8 {
    return (k) & 0x1f;
}

fn editorMoveCursor(ch: u32) void {
    switch (ch) {
        @intFromEnum(editorKey.ARROW_LEFT) => {
            if (E.cx != 0) {
                E.cx -= 1;
            } else if (E.cy > 0) {
                E.cy -= 1;
                E.cx = @truncate(E.rows.items[E.cy].rowData.items.len);
            }
        },
        @intFromEnum(editorKey.ARROW_RIGHT) => {
            if (E.cy < E.numrows) {
                var row = E.rows.items[E.cy];
                if (E.cx < row.rowData.items.len) {
                    E.cx += 1;
                } else if (E.cx == row.rowData.items.len) {
                    E.cy += 1;
                    E.cx = 0;
                }
            }
        },
        @intFromEnum(editorKey.ARROW_UP) => {
            if (E.cy != 0) {
                E.cy -= 1;
            }
        },
        @intFromEnum(editorKey.ARROW_DOWN) => {
            if (E.cy < E.numrows) {
                E.cy += 1;
            }
        },
        else => {},
    }

    if (E.cy < E.numrows) {
        var row = E.rows.items[E.cy];
        var rowlen = row.rowData.items.len;
        if (E.cx > rowlen) {
            E.cx = @truncate(rowlen);
        }
    }
}

fn editorProcessKeypress() !void {
    var ch: u32 = editorReadKey();
    switch (ch) {
        '\r' => {
            //TODO
        },
        CTRL_KEY('q') => {
            print("{s}", .{"\x1b[2J"});
            print("{s}", .{"\x1b[H"});

            c.exit(0);
        },
        CTRL_KEY('s') => {
            try editorSave();
        },
        @intFromEnum(editorKey.HOME_KEY) => {
            E.cx = 0;
        },
        @intFromEnum(editorKey.END_KEY) => {
            if (E.cy < E.numrows)
                E.cx = @truncate(E.rows.items[E.cy].rowData.items.len);
        },

        @intFromEnum(editorKey.BACKSPACE), CTRL_KEY('h'), @intFromEnum(editorKey.DEL_KEY) => {
            //TODO
        },
        @intFromEnum(editorKey.PAGE_DOWN), @intFromEnum(editorKey.PAGE_UP) => {
            if (ch == @intFromEnum(editorKey.PAGE_UP)) {
                E.cy = E.rowoff;
            } else if (ch == @intFromEnum(editorKey.PAGE_DOWN)) {
                E.cy = E.rowoff + E.screenrows - 1;
                if (E.cy > E.numrows) E.cy = E.numrows;
            }

            var times: u32 = E.screenrows;
            while (times != 0) {
                if (ch == @intFromEnum(editorKey.PAGE_UP)) {
                    editorMoveCursor(@intFromEnum(editorKey.ARROW_UP));
                } else {
                    editorMoveCursor(@intFromEnum(editorKey.ARROW_DOWN));
                }
                times -= 1;
            }
        },
        @intFromEnum(editorKey.ARROW_UP), @intFromEnum(editorKey.ARROW_DOWN), @intFromEnum(editorKey.ARROW_LEFT), @intFromEnum(editorKey.ARROW_RIGHT) => {
            editorMoveCursor(ch);
        },
        CTRL_KEY('l') => {
            //TODO
        },
        '\x1b' => {
            //TODO
        },

        else => {
            if (ch != 0)
                try editorInsertChar(@truncate(ch));
        },
    }
}

//file i/o

fn editorRowsToString() !ArrayList(u8) {
    var allLines: ArrayList(u8) = ArrayList(u8).init(allocator);
    for (0..E.numrows) |i| {
        try allLines.appendSlice(E.rows.items[i].rowData.items);
        try allLines.append('\n');
    }
    return allLines;
}
fn editorOpen(filename: []const u8) !void {
    E.filename.deinit();

    for (filename) |ch| {
        try E.filename.append(ch);
    }

    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buf: [1000]u8 = undefined;
    while (try file.reader().readUntilDelimiterOrEof(buf[0..], '\n')) |line| {
        try editorAppendRow(line);
    }
}

fn editorSave() !void {
    if (E.filename.items.len == 0) return;

    var allRows: ArrayList(u8) = try editorRowsToString();
    defer allRows.deinit();

    var file = try std.fs.cwd().openFile(E.filename.items, .{ .mode = std.fs.File.OpenMode.write_only });
    defer file.close();

    _ = try file.write(allRows.items);
}
//output

fn editorScroll() void {
    E.rx = 0;
    if (E.cy < E.numrows) {
        E.rx = editorRowCxToRx(&E.rows.items[E.cy].rowData, E.cx);
    }

    if (E.cy < E.rowoff) {
        E.rowoff = E.cy;
    }
    if (E.cy >= E.rowoff + E.screenrows) {
        E.rowoff = E.cy - E.screenrows + 1;
    }

    if (E.rx < E.coloff) {
        E.coloff = E.rx;
    }
    if (E.rx >= E.coloff + E.screencols) {
        E.coloff = E.rx - E.screencols + 1;
    }
}

fn editorDrawRows(ab: *ArrayList(u8)) !void {
    for (0..E.screenrows) |y| {
        var filerow: usize = y + E.rowoff;
        if (filerow >= E.numrows) {
            if (E.numrows == 0 and y == E.screenrows / 3) {
                var welcome = "Zilo editor -- version " ++ ZILO_VERSION;

                var padding = (E.screencols - welcome.len) / 2;
                try ab.append('~');
                padding -= 1;

                while (padding > 1) {
                    try ab.append(' ');
                    padding -= 1;
                }

                try ab.appendSlice(welcome);
            } else {
                try ab.append('~');
            }
        } else {
            var len: usize = 0;
            if (E.coloff < E.rows.items[filerow].renderData.items.len) {
                len = E.rows.items[filerow].renderData.items.len - E.coloff;
            }

            if (len > E.screencols) len = E.screencols;

            if (len != 0)
                try ab.appendSlice(E.rows.items[filerow].renderData.items[E.coloff .. E.coloff + len]);
        }
        try ab.appendSlice("\x1b[K");
        try ab.appendSlice("\r\n");
    }
}

fn editorDrawStatusBar(ab: *ArrayList(u8)) !void {
    try ab.appendSlice("\x1b[7m");
    var filename: ArrayList(u8) = ArrayList(u8).init(allocator);
    defer filename.deinit();

    if (E.filename.items.len != 0) {
        filename = try E.filename.clone();
    } else {
        try filename.appendSlice("[No Name]");
    }

    const rstatus = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ E.cy + 1, E.numrows });
    const status = try std.fmt.allocPrint(allocator, "{s} - {d} lines", .{ filename.items, E.numrows });
    var len = status.len;
    if (len > E.screencols) len = E.screencols;
    try ab.appendSlice(status);

    while (len < E.screencols) {
        if (E.screencols - len == rstatus.len) {
            try ab.appendSlice(rstatus);
            break;
        } else {
            try ab.appendSlice(" ");
            len += 1;
        }
    }
    try ab.appendSlice("\x1b[m");
    try ab.appendSlice("\r\n");
}

fn editorDrawMessageBar(ab: *ArrayList(u8)) !void {
    try ab.appendSlice("\x1b[K");
    var msglen: u32 = @truncate(E.statusmsg.items.len);
    if (msglen > E.screencols)
        msglen = E.screencols;
    if (msglen != 0) {
        if (time.timestamp() - E.statusmsg_time < 5) {
            try ab.appendSlice(E.statusmsg.items);
        }
    }
}

//terminal

fn getCursorPosition(rows: *u32, cols: *u32) i2 {
    var buf: [32]u8 = undefined;
    var i: u32 = 0;

    if (c.write(c.STDOUT_FILENO, "\x1b[6n", 4) != 4) return -1;

    while (i < buf.len) {
        if (c.read(c.STDIN_FILENO, &buf[i], 1) != 1) break;
        if (buf[i] == 'R') {
            i += 1;
            break;
        }
        i += 1;
    }

    if (buf[0] != '\x1b') return -1;
    if (buf[1] != '[') return -1;

    if (c.sscanf(&buf[2], "%d;%d", rows, cols) != 2) return -1;
    return 0;
}

fn getWindowSize(rows: *u32, cols: *u32) i2 {
    var ws: c.winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == -1) {
        if (c.write(c.STDOUT_FILENO, "\x1b[999C\x1b[999B", 12) != 12) return -1;
        return getCursorPosition(rows, cols);
    } else if (ws.ws_col == 0) {
        if (c.write(c.STDOUT_FILENO, "\x1b[999C\x1b[999B", 12) != 12) return -1;
        return getCursorPosition(rows, cols);
    } else {
        cols.* = ws.ws_col;
        rows.* = ws.ws_row;
        return 0;
    }
}

fn editorRowCxToRx(row: *ArrayList(u8), cx: u32) u32 {
    var rx: u32 = 0;

    for (0..cx) |j| {
        var ch = row.items[j];
        if (ch == '\t') {
            rx += (KILO_TAB_STOP - 1) - (rx % KILO_TAB_STOP);
        }
        rx += 1;
    }

    return rx;
}

fn editorUpdateRow(row: *erow) !void {
    row.renderData.clearAndFree();
    for (row.rowData.items) |ch| {
        if (ch == '\t') {
            for (0..KILO_TAB_STOP) |_| {
                try row.renderData.append(' ');
            }
        } else try row.renderData.append(ch);
    }
}

// row operations
fn editorAppendRow(content: []const u8) !void {
    var row: erow = erow.init(allocator);
    try row.rowData.appendSlice(content);
    try editorUpdateRow(&row);
    try E.rows.append(row);
    E.numrows += 1;
}

fn editorRowInsertChar(row: *erow, at: u32, ch: u8) !void {
    var insertPos = at;
    if (insertPos < 0) insertPos = @truncate(row.rowData.items.len);
    if (insertPos > row.rowData.items.len) insertPos = @truncate(row.rowData.items.len);
    try row.rowData.insert(insertPos, ch);
    try editorUpdateRow(row);
}

fn editorInsertChar(ch: u8) !void {
    if (E.cy == E.numrows) {
        try editorAppendRow("");
    }
    try editorRowInsertChar(&E.rows.items[E.cy], E.cx, ch);
    E.cx += 1;
}

fn editorRefreshScreen() !void {
    editorScroll();

    var ab = ArrayList(u8).init(allocator);
    defer ab.deinit();

    try ab.appendSlice("\x1b[?25l");
    try ab.appendSlice("\x1b[H");
    try editorDrawRows(&ab);
    try editorDrawStatusBar(&ab);
    try editorDrawMessageBar(&ab);
    const cursorCommand = try std.fmt.allocPrint(allocator, "\x1b[{d};{d}H", .{ (E.cy - E.rowoff) + 1, (E.rx - E.coloff) + 1 });
    defer allocator.free(cursorCommand);
    try ab.appendSlice(cursorCommand);

    try ab.appendSlice("\x1b[?25h");

    for (ab.items) |value| {
        std.debug.print("{c}", .{value});
    }
}

fn editorSetStatusMessage(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [256]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, fmt, args);
    E.statusmsg.deinit();
    try E.statusmsg.appendSlice(message);
    E.statusmsg_time = time.timestamp();
}

fn editorReadKey() u32 {
    var readChar: u8 = undefined;
    if (stdin.readByte()) |res| {
        readChar = res;
    } else |err| {
        if (err == error.EndOfStream) {
            readChar = 0;
        } else {
            die("read");
        }
    }

    if (readChar == '\x1b') {
        var seq: [3]u8 = undefined;
        if (c.read(c.STDIN_FILENO, &seq[0], 1) != 1) return '\x1b';
        if (c.read(c.STDIN_FILENO, &seq[1], 1) != 1) return '\x1b';

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                if (c.read(c.STDIN_FILENO, &seq[2], 1) != 1) return '\x1b';
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1' => return @intFromEnum(editorKey.HOME_KEY),
                        '3' => return @intFromEnum(editorKey.DEL_KEY),
                        '4' => return @intFromEnum(editorKey.END_KEY),
                        '5' => return @intFromEnum(editorKey.PAGE_UP),
                        '6' => return @intFromEnum(editorKey.PAGE_DOWN),
                        '7' => return @intFromEnum(editorKey.HOME_KEY),
                        '8' => return @intFromEnum(editorKey.END_KEY),
                        else => {},
                    }
                }
            } else {
                switch (seq[1]) {
                    'A' => return @intFromEnum(editorKey.ARROW_UP),
                    'B' => return @intFromEnum(editorKey.ARROW_DOWN),
                    'C' => return @intFromEnum(editorKey.ARROW_RIGHT),
                    'D' => return @intFromEnum(editorKey.ARROW_LEFT),
                    'H' => return @intFromEnum(editorKey.HOME_KEY),
                    'F' => return @intFromEnum(editorKey.END_KEY),
                    else => {},
                }
            }
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return @intFromEnum(editorKey.HOME_KEY),
                'F' => return @intFromEnum(editorKey.END_KEY),
                else => {},
            }
        }

        return '\x1b';
    } else {
        return readChar;
    }
}

fn disableRawMode() callconv(.C) void {
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &E.orig_termios) != 0) {
        die("Failed to restore terminal attributes\nRestart Terminal.");
    }
}

fn enableRawMode() void {
    if (c.tcgetattr(c.STDIN_FILENO, &E.orig_termios) != 0) {
        die("Failed to get terminal attributes");
    }

    _ = c.atexit(disableRawMode);
    var raw: c.termios = E.orig_termios;

    raw.c_iflag &= ~(@as(c_uint, c.BRKINT) | @as(c_uint, c.ICRNL) | @as(c_uint, c.INPCK) | @as(c_uint, c.ISTRIP) | @as(c_uint, c.IXON));
    raw.c_oflag &= ~(@as(c_uint, c.OPOST));
    raw.c_cflag |= (@as(c_uint, c.CS8));
    raw.c_lflag &= ~(@as(c_uint, c.ECHO) | @as(c_uint, c.ICANON) | @as(c_uint, c.IEXTEN) | @as(c_uint, c.ISIG));
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1;

    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) == -1) die("tcsetattr");
}

fn die(str: []const u8) void {
    print("{s}", .{"\x1b[2J"});
    print("{s}", .{"\x1b[H"});

    print("{s}\r\n", .{str});
    c.exit(1);
}

//init

pub fn initEditor() void {
    E.cx = 0;
    E.cy = 0;
    E.rx = 0;
    E.rowoff = 0;
    E.coloff = 0;
    E.numrows = 0;
    if (getWindowSize(&E.screenrows, &E.screencols) == -1) die("getWindowSize");
    E.screenrows -= 2;
    var rows = ArrayList(erow).init(allocator);
    var filename = ArrayList(u8).init(allocator);
    var statusmsg = ArrayList(u8).init(allocator);
    E.rows = rows;
    E.filename = filename;
    E.statusmsg = statusmsg;
    E.statusmsg_time = 0;
}
pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    enableRawMode();
    initEditor();
    defer deinitEditor();

    if (args.len >= 2) {
        try editorOpen(args[1]);
    }

    try editorSetStatusMessage("HELP: Ctrl-Q = quit", .{});

    while (true) {
        try editorRefreshScreen();
        try editorProcessKeypress();
    }
}

fn deinitEditor() void {
    for (E.rows.items) |*array_list| {
        array_list.deinit();
    }

    E.filename.deinit();
}
