const std = @import("std");
const posix = std.posix;

extern var environ: [*:null]?[*:0]u8;

const explosion_wav = @embedFile("SoundGen/explosion.wav");
const flag_wav = @embedFile("SoundGen/flag.wav");

const AudioPlayer = struct {
    cmd: [*:0]const u8,
    args: []const [*:0]const u8,
};

const players = [_]AudioPlayer{
    .{ .cmd = "ffplay", .args = &.{ "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet" } },
    .{ .cmd = "aplay", .args = &.{ "aplay", "-q" } },
    .{ .cmd = "paplay", .args = &.{"paplay"} },
    .{ .cmd = "afplay", .args = &.{"afplay"} },
    .{ .cmd = "mpv", .args = &.{ "mpv", "--no-video", "--really-quiet" } },
    .{ .cmd = "play", .args = &.{ "play", "-q" } },
};

var audio_player: ?*const AudioPlayer = null;

fn detectAudioPlayer() void {
    const paths = [_][]const u8{
        "/usr/bin/", "/usr/local/bin/", "/bin/", "/usr/sbin/",
    };
    for (&players) |*player| {
        const cmd = std.mem.span(player.cmd);
        for (paths) |dir| {
            var buf: [256]u8 = undefined;
            const full = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ dir, cmd }) catch continue;
            posix.access(full, posix.F_OK) catch continue;
            audio_player = player;
            return;
        }
    }
}

fn playWav(tmp_path: [*:0]const u8) void {
    const player = audio_player orelse return;
    const pid = posix.fork() catch return;
    if (pid == 0) {
        const pid2 = posix.fork() catch posix.exit(1);
        if (pid2 == 0) {
            var argv: [16:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 16;
            for (player.args, 0..) |arg, i| argv[i] = arg;
            argv[player.args.len] = tmp_path;
            _ = posix.execvpeZ(player.cmd, &argv, environ) catch {};
            posix.exit(1);
        }
        posix.exit(0);
    }
    _ = posix.waitpid(pid, 0);
}

fn playExplosion() void {
    const tmp = "/tmp/MineExplosion.wav";
    const file = std.fs.createFileAbsolute(tmp, .{}) catch return;
    file.writeAll(explosion_wav) catch {
        file.close();
        return;
    };
    file.close();
    playWav(tmp);
}

fn playFlag() void {
    const tmp = "/tmp/MineFlag.wav";
    const file = std.fs.createFileAbsolute(tmp, .{}) catch return;
    file.writeAll(flag_wav) catch {
        file.close();
        return;
    };
    file.close();
    playWav(tmp);
}

const Color = struct {
    pub const Reset = "\x1b[0m";
    pub const Red = "\x1b[31m";
    pub const Green = "\x1b[32m";
    pub const Yellow = "\x1b[33m";
    pub const Blue = "\x1b[34m";
    pub const Magenta = "\x1b[35m";
    pub const Cyan = "\x1b[36m";
    pub const DarkGray = "\x1b[90m";
    pub const BrightRed = "\x1b[91m";

    pub fn getNumberColor(n: u4) []const u8 {
        return switch (n) {
            1 => Blue,
            2 => Green,
            3 => BrightRed,
            4 => Magenta,
            5 => Yellow,
            6 => Cyan,
            7 => Red,
            8 => Yellow,
            else => Reset,
        };
    }
};

const Difficulty = enum {
    easy,
    hard,
    extreme,

    pub fn getParams(self: Difficulty) struct { w: u32, h: u32, mines: u32 } {
        return switch (self) {
            .easy => .{ .w = 10, .h = 10, .mines = 10 },
            .hard => .{ .w = 20, .h = 15, .mines = 40 },
            .extreme => .{ .w = 30, .h = 16, .mines = 99 },
        };
    }
};

const Cell = packed struct(u8) {
    mine: bool = false,
    revealed: bool = false,
    flagged: bool = false,
    neighbor_mines: u4 = 0,
    _reserved: u1 = 0,
};

const GameState = enum { playing, won, lost };
const FaceState = enum { smile, startled, dead, cool };

fn getTermSize() struct { cols: u32, rows: u32 } {
    const linux = std.os.linux;
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0 and ws.row > 0) {
        return .{ .cols = ws.col, .rows = ws.row };
    }
    return .{ .cols = 80, .rows = 24 };
}

fn countFlags(game: *const Game) u32 {
    var n: u32 = 0;
    for (game.cells) |c| if (c.flagged) {
        n += 1;
    };
    return n;
}

