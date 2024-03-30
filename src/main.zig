//adjahkfhjsdifsbhfslFIXME: Cursor blinks weirdly, apperantly never worked?

//import/include
const std = @import("std");
const ascii = std.ascii;
const print = std.debug.print;
const time = std.time;
const ArrayList = std.ArrayList;
const builtin = std.builtin;
const os = std.os;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("ctype.h");
    @cInclude("sys/ioctl.h");
});

//enum
const editorKey = enum(u32) { BACKSPACE = 127, ARROW_LEFT = 1000, ARROW_RIGHT, ARROW_UP, ARROW_DOWN, DEL_KEY, HOME_KEY, END_KEY, PAGE_UP, PAGE_DOWN };
const editorHighlight = enum(u32) { HL_NORMAL = 0, HL_COMMENT, HL_STRING, HL_NUMBER, HL_MATCH };

const editorSyntax = struct {
    filetype: []const u8,
    filematch: []const []const u8,
    singleline_comment_start: []const u8,
    flags: HL_HIGHLIGHT_FLAGS,
};

const erow = struct {
    const Self = @This();

    rowData: std.ArrayList(u8),
    renderData: std.ArrayList(u8),
    hl: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) erow {
        return .{ .rowData = std.ArrayList(u8).init(alloc), .renderData = std.ArrayList(u8).init(alloc), .hl = std.ArrayList(u8).init(alloc) };
    }

    pub fn deinit(self: Self) void {
        self.renderData.deinit();
        self.rowData.deinit();
        self.hl.deinit();
    }
};

const editorConfig = struct {
    var orig_termios: os.termios = undefined;
    var cx: u32 = undefined;
    var cy: u32 = undefined;
    var rx: u32 = undefined;
    var rowoff: u32 = undefined;
    var coloff: u32 = undefined;
    var screenrows: u32 = undefined;
    var screencols: u32 = undefined;
    var numrows: u32 = undefined;
    var rows: ArrayList(erow) = undefined;
    var dirty: u32 = undefined;
    var filename: ?ArrayList(u8) = null;
    var statusmsg: ArrayList(u8) = undefined;
    var statusmsg_time: i64 = undefined;
    var syntax: ?editorSyntax = null;
};

const E = editorConfig;

//filetypes
var HLDB: ArrayList(editorSyntax) = undefined;
const C_HL_extensions = [_][]const u8{ ".c", ".h", ".cpp" };
const ZIG_HL_extensions = [_][]const u8{".zig"};

//const
const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();
const ZILO_VERSION = "0.0.1";
const KILO_TAB_STOP = 8;
const KILO_QUIT_TIMES = 3;
pub const HL_HIGHLIGHT_FLAGS = packed struct(u32) {
    numbers: bool = false,
    strings: bool = false,

    _padding: u30 = 0,
};
//input

fn editorPrompt(comptime prompt: []const u8, callback: *const fn (b: []const u8, ch: u32) void) !?ArrayList(u8) {
    var buf = ArrayList(u8).init(allocator);
    while (true) {
        try editorSetStatusMessage(prompt, .{buf.items});
        try editorRefreshScreen();
        var ch: u32 = editorReadKey();
        if (ch != 0) {
            if (ch == @intFromEnum(editorKey.DEL_KEY) or ch == CTRL_KEY('h') or ch == @intFromEnum(editorKey.BACKSPACE)) {
                if (buf.items.len != 0) {
                    try buf.resize(buf.items.len - 1);
                }
            } else if (ch == '\x1b') {
                try editorSetStatusMessage("", .{});
                if (callback != emptyCallback) {
                    callback(buf.items, ch);
                }
                return null;
            } else if (ch == '\r') {
                if (buf.items.len != 0) {
                    try editorSetStatusMessage("", .{});
                    if (callback != emptyCallback) {
                        callback(buf.items, ch);
                    }
                    return buf;
                }
            } else if (ch >= 32 and ch < 128) {
                try buf.append(@truncate(ch));
            }
            if (callback != emptyCallback) {
                callback(buf.items, ch);
            }
        }
    }
}

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
            if (E.cy >= E.numrows) {} else {
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

    var rowlen: usize = 0;
    if (E.cy < E.numrows) {
        var row = E.rows.items[E.cy];
        rowlen = row.rowData.items.len;
    }
    if (E.cx > rowlen) {
        E.cx = @truncate(rowlen);
    }
}

