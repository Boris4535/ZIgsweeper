const std = @import("std");
const posix = std.posix;

extern var environ: [*:null]?[*:0]u8;

const beep_wav = @embedFile("SoundGen/eat.wav");

const AudioPlayer = struct {
    cmd: [*:0]const u8,
    args: []const [*:0]const u8,
};

const players = [_]AudioPlayer{
    .{ .cmd = "ffplay", .args = &.{ "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet" } },
    .{ .cmd = "aplay", .args = &.{ "aplay", "-q" } },
    .{ .cmd = "paplay", .args = &.{"paplay"} },
    .{ .cmd = "afplay", .args = &.{"afplay"} }, // macOS
    .{ .cmd = "mpv", .args = &.{ "mpv", "--no-video", "--really-quiet" } },
    .{ .cmd = "sox", .args = &.{ "play", "-q" } },
};

var audio_player: ?*const AudioPlayer = null;

fn detectAudioPlayer() void {
    for (&players) |*player| {
        const paths = [_][]const u8{
            "/usr/bin/", "/usr/local/bin/", "/bin/", "/usr/sbin/",
        };
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
        const pid2 = posix.fork() catch {
            posix.exit(1);
        };

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

fn playBeep() void {
    const tmp = "/tmp/SnakeEat.wav";
    const file = std.fs.createFileAbsolute(tmp, .{}) catch return;
    file.writeAll(beep_wav) catch {
        file.close();
        return;
    };
    file.close();
    playWav(tmp);
}

const Point = struct {
    x: i32,
    y: i32,

    fn eq(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y;
    }
};

const Direction = enum { up, down, left, right };

const FoodKind = enum { normal, fast, slow };

const BonusFood = struct {
    pos: Point,
    kind: FoodKind,
};

const SnakeNode = struct {
    node: std.DoublyLinkedList.Node = .{},
    pos: Point,

    fn fromNode(n: *std.DoublyLinkedList.Node) *SnakeNode {
        return @fieldParentPtr("node", n);
    }
};

const BodyList = std.DoublyLinkedList;

const Theme = enum {
    neon_green,
    fire,
    cyberpunk,

    pub fn getRgb(self: Theme, i: usize, len: usize) [3]u8 {
        const ratio: f32 = if (len <= 1) 0.0 else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(len - 1));
        return switch (self) {
            .neon_green => .{ 0, @as(u8, @intFromFloat(255.0 - (200.0 * ratio))), 50 },
            .fire => .{ 255, @as(u8, @intFromFloat(255.0 * (1.0 - ratio))), 0 },
            .cyberpunk => .{ @as(u8, @intFromFloat(255.0 * (1.0 - ratio))), @as(u8, @intFromFloat(255.0 * ratio)), 255 },
        };
    }
};

const Pixel = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    empty: bool = true,
};

fn getTermSize() struct { cols: u32, rows: u32 } {
    const linux = std.os.linux;
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0 and ws.row > 0)
        return .{ .cols = ws.col, .rows = ws.row };
    return .{ .cols = 80, .rows = 24 };
}

fn egyptSide(i: u32) []const u8 {
    return switch (i % 6) {
        0 => "|\xc3\xb8|",
        1 => "|^|",
        2 => "|~|",
        3 => "|\xc3\xb8|",
        4 => "|+|",
        5 => "|*|",
        else => "|||",
    };
}

fn egyptTop(i: u32) []const u8 {
    return switch (i % 8) {
        0, 4 => "*",
        2, 6 => "^",
        else => "-",
    };
}

const Spark = struct {
    pos: Point,
    life: u8, // ticks remaining, 0 = dead
};

