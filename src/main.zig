const std = @import("std");
const json = std.json;

const zzz = @import("zzz");
const http = zzz.HTTP;
const template = zzz.template;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const FsDir = http.FsDir;
const Form = http.Form;

const Compression = http.Middlewares.Compression;

const todo_json_file: []const u8 = "todo.json";

const TodoList = struct {
    id: usize = 0,
    todo: []const u8,
    status: bool = false,
    
    fn init(id: usize, todo: []const u8, status: bool) TodoList {
		return TodoList {
			.id = id,
			.todo = todo,
			.status = status
		};
	}
};

fn base_handler(ctx: *const Context, _: void) !Respond {
    const body = try read_json(ctx.io, ctx.allocator, todo_json_file);

    return try ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

fn td(ctx: *const Context, _: void) !Respond {
    var res: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &res.writer;
    
    const html = comptime template.include(
        @embedFile("static/todo.html"),
        "content",
        @embedFile("static/content.html"),
    );

    const todo_list = try read_json(ctx.io, ctx.allocator, todo_json_file);
    const parsed_todo = try json.parseFromSlice([]TodoList, ctx.allocator, todo_list, .{});
    defer parsed_todo.deinit();

    try template.print(writer, html, .{ .title = "Todo List", .todos = parsed_todo.value });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = res.written(),
    });
}

fn add_task(ctx: *const Context, _: void) !Respond {
    const info = switch (ctx.request.method.?) {
        .POST => try Form(TodoList).parse(ctx.allocator, ctx),
        else => return error.UnexpectedMethod,
    };
    
    const todo_list = try read_json(ctx.io, ctx.allocator, todo_json_file);
    try write_json(todo_json_file, ctx.allocator, todo_list, info);

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.TEXT,
//        .body = res.written(),
        .body = "Success",
    });
}

fn read_json(gg: std.Io, allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
	const buf = try allocator.alloc(u8, 4096);
	const content: []u8 = try std.Io.Dir.cwd().readFile(gg, file_path, buf);
	return content;
}

fn write_json(file_path: []const u8, allocator: std.mem.Allocator, json_content: []u8, form_data: TodoList) !void {

    var list = std.array_list.Managed(TodoList).init(allocator);
    defer list.deinit();

    const parsed = try json.parseFromSlice([]TodoList, allocator, json_content, .{});
    defer parsed.deinit();

    const parsed_value = parsed.value;
    try list.appendSlice(parsed_value);

    const element_id: usize = parsed_value.len;
    const append_ele = TodoList.init(element_id + 1, form_data.todo, form_data.status);
    try list.append(append_ele);
    
    const new_js = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer new_js.close();

    const render = try json.Stringify.valueAlloc(allocator, list.items, .{});
    defer allocator.free(render);

    var write_buffer: [1024]u8 = undefined;
    var wtr = new_js.writer(&write_buffer);

    const writer_interface: *std.Io.Writer = &wtr.interface;
    try writer_interface.writeAll(render);
    try writer_interface.flush();
}

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

var server: Server = undefined;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var threaded: std.Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    const static_dir = try std.Io.Dir.cwd().openDir(io, "src/static", .{});

    var router = try Router.init(allocator, &.{
        Compression(.{ .gzip = .default }),
        Route.init("/").get({}, base_handler).layer(),
        Route.init("/todo").get({}, td).layer(),
        Route.init("/add").post({}, add_task).layer(),
        FsDir.serve("/", &static_dir),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(io, .{ .reuse_address = true });
    defer s.deinit(io);

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 4,
    });
    defer server.deinit();
    try server.serve(io, &router, &s);
}