fn editorProcessKeypress() !void {
    const state = struct {
        var quit_times: u32 = KILO_QUIT_TIMES;
    };
    var pressedQuit: bool = false;

    var ch: u32 = editorReadKey();
    if (ch == 0) return;
    switch (ch) {
        '\r' => {
            try editorInsertNewline();
        },
        CTRL_KEY('q') => {
            //FIXME: is a mess
            pressedQuit = true;
            if (E.dirty != 0) {
                if (state.quit_times > 0) {
                    try editorSetStatusMessage("WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{state.quit_times});
                    state.quit_times -= 1;
                    return;
                } else {
                    print("{s}", .{"\x1b[2J"});
                    print("{s}", .{"\x1b[H"});
                    closeProgram();
                }
            } else {
                print("{s}", .{"\x1b[2J"});
                print("{s}", .{"\x1b[H"});
                closeProgram();
            }
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
        CTRL_KEY('f') => {
            try editorFind();
        },
        @intFromEnum(editorKey.BACKSPACE), CTRL_KEY('h'), @intFromEnum(editorKey.DEL_KEY) => {
            if (ch == @intFromEnum(editorKey.DEL_KEY))
                editorMoveCursor(@intFromEnum(editorKey.ARROW_RIGHT));
            try editorDelChar();
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
            try editorInsertChar(@truncate(ch));
        },
    }
    if (pressedQuit == false) {
        state.quit_times = KILO_QUIT_TIMES;
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
    E.filename.?.deinit();

    for (filename) |ch| {
        try E.filename.?.append(ch);
    }

    try editorSelectSyntaxHighlight();

    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buf: [1000]u8 = undefined;
    while (try file.reader().readUntilDelimiterOrEof(buf[0..], '\n')) |line| {
        try editorInsertRow(E.numrows, line);
    }

    E.dirty = 0;
}

fn emptyCallback(b: []const u8, ch: u32) void {
    _ = b;
    _ = ch;
}

fn editorSave() !void {
    if (E.filename.?.items.len == 0) {
        if (try editorPrompt("Save as: {s} (ESC to cancel)", emptyCallback)) |result| {
            E.filename.?.deinit();
            E.filename.? = result;
        }
        if (E.filename.?.items.len == 0) {
            try editorSetStatusMessage("Save aborted", .{});
            return;
        }
        try editorSelectSyntaxHighlight();
    }

    var allRows: ArrayList(u8) = try editorRowsToString();
    defer allRows.deinit();

    var file = try std.fs.cwd().createFile(E.filename.?.items, .{ .read = false });

    defer file.close();
    if (file.write(allRows.items)) |bytes| {
        try editorSetStatusMessage("{d} bytes written to disk", .{bytes});
        E.dirty = 0;
    } else |err| {
        try editorSetStatusMessage("Can't save! I/O error: {}", .{err});
    }
}

//find

fn editorFindCallback(buf: []const u8, key: u32) void {
    if (key == 0) return;
    const state = struct {
        var last_match: i32 = -1;
        var direction: i32 = 1;
        var saved_hl_line: u32 = undefined;
        var saved_hl: ArrayList(u8) = undefined;
    };

    if (state.saved_hl.items.len != 0) {
        var row = &E.rows.items[state.saved_hl_line];
        row.hl = state.saved_hl;
        state.saved_hl.clearRetainingCapacity();
    }

    if (key == '\r' or key == '\x1b') {
        state.last_match = -1;
        state.direction = 1;
        return;
    } else if (key == @intFromEnum(editorKey.ARROW_RIGHT) or key == @intFromEnum(editorKey.ARROW_DOWN)) {
        state.direction = 1;
    } else if (key == @intFromEnum(editorKey.ARROW_LEFT) or key == @intFromEnum(editorKey.ARROW_UP)) {
        state.direction = -1;
    } else {
        state.last_match = -1;
        state.direction = 1;
    }

    if (state.last_match == -1) {
        state.direction = 1;
    }
    var current: i64 = state.last_match;

    for (0..E.numrows) |_| {
        current += state.direction;

        if (current == -1) {
            current = E.numrows - 1;
        } else if (current == E.numrows) {
            current = 0;
        }

        var row = &E.rows.items[@as(usize, @intCast(current))];
        var match = findSubstring(row.renderData.items, buf);
        if (match != null) {
            state.last_match = @as(i32, @intCast(current));
            E.cy = @as(u32, @intCast(current));
            E.cx = editorRowRxToCx(&row.rowData, match.?);
            E.rowoff = E.numrows;

            state.saved_hl_line = @as(u32, @intCast(current));
            state.saved_hl = row.hl.clone() catch ArrayList(u8).init(allocator);
            if (state.saved_hl.items.len != 0) {
                for (match.?..match.? + buf.len) |i| {
                    row.hl.items[i] = @intFromEnum(editorHighlight.HL_MATCH);
                }
            }

            break;
        }
    }
}

fn editorFind() !void {
    var saved_cx = E.cx;
    var saved_cy = E.cy;
    var saved_coloff = E.coloff;
    var saved_rowoff = E.rowoff;
    var query = try editorPrompt("Search: {s} (Use ESC/Arrows/Enter)", editorFindCallback);
    if (query != null) {
        query.?.deinit();
    } else {
        E.cx = saved_cx;
        E.cy = saved_cy;
        E.coloff = saved_coloff;
        E.rowoff = saved_rowoff;
        return;
    }
}

fn findSubstring(str: []const u8, substr: []const u8) ?u32 {
    var len = str.len;
    var sublen = substr.len;
    if (len == 0) return null;
    if (len < sublen) return null;

    for (0..(len - sublen)) |i| {
        if (std.mem.eql(u8, str[i..(i + sublen)], substr)) {
            return @truncate(i);
        }
    }
    return null;
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
            var current_color: i32 = -1;

            if (len != 0) {
                for (E.coloff..E.coloff + len) |j| {
                    var current = E.rows.items[filerow].renderData.items[j];
                    var hl = E.rows.items[filerow].hl.items[j];
                    if (hl == @intFromEnum(editorHighlight.HL_NORMAL)) {
                        if (current_color != -1) {
                            try ab.appendSlice("\x1b[39m");
                            current_color = -1;
                        }
                        try ab.append(current);
                    } else {
                        var color = editorSyntaxToColor(hl);
                        if (color != current_color) {
                            current_color = @as(i32, @intCast(color));
                            const clen = try std.fmt.allocPrint(allocator, "\x1b[{d}m", .{color});
                            defer allocator.free(clen);
                            try ab.appendSlice(clen);
                        }
                        try ab.append(current);
                    }
                }
                try ab.appendSlice("\x1b[39m");
            }
        }
        try ab.appendSlice("\x1b[K");
        try ab.appendSlice("\r\n");
    }
}

fn editorDrawStatusBar(ab: *ArrayList(u8)) !void {
    try ab.appendSlice("\x1b[7m");
    var filename: ArrayList(u8) = ArrayList(u8).init(allocator);
    defer filename.deinit();

    if (E.filename.?.items.len != 0) {
        filename = try E.filename.?.clone();
    } else {
        try filename.appendSlice("[No Name]");
    }

    var modifiedText = if (E.dirty != 0) "(modified)" else "";

    const filetype = if (E.syntax == null) "no ft" else E.syntax.?.filetype;
    const rstatus = try std.fmt.allocPrint(allocator, "{s} | {d}/{d}", .{ filetype, E.cy + 1, E.numrows });
    const status = try std.fmt.allocPrint(allocator, "{s} - {d} lines {s}", .{ filename.items, E.numrows, modifiedText });
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

    if (os.write(os.STDOUT_FILENO, "\x1b[6n") == error.WriteError) die("write", true);

    while (i < buf.len) {
        if (c.read(os.STDIN_FILENO, &buf[i], 1) != 1) break;
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
    var ws: os.linux.winsize = undefined;
    if (std.os.system.ioctl(os.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == -1) {
        if (os.write(os.STDOUT_FILENO, "\x1b[999C\x1b[999B") == error.WriteError) die("write", true);
        return getCursorPosition(rows, cols);
    } else if (ws.ws_col == 0) {
        if (os.write(os.STDOUT_FILENO, "\x1b[999C\x1b[999B") == error.WriteError) die("write", true);
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

fn editorRowRxToCx(row: *ArrayList(u8), rx: u32) u32 {
    var cur_rx: usize = 0;
    var retcx: usize = undefined;
    for (0..row.items.len) |cx| {
        retcx = cx;
        if (row.items[cx] == '\t') {
            cur_rx += (KILO_TAB_STOP - 1) - (cur_rx % KILO_TAB_STOP);
        }
        cur_rx += 1;
        if (cur_rx > rx) return @truncate(cx);
    }
    return @truncate(retcx);
}

fn editorUpdateRow(row: *erow) !void {
    row.renderData.clearAndFree();
    for (row.rowData.items) |ch| {
        if (ch == '\t') {
            try row.renderData.append(' ');
            var curLen = row.renderData.items.len;
            while (curLen % KILO_TAB_STOP != 0) {
                try row.renderData.append(' ');
                curLen += 1;
            }
        } else try row.renderData.append(ch);
    }
    try editorUpdateSyntax(row);
}

//syntax highlighting

fn is_separator(ch: u8) bool {
    var seperators = ",.()+-/*=~%<>[];";

    return ascii.isWhitespace(ch) or (ch == 0) or (std.mem.indexOf(u8, seperators, &[1]u8{ch}) != null);
}

fn editorUpdateSyntax(row: *erow) !void {
    row.hl.clearAndFree();
    try row.hl.appendNTimes(@intFromEnum(editorHighlight.HL_NORMAL), row.renderData.items.len);

    if (E.syntax == null) return;

    var prev_sep = true;
    var in_string: u8 = 0;
    var i: usize = 0;
    while (i < row.renderData.items.len) {
        var prev_hl = if (i > 0) row.hl.items[i - 1] else @intFromEnum(editorHighlight.HL_NORMAL);
        var ch = row.renderData.items[i];

        if (E.syntax.?.flags.strings) {
            if (in_string > 0) {
                row.hl.items[i] = @intFromEnum(editorHighlight.HL_STRING);
                if (ch == '\\' and i + 1 < row.renderData.items.len) {
                    row.hl.items[i + 1] = @intFromEnum(editorHighlight.HL_STRING);
                    i += 2;
                    continue;
                }
                if (ch == in_string) in_string = 0;
                i += 1;
                prev_sep = true;
                continue;
            } else {
                if (ch == '"' or ch == '\'') {
                    in_string = ch;
                    row.hl.items[i] = @intFromEnum(editorHighlight.HL_STRING);
                    i += 1;
                    continue;
                }
            }
        }

        if (E.syntax.?.flags.numbers) {
            if ((ascii.isDigit(ch) and (prev_sep or prev_hl == @intFromEnum(editorHighlight.HL_NUMBER))) or (ch == '.' and prev_hl == @intFromEnum(editorHighlight.HL_NUMBER))) {
                try row.hl.insert(i, @intFromEnum(editorHighlight.HL_NUMBER));
                i += 1;
                prev_sep = false;
                continue;
            }
        }
        prev_sep = is_separator(ch);
        i += 1;
    }
}

fn editorSyntaxToColor(hl: u32) u32 {
    switch (hl) {
        @intFromEnum(editorHighlight.HL_COMMENT) => return 36,
        @intFromEnum(editorHighlight.HL_NUMBER) => return 31,
        @intFromEnum(editorHighlight.HL_STRING) => return 35,
        @intFromEnum(editorHighlight.HL_MATCH) => return 34,
        else => return 37,
    }
}

fn editorSelectSyntaxHighlight() !void {
    E.syntax = null;
    if (E.filename) |filename| {
        var ext = std.mem.indexOf(u8, filename.items, &[1]u8{'.'});
        for (HLDB.items) |s| {
            for (s.filematch) |fmItem| {
                var is_ext = (fmItem[0] == '.');
                var found = false;
                if (ext) |dotIndex| {
                    var ending = filename.items[dotIndex..filename.items.len];
                    if (is_ext and std.mem.eql(u8, ending, fmItem)) {
                        found = true;
                    }
                } else if (!is_ext and (std.mem.indexOf(u8, filename.items, fmItem) != null)) {
                    found = true;
                }
                if (found) {
                    E.syntax = s;
                    for (E.rows.items) |*row| {
                        try editorUpdateSyntax(row);
                    }
                    return;
                }
            }
        }
    } else return;
}

// row operations
fn editorInsertRow(at: u32, content: []const u8) !void {
    if (at > E.numrows or at < 0) return;

    var row: erow = erow.init(allocator);
    try row.rowData.appendSlice(content);
    try editorUpdateRow(&row);

    try E.rows.insert(at, row);
    E.numrows += 1;
    E.dirty += 1;
}

fn editorFreeRow(row: *erow) void {
    row.rowData.deinit();
    row.renderData.deinit();
}

fn editorDelRow(at: u32) !void {
    if (at < 0 or at >= E.numrows) return;
    editorFreeRow(&E.rows.items[at]);
    _ = E.rows.orderedRemove(at);

    E.numrows -= 1;
    E.dirty += 1;
}

fn editorRowInsertChar(row: *erow, at: u32, ch: u8) !void {
    var insertPos = at;
    if (insertPos < 0 or insertPos > row.rowData.items.len) insertPos = @truncate(row.rowData.items.len);
    try row.rowData.insert(insertPos, ch);
    try editorUpdateRow(row);
    E.dirty += 1;
}

fn editorInsertNewline() !void {
    if (E.cx == 0) {
        try editorInsertRow(E.cy, "");
    } else {
        var row = &E.rows.items[E.cy];
        var end = row.rowData.items.len;
        try editorInsertRow(E.cy + 1, row.rowData.items[E.cx..@truncate(end)]);

        try row.rowData.resize(E.cx);

        try editorUpdateRow(row);
    }
    E.cy += 1;
    E.cx = 0;
}

fn editorRowAppendString(row: *erow, append: []const u8) !void {
    try row.rowData.appendSlice(append);

    try editorUpdateRow(row);
    E.dirty += 1;
}

fn editorRowDelChar(row: *erow, at: u32) !void {
    if (at < 0 or at >= row.rowData.items.len) return;

    _ = row.rowData.orderedRemove(at);

    try editorUpdateRow(row);
    E.dirty += 1;
}

fn editorInsertChar(ch: u8) !void {
    if (E.cy == E.numrows) {
        try editorInsertRow(E.numrows, "");
    }
    try editorRowInsertChar(&E.rows.items[E.cy], E.cx, ch);
    E.cx += 1;
}

fn editorDelChar() !void {
    if (E.cy == E.numrows) return;
    if (E.cx == 0) {
        if (E.cy == 0) {
            return;
        }
    }

    var row = &E.rows.items[E.cy];

    if (E.cx > 0) {
        try editorRowDelChar(row, E.cx - 1);
        E.cx -= 1;
    } else {
        E.cx = @truncate(E.rows.items[E.cy - 1].rowData.items.len);
        try editorRowAppendString(&E.rows.items[E.cy - 1], row.rowData.items);
        try editorDelRow(E.cy);
        E.cy -= 1;
    }
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
    E.statusmsg.clearRetainingCapacity();
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
            die("read", true);
        }
    }

    if (readChar == '\x1b') {
        var seq: [3]u8 = undefined;
        if (c.read(os.STDIN_FILENO, &seq[0], 1) != 1) return '\x1b';
        if (c.read(os.STDIN_FILENO, &seq[1], 1) != 1) return '\x1b';

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                if (c.read(os.STDIN_FILENO, &seq[2], 1) != 1) return '\x1b';
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
    var res = os.tcsetattr(os.STDIN_FILENO, .FLUSH, E.orig_termios);

    if (@TypeOf(res) == os.TermiosSetError) {
        die("Failed to restore terminal attributes\nRestart Terminal.", true);
    }
}

fn enableRawMode() !void {
    var term = try os.tcgetattr(os.STDIN_FILENO);
    if (@TypeOf(term) != os.TermiosGetError) {
        E.orig_termios = term;
    } else {
        die("Failed to get terminal attributes", true);
    }

    var raw: os.termios = E.orig_termios;

    raw.iflag &= ~@as(os.linux.tcflag_t, os.linux.IXON | os.linux.ICRNL | os.linux.BRKINT | os.linux.INPCK | os.linux.ISTRIP);
    raw.oflag &= ~@as(os.linux.tcflag_t, os.linux.OPOST);
    raw.cflag |= os.linux.CS8;
    raw.lflag &= ~@as(
        os.linux.tcflag_t,
        os.linux.ECHO | os.linux.ICANON | os.linux.ISIG | os.linux.IEXTEN,
    );
    raw.cc[os.linux.V.MIN] = 0;
    raw.cc[os.linux.V.TIME] = 1;

    var new = os.tcsetattr(os.STDIN_FILENO, .FLUSH, raw);
    if (@TypeOf(new) == os.TermiosSetError) {
        die("tcsetattr", true);
    }
}

fn die(str: []const u8, exit: bool) void {
    disableRawMode();
    HLDB.deinit();
    print("{s}", .{"\x1b[2J"});
    print("{s}", .{"\x1b[H"});
    print("{s}\r\n", .{str});
    if (exit)
        os.exit(1);
}

//init

pub fn initEditor() void {
    E.cx = 0;
    E.cy = 0;
    E.rx = 0;
    E.rowoff = 0;
    E.coloff = 0;
    E.numrows = 0;
    E.dirty = 0;
    if (getWindowSize(&E.screenrows, &E.screencols) == -1) die("getWindowSize", true);
    E.screenrows -= 2;
    var rows = ArrayList(erow).init(allocator);
    var filename = ArrayList(u8).init(allocator);
    var statusmsg = ArrayList(u8).init(allocator);
    E.rows = rows;
    E.filename = filename;
    E.statusmsg = statusmsg;
    E.statusmsg_time = 0;
}

pub fn setupHLDB() !void {
    HLDB = ArrayList(editorSyntax).init(allocator);
    try HLDB.append(.{ .filetype = "c", .filematch = &C_HL_extensions, .singleline_comment_start = "//", .flags = HL_HIGHLIGHT_FLAGS{ .numbers = true, .strings = true } });
    try HLDB.append(.{ .filetype = "zig", .filematch = &ZIG_HL_extensions, .singleline_comment_start = "//", .flags = HL_HIGHLIGHT_FLAGS{ .numbers = true, .strings = true } });
}

pub fn closeProgram() void {
    disableRawMode();
    os.exit(0);
}

pub fn main() !void {
    try setupHLDB();
    defer HLDB.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    try enableRawMode();
    initEditor();
    defer deinitEditor();

    _ = args.next();
    if (args.next()) |arg| {
        try editorOpen(arg);
    }

    try editorSetStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find", .{});

    while (true) {
        try editorRefreshScreen();
        try editorProcessKeypress();
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    die(msg, false);
    const first_trace_addr = ret_addr orelse @returnAddress();
    std.debug.panicImpl(error_return_trace, first_trace_addr, msg);
}

fn deinitEditor() void {
    for (E.rows.items) |*array_list| {
        array_list.deinit();
    }

    E.filename.?.deinit();
}