const Game = struct {
    width: u32,
    height: u32,
    mine_count: u32,
    cells: []Cell,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    state: GameState = .playing,
    face: FaceState = .smile,
    start_time: i64 = 0,
    first_move: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32, mines: u32) !Game {
        const cells = try allocator.alloc(Cell, w * h);
        @memset(cells, Cell{});
        return .{
            .width = w,
            .height = h,
            .mine_count = mines,
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

        var placed: u32 = 0;

        while (placed < self.mine_count) {
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
    detectAudioPlayer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var term = try Term.init();
    defer term.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    const menu_ts = getTermSize();
    const menu_col = if (menu_ts.cols > 40) (menu_ts.cols - 40) / 2 else 1;
    const menu_row = if (menu_ts.rows > 10) (menu_ts.rows - 10) / 2 else 1;

    try w.print("\x1b[2J", .{});
    try w.print("\x1b[{d};{d}H{s}=== ZIGSWEEPER ==={s}", .{ menu_row, menu_col, Color.Cyan, Color.Reset });
    try w.print("\x1b[{d};{d}HChoose difficulty:", .{ menu_row + 2, menu_col });
    try w.print("\x1b[{d};{d}H{s}1.{s} Easy    (10x10, 10 mines)", .{ menu_row + 4, menu_col, Color.Green, Color.Reset });
    try w.print("\x1b[{d};{d}H{s}2.{s} Hard    (20x15, 40 mines)", .{ menu_row + 5, menu_col, Color.Yellow, Color.Reset });
    try w.print("\x1b[{d};{d}H{s}3.{s} Extreme (30x16, 99 mines)", .{ menu_row + 6, menu_col, Color.Red, Color.Reset });
    try w.print("\x1b[{d};{d}HPress 1, 2, 3 or Q to quit.", .{ menu_row + 8, menu_col });
    try w.flush();

    var diff: Difficulty = .easy;
    menu_loop: while (true) {
        var key_buf: [1]u8 = undefined;
        const bytes_read = try posix.read(posix.STDIN_FILENO, &key_buf);
        if (bytes_read == 0) continue;
        switch (key_buf[0]) {
            '1' => {
                diff = .easy;
                break :menu_loop;
            },
            '2' => {
                diff = .hard;
                break :menu_loop;
            },
            '3' => {
                diff = .extreme;
                break :menu_loop;
            },
            'q' => return,
            else => {},
        }
    }

    const params = diff.getParams();
    var game = try Game.init(allocator, params.w, params.h, params.mines);
    defer game.deinit();

    while (game.state == .playing) {
        const ts = getTermSize();
        const board_w = game.width * 2 + 2;
        const board_h = game.height + 5;
        const col_off = if (ts.cols > board_w) (ts.cols - board_w) / 2 else 0;
        const row_off = if (ts.rows > board_h) (ts.rows - board_h) / 2 else 0;

        try w.print("\x1b[2J", .{});

        const flags_placed = countFlags(&game);
        const mines_left: i32 = @as(i32, @intCast(game.mine_count)) - @as(i32, @intCast(flags_placed));
        const elapsed = if (game.start_time > 0) @divTrunc(std.time.milliTimestamp() - game.start_time, 1000) else 0;
        const face_str = switch (game.face) {
            .smile => ":-)",
            .startled => ":-O",
            .dead => "X-(",
            .cool => "B-)",
        };
        try w.print("\x1b[{d};{d}H", .{ row_off + 1, col_off + 1 });
        try w.print("{s}+", .{Color.DarkGray});
        var bi: u32 = 0;
        while (bi < board_w - 2) : (bi += 1) try w.writeAll("-");
        try w.print("+{s}", .{Color.Reset});

        try w.print("\x1b[{d};{d}H", .{ row_off + 2, col_off + 1 });
        try w.print("{s}|{s}", .{ Color.DarkGray, Color.Reset });
        try w.print(" {s}{d:0>3}{s}", .{ Color.BrightRed, @max(mines_left, 0), Color.Reset });
        const inner = board_w - 2;
        const pad_total = if (inner > 9) inner - 9 else 0; // "000" + "   " + face + "   " + "000" = 3+3+3+3+3=15... simpler:
        const left_pad = pad_total / 2;
        const right_pad = pad_total - left_pad;
        var p: u32 = 0;
        while (p < left_pad) : (p += 1) try w.writeByte(' ');
        try w.print("{s}{s}{s}", .{ Color.Yellow, face_str, Color.Reset });
        p = 0;
        while (p < right_pad) : (p += 1) try w.writeByte(' ');
        try w.print(" {s}{d:0>3}{s}", .{ Color.Green, @min(elapsed, 999), Color.Reset });
        try w.print("{s}|{s}", .{ Color.DarkGray, Color.Reset });

        try w.print("\x1b[{d};{d}H", .{ row_off + 3, col_off + 1 });
        try w.print("{s}+", .{Color.DarkGray});
        bi = 0;
        while (bi < board_w - 2) : (bi += 1) try w.writeAll("-");
        try w.print("+{s}", .{Color.Reset});

        for (0..game.height) |y| {
            try w.print("\x1b[{d};{d}H", .{ row_off + 4 + y, col_off + 1 });
            try w.print("{s}|{s}", .{ Color.DarkGray, Color.Reset });
            for (0..game.width) |x| {
                const is_cursor = (x == game.cursor_x and y == game.cursor_y);
                const cell = game.cells[game.getIndex(@intCast(x), @intCast(y))];
                if (is_cursor) try w.writeAll("\x1b[7m");
                if (cell.revealed) {
                    if (cell.mine) {
                        try w.print("{s}* {s}", .{ Color.BrightRed, Color.Reset });
                    } else if (cell.neighbor_mines == 0) {
                        try w.print("{s}  {s}", .{ Color.DarkGray, Color.Reset });
                    } else {
                        const nc = Color.getNumberColor(cell.neighbor_mines);
                        try w.print("{s}{d} {s}", .{ nc, cell.neighbor_mines, Color.Reset });
                    }
                } else if (cell.flagged) {
                    try w.print("{s}! {s}", .{ Color.Yellow, Color.Reset });
                } else {
                    try w.print("{s}# {s}", .{ Color.DarkGray, Color.Reset });
                }
                if (is_cursor) try w.writeAll("\x1b[27m");
            }
            try w.print("{s}|{s}", .{ Color.DarkGray, Color.Reset });
        }

        try w.print("\x1b[{d};{d}H", .{ row_off + 4 + game.height, col_off + 1 });
        try w.print("{s}+", .{Color.DarkGray});
        bi = 0;
        while (bi < board_w - 2) : (bi += 1) try w.writeAll("-");
        try w.print("+{s}", .{Color.Reset});

        try w.print("\x1b[{d};{d}H", .{ row_off + 5 + game.height, col_off + 1 });
        try w.print("{s}HJKL{s}:move  {s}SPC{s}:dig  {s}F{s}:flag  {s}Q{s}:quit", .{ Color.Cyan, Color.Reset, Color.Cyan, Color.Reset, Color.Cyan, Color.Reset, Color.Cyan, Color.Reset });

        try w.flush();

        var key_buf: [1]u8 = undefined;
        const bytes_read = try posix.read(posix.STDIN_FILENO, &key_buf);
        if (bytes_read == 0) continue;

        if (game.face == .startled) game.face = .smile;

        switch (key_buf[0]) {
            'q' => break,
            'k' => if (game.cursor_y > 0) {
                game.cursor_y -= 1;
            },
            'j' => if (game.cursor_y < game.height - 1) {
                game.cursor_y += 1;
            },
            'h' => if (game.cursor_x > 0) {
                game.cursor_x -= 1;
            },
            'l' => if (game.cursor_x < game.width - 1) {
                game.cursor_x += 1;
            },
            ' ' => {
                if (game.first_move) game.start_time = std.time.milliTimestamp();
                const prev_state = game.state;
                game.reveal(game.cursor_x, game.cursor_y);
                if (game.state == .lost and prev_state == .playing) {
                    game.face = .dead;
                    playExplosion();
                } else if (game.state == .won) {
                    game.face = .cool;
                }
            },
            'f' => {
                const idx = game.getIndex(game.cursor_x, game.cursor_y);
                if (!game.cells[idx].revealed) {
                    game.cells[idx].flagged = !game.cells[idx].flagged;
                    game.face = .startled;
                    playFlag();
                }
            },
            else => {},
        }
    }

    const ts = getTermSize();
    const board_w = game.width * 2 + 2;
    const board_h = game.height + 5;
    const col_off = if (ts.cols > board_w) (ts.cols - board_w) / 2 else 0;
    const row_off = if (ts.rows > board_h) (ts.rows - board_h) / 2 else 0;

    try w.print("\x1b[2J", .{});
    try w.print("\x1b[{d};{d}H", .{ row_off + 1, col_off + 1 });
    if (game.state == .won) {
        try w.print("{s}B-)  YOU WIN!  B-){s}", .{ Color.Green, Color.Reset });
    } else if (game.state == .lost) {
        try w.print("{s}X-(  BOOM!  X-({s}", .{ Color.BrightRed, Color.Reset });
    }
    try w.flush();
    std.Thread.sleep(2 * std.time.ns_per_s);
}
