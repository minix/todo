const std = @import("std");
const json = std.json;
const posix = std.posix;
const Io = std.Io;
const log = std.log;

const zzz = @import("zzz");
const http = zzz.HTTP;
const template = zzz.template;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const FsDir = http.FsDir;
const Form = http.Form;

const Compression = http.Middlewares.Compression;

const todo_json_file: []const u8 = "todo.json";
const init_str: []const u8 = 
\\ [{"id": 1, "todo": "开始你的todo之旅", "status": true, "startts:": "1764724381", "endts": 1764724381}]
;

const TodoList = struct {
    id: usize = 0,
    todo: []const u8,
    status: bool = false,
    
    fn init(id: usize, todo: []const u8, status: bool) TodoList {
		return TodoList {
			.id = id,
			.todo = todo,
			.status = status,
		};
	}
};

fn base_handler(ctx: *const Context, _: void) !Respond {
    var todo_list = try read_json(ctx.io, ctx.allocator, todo_json_file);
    
    if (todo_list.len == 0) {
        _ = try write_init(todo_json_file, init_str);
        todo_list = try read_json(ctx.io, ctx.allocator, todo_json_file);
    }

    const parsed = try json.parseFromSlice([]TodoList, ctx.allocator, todo_list,  .{});

    defer parsed.deinit();
    
    const render = try json.Stringify.valueAlloc(ctx.allocator, parsed.value, .{});
    defer ctx.allocator.free(render);
    return try ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        //.body = body[0..],
        .body = render,
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
    if (todo_list.len == 0) try write_init(todo_json_file, init_str);
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
    if (todo_list.len == 0) try write_init(todo_json_file, init_str);
    
    var list = std.array_list.Managed(TodoList).init(ctx.allocator);
    defer list.deinit();

    const parsed = try json.parseFromSlice([]TodoList, ctx.allocator, todo_list, .{});
    defer parsed.deinit();

    const parsed_value = parsed.value;
    try list.appendSlice(parsed_value);

    const element_id: usize = parsed_value.len;
    const append_ele = TodoList.init(element_id + 1, info.todo, info.status);
    try list.append(append_ele);
    
    const render = try json.Stringify.valueAlloc(ctx.allocator, list.items, .{});
    
    try write_init(todo_json_file, render);
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
//        .body = res.written(),
        .body = render,
    });
}

fn change_task_status(ctx: *const Context, _: void) !Respond {
    const info = switch (ctx.request.method.?) {
        .POST => try Form(TodoList).parse(ctx.allocator, ctx),
        else => return error.UnexpectedMethod,
    };
    
    const todo_list = try read_json(ctx.io, ctx.allocator, todo_json_file);
    if (todo_list.len == 0) try write_init(todo_json_file, todo_list);
    
    var list = std.array_list.Managed(TodoList).init(ctx.allocator);
    defer list.deinit();
    
    const parsed = try json.parseFromSlice([]TodoList, ctx.allocator, todo_list, .{});
    defer parsed.deinit();
    try list.appendSlice(parsed.value);
	
    const list_items = list.items;
    
    for (list_items, 0..) |item, i| {
        if (item.id == info.id) {
            const completed_task: TodoList = .{
    		    .id = item.id,
    		    .status = true,
    		    .todo = item.todo,
    	    };
    	    _ = list.orderedRemove(i);
    	    try list.append(completed_task);
    	} else {
    	    return ctx.response.apply(.{
    	        .status = .Forbidden,
    	        .mime = http.Mime.JSON,
    	        .body = "Not found the task. "
    	    });
    	}
    }

    const render = try json.Stringify.valueAlloc(ctx.allocator, list_items, .{});
    defer ctx.allocator.free(render);
    try write_init(todo_json_file, render);
	
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
//            .body = res.written(),
        .body = render,
    });
}

fn read_json(gg: std.Io, allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, 4096);
    if (std.fs.cwd().statFile(file_path)) |stat| {
        if (stat.size == 0) {
            try write_init(todo_json_file, init_str);
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            try write_init(todo_json_file, init_str);
        },
    else => return err
    }
    
    const content: []u8 = try std.Io.Dir.cwd().readFile(gg, file_path, buf);
    return content;
}

fn write_init(file_path: []const u8, str: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{ }); 
    defer file.close();
    var write_buffer: [1024]u8 = undefined;
    var wtr = file.writer(&write_buffer);
    const write_interface: *std.Io.Writer = &wtr.interface;
    try write_interface.writeAll(str);
    _ = try write_interface.flush();
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
        Route.init("/change").post({}, change_task_status).layer(),
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
