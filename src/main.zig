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

    raw.c_iflag &= ~(@as(c_uint, c.IXON) | @as(c_uint, c.ICRNL));
    raw.c_lflag &= ~(@as(c_uint, c.ECHO) | @as(c_uint, c.ICANON) | @as(c_uint, c.IEXTEN) | @as(c_uint, c.ISIG));
    _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
}

pub fn main() !void {
    try enableRawMode();

    const stdin = std.io.getStdIn().reader();

    while (true) {
        const ch: u8 = try stdin.readByte();
        if (ch == 'q') return;
        if (ascii.isControl(ch)) {
            try stdout.print("{}", .{ch});
        } else {
            try stdout.print("{u}", .{ch});
        }
    }
}
