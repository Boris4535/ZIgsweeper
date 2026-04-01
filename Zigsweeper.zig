const std = @import("std");
const posix = std.posix;

const Cell = packed struct(u8) {
    mine: bool = false,
    revealed: bool = false,
    flagged: bool = false,
    neighbor_mines: u4 = 0,
    _reserved: u1 = 0,
};

const GameState = enum { playing, won, lost };

const Game = struct {
    width: u32,
    height: u32,
    cells: []Cell,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    state: GameState = .playing,
    first_move: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Game {
        const cells = try allocator.alloc(Cell, w * h);
        @memset(cells, Cell{});
        return .{
            .width = w,
            .height = h,
            .cells = cells,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Game) void {
        self.allocator.free(self.cells);
    }

    fn getIndex(self: Game, x: u32, y: u32) u32 {
        return y * self.width + x;
    }

    fn placeMines(self: *Game, safe_x: u32, safe_y: u32) void {
        var prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(std.time.milliTimestamp())));
        const random = prng.random();
        const total_cells = self.width * self.height;
        const mine_count = total_cells / 8;
        var placed: u32 = 0;

        while (placed < mine_count) {
            const rx = random.intRangeLessThan(u32, 0, self.width);
            const ry = random.intRangeLessThan(u32, 0, self.height);

            if ((rx == safe_x and ry == safe_y) or self.cells[self.getIndex(rx, ry)].mine) {
                continue;
            }

            self.cells[self.getIndex(rx, ry)].mine = true;
            placed += 1;
        }

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                if (self.cells[self.getIndex(@intCast(x), @intCast(y))].mine) continue;
                self.cells[self.getIndex(@intCast(x), @intCast(y))].neighbor_mines =
                    self.countMines(@as(i32, @intCast(x)), @as(i32, @intCast(y)));
            }
        }
    }

    fn countMines(self: Game, x: i32, y: i32) u4 {
        var count: u4 = 0;
        const w = @as(i32, @intCast(self.width));
        const h = @as(i32, @intCast(self.height));
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx = x + dx;
                const ny = y + dy;
                if (nx >= 0 and nx < w and ny >= 0 and ny < h) {
                    if (self.cells[self.getIndex(@intCast(nx), @intCast(ny))].mine) count += 1;
                }
            }
        }
        return count;
    }

    pub fn reveal(self: *Game, x: u32, y: u32) void {
        if (self.state != .playing) return;
        const idx = self.getIndex(x, y);
        if (self.cells[idx].revealed or self.cells[idx].flagged) return;

        if (self.first_move) {
            self.placeMines(x, y);
            self.first_move = false;
        }

        self.cells[idx].revealed = true;
        if (self.cells[idx].mine) {
            self.state = .lost;
            return;
        }

        if (self.cells[idx].neighbor_mines == 0) {
            const w = @as(i32, @intCast(self.width));
            const h = @as(i32, @intCast(self.height));
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = @as(i32, @intCast(x)) + dx;
                    const ny = @as(i32, @intCast(y)) + dy;
                    if (nx >= 0 and nx < w and ny >= 0 and ny < h) {
                        self.reveal(@intCast(nx), @intCast(ny));
                    }
                }
            }
        }
        self.checkWin();
    }

    fn checkWin(self: *Game) void {
        for (self.cells) |cell| {
            if (!cell.mine and !cell.revealed) return;
        }
        self.state = .won;
    }
};

const Term = struct {
    orig_termios: posix.termios,

    pub fn init() !Term {
        const orig = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, raw);
        _ = try posix.write(posix.STDOUT_FILENO, "\x1b[?1049h\x1b[?25l");
        return .{ .orig_termios = orig };
    }

    pub fn deinit(self: Term) void {
        posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, self.orig_termios) catch {};
        _ = posix.write(posix.STDOUT_FILENO, "\x1b[?1049l\x1b[?25h") catch {};
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var term = try Term.init();
    defer term.deinit();

    var game = try Game.init(allocator, 20, 10);
    defer game.deinit();

    // Zig 0.15 writer API: supply an explicit backing buffer
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    while (game.state == .playing) {
        try w.print("\x1b[2J\x1b[H", .{});
        try w.print("ZigSweeper - WASD to move, SPACE to reveal, F to flag, Q to quit\n\n", .{});

        for (0..game.height) |y| {
            for (0..game.width) |x| {
                const is_cursor = (x == game.cursor_x and y == game.cursor_y);
                const cell = game.cells[game.getIndex(@intCast(x), @intCast(y))];

                if (is_cursor) try w.writeAll("\x1b[7m");

                if (cell.revealed) {
                    if (cell.mine) {
                        try w.writeAll("* ");
                    } else if (cell.neighbor_mines == 0) {
                        try w.writeAll(". ");
                    } else {
                        try w.print("{d} ", .{cell.neighbor_mines});
                    }
                } else if (cell.flagged) {
                    try w.writeAll("F ");
                } else {
                    try w.writeAll("? ");
                }

                if (is_cursor) try w.writeAll("\x1b[0m");
            }
            try w.writeAll("\n");
        }
        try w.flush();

        // Use posix.read directly for raw single-byte terminal input —
        // cleaner than fighting the new std.Io.Reader API for a 1-byte read.
        var key_buf: [1]u8 = undefined;
        const bytes_read = try posix.read(posix.STDIN_FILENO, &key_buf);
        if (bytes_read == 0) continue;

        switch (key_buf[0]) {
            'q' => break,
            'w' => if (game.cursor_y > 0) {
                game.cursor_y -= 1;
            },
            's' => if (game.cursor_y < game.height - 1) {
                game.cursor_y += 1;
            },
            'a' => if (game.cursor_x > 0) {
                game.cursor_x -= 1;
            },
            'd' => if (game.cursor_x < game.width - 1) {
                game.cursor_x += 1;
            },
            ' ' => game.reveal(game.cursor_x, game.cursor_y),
            'f' => {
                const idx = game.getIndex(game.cursor_x, game.cursor_y);
                if (!game.cells[idx].revealed) game.cells[idx].flagged = !game.cells[idx].flagged;
            },
            else => {},
        }
    }

    try w.print("\x1b[2J\x1b[H", .{});
    if (game.state == .won) try w.writeAll("YOU WON!\n") else try w.writeAll("BOOM!\n");
    try w.flush();
    std.Thread.sleep(2 * std.time.ns_per_s);
}