const Game = struct {
    width: i32,
    height: i32,
    snake: BodyList,
    snake_len: usize = 0,
    dir: Direction,
    food: Point,
    score: u32 = 0,
    theme: Theme = .neon_green,
    grid: []Pixel,
    sparks: [4]Spark = [_]Spark{.{ .pos = .{ .x = 0, .y = 0 }, .life = 0 }} ** 4,
    flash_frames: u8 = 0,
    bonus_food: ?BonusFood = null,
    buff_ticks: u32 = 0,
    speed_buff: i32 = 0, // ms delta: negative = faster, positive = slower
    walls: std.ArrayListUnmanaged(Point) = .{},
    level: u32 = 1,
    rng: std.Random,
    allocator: std.mem.Allocator,
    is_running: bool = true,

    pub fn init(allocator: std.mem.Allocator, w: i32, h: i32, random: std.Random) !Game {
        const grid = try allocator.alloc(Pixel, @as(usize, @intCast(w * h)));
        var self = Game{
            .width = w,
            .height = h,
            .snake = BodyList{},
            .dir = .right,
            .food = undefined,
            .grid = grid,
            .walls = .{},
            .rng = random,
            .allocator = allocator,
        };

        try self.addSegment(.{ .x = @divTrunc(w, 2), .y = @divTrunc(h, 2) });
        try self.addSegment(.{ .x = @divTrunc(w, 2) - 1, .y = @divTrunc(h, 2) });
        try self.addSegment(.{ .x = @divTrunc(w, 2) - 2, .y = @divTrunc(h, 2) });

        self.spawnFood();
        return self;
    }

    fn addSegment(self: *Game, pos: Point) !void {
        const sn = try self.allocator.create(SnakeNode);
        sn.* = .{ .pos = pos };
        self.snake.append(&sn.node);
        self.snake_len += 1;
    }

    fn spawnFood(self: *Game) void {
        while (true) {
            const new_food = Point{
                .x = self.rng.intRangeLessThan(i32, 0, self.width),
                .y = self.rng.intRangeLessThan(i32, 0, self.height),
            };

            var curr = self.snake.first;
            var conflict = false;
            while (curr) |n| : (curr = n.next) {
                if (SnakeNode.fromNode(n).pos.eq(new_food)) {
                    conflict = true;
                    break;
                }
            }
            if (!conflict) {
                self.food = new_food;
                break;
            }
        }
    }

    fn spawnSparks(self: *Game, origin: Point) void {
        const offsets = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (&self.sparks, offsets) |*spark, off| {
            const sx = origin.x + off[0];
            const sy = origin.y + off[1];
            if (sx >= 0 and sx < self.width and sy >= 0 and sy < self.height) {
                spark.* = .{ .pos = .{ .x = sx, .y = sy }, .life = 2 };
            }
        }
    }

    fn spawnBonusFood(self: *Game) void {
        if (self.rng.intRangeLessThan(u8, 0, 2) == 0) return;
        const kind: FoodKind = if (self.rng.intRangeLessThan(u8, 0, 2) == 0) .fast else .slow;
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            const p = Point{
                .x = self.rng.intRangeLessThan(i32, 0, self.width),
                .y = self.rng.intRangeLessThan(i32, 0, self.height),
            };
            if (p.eq(self.food)) continue;
            if (self.isWall(p)) continue;
            var on_snake = false;
            var curr = self.snake.first;
            while (curr) |n| : (curr = n.next) {
                if (SnakeNode.fromNode(n).pos.eq(p)) {
                    on_snake = true;
                    break;
                }
            }
            if (!on_snake) {
                self.bonus_food = .{ .pos = p, .kind = kind };
                return;
            }
        }
    }

    fn spawnWalls(self: *Game) !void {
        const segments = 2;
        var s: u32 = 0;
        while (s < segments) : (s += 1) {
            var attempts: u32 = 0;
            while (attempts < 100) : (attempts += 1) {
                const start = Point{
                    .x = self.rng.intRangeLessThan(i32, 2, self.width - 2),
                    .y = self.rng.intRangeLessThan(i32, 2, self.height - 2),
                };
                const cx = @divTrunc(self.width, 2);
                const cy = @divTrunc(self.height, 2);
                if (@abs(start.x - cx) < 5 and @abs(start.y - cy) < 3) continue;
                if (self.isWall(start)) continue;

                const horizontal = self.rng.intRangeLessThan(u8, 0, 2) == 0;
                const length = self.rng.intRangeLessThan(i32, 3, 5);
                var j: i32 = 0;
                while (j < length) : (j += 1) {
                    const wp = Point{
                        .x = if (horizontal) start.x + j else start.x,
                        .y = if (horizontal) start.y else start.y + j,
                    };
                    if (wp.x < 0 or wp.x >= self.width or wp.y < 0 or wp.y >= self.height) break;
                    try self.walls.append(self.allocator, wp);
                }
                break;
            }
        }
    }

    fn isWall(self: *const Game, p: Point) bool {
        for (self.walls.items) |wp| {
            if (wp.eq(p)) return true;
        }
        return false;
    }

    pub fn update(self: *Game) !bool {
        const head_pos = SnakeNode.fromNode(self.snake.first.?).pos;
        var next_pos = head_pos;

        switch (self.dir) {
            .up => next_pos.y -= 1,
            .down => next_pos.y += 1,
            .left => next_pos.x -= 1,
            .right => next_pos.x += 1,
        }

        if (next_pos.x < 0 or next_pos.x >= self.width or next_pos.y < 0 or next_pos.y >= self.height) {
            self.is_running = false;
            return false;
        }

        if (self.isWall(next_pos)) {
            self.is_running = false;
            return false;
        }

        var curr = self.snake.first;
        while (curr) |n| : (curr = n.next) {
            if (SnakeNode.fromNode(n).pos.eq(next_pos)) {
                self.is_running = false;
                return false;
            }
        }

        const sn = try self.allocator.create(SnakeNode);
        sn.* = .{ .pos = next_pos };
        self.snake.prepend(&sn.node);

        if (self.buff_ticks > 0) {
            self.buff_ticks -= 1;
            if (self.buff_ticks == 0) self.speed_buff = 0;
        }

        for (&self.sparks) |*spark| {
            if (spark.life > 0) spark.life -= 1;
        }

        if (self.bonus_food) |bf| {
            if (next_pos.eq(bf.pos)) {
                self.bonus_food = null;
                self.score += 5;
                self.snake_len += 1;
                self.buff_ticks = 28;
                self.speed_buff = if (bf.kind == .fast) -30 else 40;
                self.spawnSparks(next_pos);
                return true;
            }
        }

        if (next_pos.eq(self.food)) {
            self.score += 10;
            self.snake_len += 1;
            self.spawnSparks(next_pos);

            const milestones = [_]u32{ 50, 100, 200, 350, 500, 700, 1000 };
            for (milestones) |m| {
                if (self.score == m) {
                    self.flash_frames = 3;
                    break;
                }
            }

            const new_level = (self.score / 50) + 1;
            if (new_level > self.level) {
                self.level = new_level;
                try self.spawnWalls();
                self.flash_frames = 5;
            }

            self.spawnBonusFood();
            self.spawnFood();
            return true;
        } else {
            if (self.snake.pop()) |tail_node| {
                self.allocator.destroy(SnakeNode.fromNode(tail_node));
            }
            return false;
        }
    }

    pub fn render(self: *Game, w: anytype) !void {
        const ts = getTermSize();
        const gw: u32 = @intCast(self.width);
        const gh: u32 = @intCast(self.height);
        const term_rows = gh / 2;
        const box_w = gw + 6;
        const box_h = term_rows + 6;
        const col_off = if (ts.cols > box_w) (ts.cols - box_w) / 2 else 0;
        const row_off = if (ts.rows > box_h) (ts.rows - box_h) / 2 else 0;

        try w.print("\x1b[{d};{d}H\x1b[2K", .{ row_off + 1, col_off + 1 });
        if (self.flash_frames > 0) {
            try w.print("\x1b[7m Scr:{d:>4}  Lvl:{d}  \x1b[0m", .{ self.score, self.level });
            self.flash_frames -= 1;
        } else {
            try w.print("\x1b[38;2;255;215;0mScr:\x1b[1m{d:>4}\x1b[0m  \x1b[38;2;180;180;255mLvl:{d}\x1b[0m", .{ self.score, self.level });
            if (self.buff_ticks > 0) {
                if (self.speed_buff < 0) {
                    try w.print("  \x1b[38;2;255;80;80mFAST!({d})\x1b[0m", .{self.buff_ticks});
                } else {
                    try w.print("  \x1b[38;2;80;130;255mSLOW!({d})\x1b[0m", .{self.buff_ticks});
                }
            }
        }

        @memset(self.grid, .{});

        for (0..gw) |gx| {
            const shade: u8 = if (gx % 3 == 0) @as(u8, 100) else if (gx % 3 == 1) @as(u8, 120) else @as(u8, 80);
            const g1 = (@as(u32, @intCast(self.height)) - 2) * gw + @as(u32, @intCast(gx));
            const g2 = (@as(u32, @intCast(self.height)) - 1) * gw + @as(u32, @intCast(gx));
            self.grid[g1] = .{ .r = 20, .g = shade, .b = 20, .empty = false };
            self.grid[g2] = .{ .r = 10, .g = @intCast(@as(u32, shade) * 6 / 10), .b = 10, .empty = false };
        }

        self.grid[@intCast(self.food.y * self.width + self.food.x)] = .{ .r = 255, .g = 50, .b = 180, .empty = false };

        for (self.walls.items) |wp| {
            self.grid[@intCast(wp.y * self.width + wp.x)] = .{ .r = 190, .g = 160, .b = 90, .empty = false };
        }

        if (self.bonus_food) |bf| {
            const idx: usize = @intCast(bf.pos.y * self.width + bf.pos.x);
            self.grid[idx] = if (bf.kind == .fast)
                .{ .r = 255, .g = 60, .b = 60, .empty = false }
            else
                .{ .r = 60, .g = 100, .b = 255, .empty = false };
        }

        for (self.sparks) |spark| {
            if (spark.life == 0) continue;
            const idx: usize = @intCast(spark.pos.y * self.width + spark.pos.x);
            const bright: u8 = if (spark.life == 2) 255 else 140;
            self.grid[idx] = .{ .r = bright, .g = @intCast(@as(u32, bright) * 3 / 4), .b = 0, .empty = false };
        }

        var curr = self.snake.first;
        var si: usize = 0;
        while (curr) |sn_node| : (curr = sn_node.next) {
            const sn = SnakeNode.fromNode(sn_node);
            const c = self.theme.getRgb(si, self.snake_len);
            self.grid[@intCast(sn.pos.y * self.width + sn.pos.x)] = .{ .r = c[0], .g = c[1], .b = c[2], .empty = false };
            si += 1;
        }

        try w.print("\x1b[{d};{d}H\x1b[38;2;218;165;32m*=", .{ row_off + 2, col_off + 1 });
        var ti: u32 = 0;
        while (ti < gw) : (ti += 1) try w.writeAll(egyptTop(ti));
        try w.writeAll("=*\x1b[0m");

        try w.print("\x1b[{d};{d}H\x1b[38;2;218;165;32m||\x1b[38;2;120;90;40m\x1b[49m", .{ row_off + 3, col_off + 1 });
        ti = 0;
        while (ti < gw) : (ti += 1) try w.writeAll("\xe2\x96\x84"); // ▄
        try w.print("\x1b[0m\x1b[38;2;218;165;32m||\x1b[0m", .{});

        var row: u32 = 0;
        while (row < term_rows) : (row += 1) {
            const top_y = row * 2;
            const bot_y = row * 2 + 1;
            try w.print("\x1b[{d};{d}H\x1b[38;2;218;165;32m{s}\x1b[0m", .{ row_off + 4 + row, col_off + 1, egyptSide(row) });

            for (0..gw) |x| {
                const top = self.grid[top_y * gw + x];
                const bot = self.grid[bot_y * gw + x];
                try w.print(
                    "\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m\xe2\x96\x80\x1b[0m",
                    .{ top.r, top.g, top.b, bot.r, bot.g, bot.b },
                );
            }
            try w.print("\x1b[38;2;218;165;32m{s}\x1b[0m", .{egyptSide(row + 1)});
        }

        try w.print("\x1b[{d};{d}H\x1b[38;2;218;165;32m||\x1b[38;2;120;90;40m", .{ row_off + 4 + term_rows, col_off + 1 });
        ti = 0;
        while (ti < gw) : (ti += 1) try w.writeAll("\xe2\x96\x80"); // ▀
        try w.print("\x1b[0m\x1b[38;2;218;165;32m||\x1b[0m", .{});

        try w.print("\x1b[{d};{d}H\x1b[38;2;218;165;32m*=", .{ row_off + 5 + term_rows, col_off + 1 });
        ti = 0;
        while (ti < gw) : (ti += 1) try w.writeAll(egyptTop(ti + 4));
        try w.writeAll("=*\x1b[0m");

        // controls
        try w.print("\x1b[{d};{d}H\x1b[38;2;100;100;100mWASD:move  Q:quit\x1b[0m", .{ row_off + 7 + term_rows, col_off + 4 });
    }

    pub fn deinit(self: *Game) void {
        while (self.snake.popFirst()) |n| {
            self.allocator.destroy(SnakeNode.fromNode(n));
        }
        self.walls.deinit(self.allocator);
        self.allocator.free(self.grid);
    }
};

