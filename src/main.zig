const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
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

    raw.c_lflag &= @as(c_uint, c.ECHO);
    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
}

pub fn main() !void {
    try enableRawMode();

    const stdin = std.io.getStdIn().reader();
    var buf: [100]u8 = undefined;

    if (try stdin.readUntilDelimiterOrEof(&buf, 'q')) |user_input| {
        _ = user_input;
    }
}
