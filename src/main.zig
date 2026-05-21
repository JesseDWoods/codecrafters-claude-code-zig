const std = @import("std");

const MAX_MESSAGES = 10;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "-p")) {
        @panic("Usage: main -p <prompt>");
    }
    const prompt_str = args[2];

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse @panic("OPENROUTER_API_KEY is not set");
    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse "https://openrouter.ai/api/v1";

    //Store messages as raw JSON to avoid unnecessary parsing and serialization
    var message_count: usize = 0;
    var messages:[MAX_MESSAGES][]const u8 = undefined;
    defer {
        for(0..message_count) |i| {
            allocator.free(messages[i]);
        }
    }
    // Add user prompt as raw JSON
    {
        var user_message_out: std.io.Writer.Allocating = .init(allocator);
        defer user_message_out.deinit();
        var jw: std.json.Stringify = .{ .writer = &user_message_out.writer };
        try jw.write(.{
            .role = "user",
            .content = prompt_str,
        });
        const written = user_message_out.written();
        messages[message_count] = try allocator.dupe(u8, written);
        message_count += 1;
    }
    //Define tools as raw JSON
    const tools = &[_]struct { type: []const u8, function: struct { name: []const u8,
                                                                   description: []const u8, parameters: struct {
                                                                       required: []const []const u8, type: []const u8, properties: struct {
                                                                           file_path: struct {
                                                                                 type: []const u8,
                                                                                 description: []const u8,
    }}}}}{
        .{
            .type = "function",
            .function = .{
                .name = "Read",
                .description = "Read the contents of a file given its path",
                .parameters = .{
                    .required = &[_][]const u8{ "file_path" },
                    .type = "object",
                    .properties = .{
                        .file_path = .{
                            .type = "string",
                            .description = "The path to the file to read, relative to the current working directory",
                        },

                    },
                },
            },
        },
    };

    while(true) {
        //Build request body with all messages
        var body_out: std.io.Writer.Allocating = .init(allocator);
        defer body_out.deinit();
        try body_out.writer.writeAll("{\"model\":\"anthropic/claude-haiku-4.5\",\"messages\":[");
        for (0..message_count) |i| {
            if (i > 0) try body_out.writer.writeAll(",");
            try body_out.writer.writeAll(messages[i]);
        }
        try body_out.writer.writeAll("],\"tools\":");
        var tools_jw: std.json.Stringify = .{ .writer = &body_out.writer };
        try tools_jw.write(tools);
        try body_out.writer.writeAll("]}");
        const body = body_out.written();

        //Build url and headers
        //Note: OpenRouter expects the API key in the Authorization header as "Authorization:
        const url_string = try std.fmt.allocPrint(allocator, "{s}/chat/completions",.{ base_url });
        defer allocator.free(url_string);

        const authorization_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{ api_key });
        defer allocator.free(authorization_value);

        //Make HTTP request
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var response_out: std.io.Writer.Allocating = .init(allocator);
        defer response_out.deinit();

        _ = try client.fetch( .{
            .location = .{ .url = url_string },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = authorization_value },
            },
            .response_writer = &response_out.writer,
        });
        const response_body = response_out.written();

        //Parse response to extract assistant message and tool calls
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
        defer parsed.deinit();

        const choices = parsed.value.object.get("choices") orelse @panic("Response missing 'choices'");
        if (choices.array.items.len == 0) {
            @panic("Response 'choices' array is empty");
        }
        const choice = choices.array.items[0];
        const message_object = choice.object.get("message").?.object;

        if(message_object.get("tool_calls")) |tool_calls_value| {

            //Append assistant message
            var assistant_out: std.io.Writer.Allocating = .init(allocator);
            defer assistant_out.deinit();
            var ajw: std.json.Stringify = .{ .writer = &assistant_out.writer };
            try ajw.write(.{
                .role = "assistant",
                .content = @as(?[]const u8, null),
                .tool_calls = tool_calls_value,
            });
            const assistant_message  = assistant_out.written();
            messages[message_count] = try allocator.dupe(u8, assistant_message);
            message_count += 1;

            //Handle tool calls
            const tool_calls = tool_calls_value.array.items;
            for (tool_calls) |tool_call_value| {
                const tool_call_object = tool_call_value.object;
                const tool_call_id = tool_call_object.get("id").?.string;
                const function_object = tool_call_object.get("function").?.object;
                const function_name = function_object.get("name").?.string;
                const arguments_string = function_object.get("arguments").?.string;

                //execute the tool
                var result: []const u8 = undefined;
                if (std.mem.eql(u8, function_name, "Read")) {
                    const arguments_parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_string, .{});
                    defer arguments_parsed.deinit();
                    const file_path = arguments_parsed.value.object.get("file_path").?.string;
                    result = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
                    defer allocator.free(result);

                    //append tool result
                    var tool_out: std.io.Writer.Allocating = .init(allocator);
                    defer tool_out.deinit();
                    var tjw: std.json.Stringify = .{ .writer = &tool_out.writer };
                    try tjw.write(.{
                        .role = "tool",
                        .tool_call_id = tool_call_id,
                        .content = result,
                    });
                    const tool_message = tool_out.written();
                    messages[message_count] = try allocator.dupe(u8, tool_message);
                    message_count += 1;
                }
            }
        } else {
            //No tool calls, just append assistant message
            const content = message_object.get("content").?.string;
            try std.fs.File.stdout().writeAll(content);
            break;
        }
    }
}
