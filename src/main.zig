const std = @import("std");
const ascii = std.ascii;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("ctype.h");
});

var orig_termios: c.termios = undefined;
const stdout = std.io.getStdOut().writer();

fn disableRawMode() callconv(.C) void {
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &orig_termios) != 0) {
        _ = c.printf("Failed to restore terminal attributes\nRestart Terminal.");
        return;
    }
}

fn enableRawMode() !void {
    if (c.tcgetattr(c.STDIN_FILENO, &orig_termios) != 0) {
        try stdout.print("Failed to get terminal attributes\n", .{});
        return;
    }

    _ = c.atexit(disableRawMode);
    var raw: c.termios = orig_termios;

    raw.c_iflag &= ~(@as(c_uint, c.BRKINT) | @as(c_uint, c.ICRNL) | @as(c_uint, c.INPCK) | @as(c_uint, c.ISTRIP) | @as(c_uint, c.IXON));
    raw.c_oflag &= ~(@as(c_uint, c.OPOST));
    raw.c_cflag |= (@as(c_uint, c.CS8));
    raw.c_lflag &= ~(@as(c_uint, c.ECHO) | @as(c_uint, c.ICANON) | @as(c_uint, c.IEXTEN) | @as(c_uint, c.ISIG));
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1;

    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
}

pub fn main() !void {
    try enableRawMode();

    const stdin = std.io.getStdIn().reader();

    while (true) {
        var ch: u8 = undefined;
        ch = stdin.readByte() catch 0;
    
        if (ascii.isControl(ch)) {
            try stdout.print("{}\r\n", .{ch});
        } else {
            try stdout.print("{u}\r\n", .{ch});
        }
    
        if (ch == 'q') return;
    }
}