const Term = struct {
    orig: posix.termios,

    pub fn init() !Term {
        const fd = posix.STDIN_FILENO;
        const orig = try posix.tcgetattr(fd);
        var raw = orig;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;

        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, posix.TCSA.FLUSH, raw);
        _ = try posix.write(posix.STDOUT_FILENO, "\x1b[?1049h\x1b[?25l");
        return .{ .orig = orig };
    }

    pub fn deinit(self: Term) void {
        posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, self.orig) catch {};
        _ = posix.write(posix.STDOUT_FILENO, "\x1b[?1049l\x1b[?25h") catch {};
    }
};

fn screenShake(w: anytype) !void {
    const offsets = [_][2]i32{ .{ 2, 1 }, .{ -1, 2 }, .{ 1, -1 }, .{ -2, 1 }, .{ 0, 0 } };
    for (offsets) |off| {
        try w.print("\x1b[2J\x1b[{d};{d}H", .{ 2 + off[1], 1 + off[0] });
        try w.flush();
        std.Thread.sleep(60 * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    detectAudioPlayer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(std.time.milliTimestamp())));

    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    var bw_buf: [131072]u8 = undefined;

    var bw_impl = stdout_file.writer(&bw_buf);
    const bw = &bw_impl.interface;
    const w = bw;

    const term = try Term.init();
    defer term.deinit();

    var selected_theme: Theme = .neon_green;

    while (true) {
        try w.print("\x1b[2J\x1b[H", .{});
        try w.print("Select Snake Pattern:\n\n", .{});
        try w.print("1. \x1b[38;2;0;255;50mNeon Green\x1b[0m\n", .{});
        try w.print("2. \x1b[38;2;255;128;0mFire\x1b[0m\n", .{});
        try w.print("3. \x1b[38;2;255;0;255mCyberpunk\x1b[0m\n\n", .{});
        try w.print("Press 1, 2, or 3 to start (or q to quit)...\n", .{});
        try bw.flush();

        var buf: [1]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n > 0) {
            if (buf[0] == '1') {
                selected_theme = .neon_green;
                break;
            }
            if (buf[0] == '2') {
                selected_theme = .fire;
                break;
            }
            if (buf[0] == '3') {
                selected_theme = .cyberpunk;
                break;
            }
            if (buf[0] == 'q') return;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    var game = try Game.init(allocator, 40, 20, prng.random());
    defer game.deinit();
    game.theme = selected_theme;

    while (game.is_running) {
        var buf: [1]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n > 0) {
            switch (buf[0]) {
                'q' => break,
                'w' => if (game.dir != .down) {
                    game.dir = .up;
                },
                's' => if (game.dir != .up) {
                    game.dir = .down;
                },
                'a' => if (game.dir != .right) {
                    game.dir = .left;
                },
                'd' => if (game.dir != .left) {
                    game.dir = .right;
                },
                else => {},
            }
        }

        const ate_food = try game.update();
        if (ate_food) playBeep();
        try game.render(w);
        try w.flush();

        const base: i64 = 180 - @as(i64, @intCast(@min(game.score, 120)));
        const sleep_ms = @as(u64, @intCast(@max(30, base + game.speed_buff)));
        std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
    }

    try screenShake(w);
    try w.print("\x1b[2J\x1b[HGAME OVER! Final Score: {d}\n", .{game.score});
    try w.flush();
    std.Thread.sleep(2 * std.time.ns_per_s);
}
