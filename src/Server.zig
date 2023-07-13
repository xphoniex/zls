const Server = @This();

const std = @import("std");
const zig_builtin = @import("builtin");
const build_options = @import("build_options");
const Config = @import("Config.zig");
const configuration = @import("configuration.zig");
const DocumentStore = @import("DocumentStore.zig");
const types = @import("lsp.zig");
const Analyser = @import("analysis.zig");
const ast = @import("ast.zig");
const offsets = @import("offsets.zig");
const shared = @import("shared.zig");
const Ast = std.zig.Ast;
const tracy = @import("tracy.zig");
const diff = @import("diff.zig");
const ComptimeInterpreter = @import("ComptimeInterpreter.zig");
const InternPool = @import("analyser/analyser.zig").InternPool;
const ZigVersionWrapper = @import("ZigVersionWrapper.zig");

const signature_help = @import("features/signature_help.zig");
const references = @import("features/references.zig");
const semantic_tokens = @import("features/semantic_tokens.zig");
const inlay_hints = @import("features/inlay_hints.zig");
const code_actions = @import("features/code_actions.zig");
const folding_range = @import("features/folding_range.zig");
const document_symbol = @import("features/document_symbol.zig");
const completions = @import("features/completions.zig");
const goto = @import("features/goto.zig");
const hover_handler = @import("features/hover.zig");
const selection_range = @import("features/selection_range.zig");
const diagnostics_gen = @import("features/diagnostics.zig");

const log = std.log.scoped(.zls_server);

// Server fields

config: *Config,
allocator: std.mem.Allocator,
document_store: DocumentStore,
ip: InternPool = .{},
client_capabilities: ClientCapabilities = .{},
runtime_zig_version: ?ZigVersionWrapper,
outgoing_messages: std.ArrayListUnmanaged([]const u8) = .{},
recording_enabled: bool,
replay_enabled: bool,
message_tracing_enabled: bool = false,
offset_encoding: offsets.Encoding = .@"utf-16",
status: enum {
    /// the server has not received a `initialize` request
    uninitialized,
    /// the server has received a `initialize` request and is awaiting the `initialized` notification
    initializing,
    /// the server has been initialized and is ready to received requests
    initialized,
    /// the server has been shutdown and can't handle any more requests
    shutdown,
    /// the server is received a `exit` notification and has been shutdown
    exiting_success,
    /// the server is received a `exit` notification but has not been shutdown
    exiting_failure,
},

// Code was based off of https://github.com/andersfr/zig-lsp/blob/master/server.zig

const ClientCapabilities = packed struct {
    supports_snippets: bool = false,
    supports_apply_edits: bool = false,
    supports_will_save: bool = false,
    supports_will_save_wait_until: bool = false,
    supports_publish_diagnostics: bool = false,
    supports_code_action_fixall: bool = false,
    hover_supports_md: bool = false,
    completion_doc_supports_md: bool = false,
    label_details_support: bool = false,
    supports_configuration: bool = false,
    supports_workspace_did_change_configuration_dynamic_registration: bool = false,
};

pub const Error = std.mem.Allocator.Error || error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    /// Error code indicating that a server received a notification or
    /// request before the server has received the `initialize` request.
    ServerNotInitialized,
    /// A request failed but it was syntactically correct, e.g the
    /// method name was known and the parameters were valid. The error
    /// message should contain human readable information about why
    /// the request failed.
    ///
    /// @since 3.17.0
    RequestFailed,
    /// The server cancelled the request. This error code should
    /// only be used for requests that explicitly support being
    /// server cancellable.
    ///
    /// @since 3.17.0
    ServerCancelled,
    /// The server detected that the content of a document got
    /// modified outside normal conditions. A server should
    /// NOT send this error code if it detects a content change
    /// in it unprocessed messages. The result even computed
    /// on an older state might still be useful for the client.
    ///
    /// If a client decides that a result is not of any use anymore
    /// the client should cancel the request.
    ContentModified,
    /// The client has canceled a request and a server as detected
    /// the cancel.
    RequestCancelled,
};

fn sendResponse(server: *Server, id: types.RequestId, result: anytype) void {
    // TODO validate result type is a possible response
    // TODO validate response is from a client to server request
    // TODO validate result type

    server.sendInternal(id, null, null, "result", result) catch {};
}

fn sendRequest(server: *Server, id: types.RequestId, method: []const u8, params: anytype) void {
    // TODO validate method is a request
    // TODO validate method is server to client
    // TODO validate params type

    server.sendInternal(id, method, null, "params", params) catch {};
}

fn sendNotification(server: *Server, method: []const u8, params: anytype) void {
    // TODO validate method is a notification
    // TODO validate method is server to client
    // TODO validate params type

    server.sendInternal(null, method, null, "params", params) catch {};
}

fn sendResponseError(server: *Server, id: types.RequestId, err: ?types.ResponseError) void {
    server.sendInternal(id, null, err, "", {}) catch {};
}

fn sendInternal(
    server: *Server,
    maybe_id: ?types.RequestId,
    maybe_method: ?[]const u8,
    maybe_err: ?types.ResponseError,
    extra_name: []const u8,
    extra: anytype,
) error{OutOfMemory}!void {
    var buffer = std.ArrayListUnmanaged(u8){};
    var writer = buffer.writer(server.allocator);
    try writer.writeAll(
        \\{"jsonrpc":"2.0"
    );
    if (maybe_id) |id| {
        try writer.writeAll(
            \\,"id":
        );
        try std.json.stringify(id, .{}, writer);
    }
    if (maybe_method) |method| {
        try writer.writeAll(
            \\,"method":
        );
        try std.json.stringify(method, .{}, writer);
    }
    switch (@TypeOf(extra)) {
        void => {},
        ?void => {
            try writer.print(
                \\,"{s}":null
            , .{extra_name});
        },
        else => {
            try writer.print(
                \\,"{s}":
            , .{extra_name});
            try std.json.stringify(extra, .{ .emit_null_optional_fields = false }, writer);
        },
    }
    if (maybe_err) |err| {
        try writer.writeAll(
            \\,"error":
        );
        try std.json.stringify(err, .{}, writer);
    }
    try writer.writeByte('}');

    const message = try buffer.toOwnedSlice(server.allocator);
    errdefer server.allocator.free(message);

    try server.outgoing_messages.append(server.allocator, message);
}

fn showMessage(
    server: *Server,
    message_type: types.MessageType,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(server.allocator, fmt, args) catch return;
    defer server.allocator.free(message);
    switch (message_type) {
        .Error => log.err("{s}", .{message}),
        .Warning => log.warn("{s}", .{message}),
        .Info => log.info("{s}", .{message}),
        .Log => log.debug("{s}", .{message}),
    }
    server.sendNotification("window/showMessage", types.ShowMessageParams{
        .type = message_type,
        .message = message,
    });
}

fn getAutofixMode(server: *Server) enum {
    on_save,
    will_save_wait_until,
    fixall,
    none,
} {
    if (!server.config.enable_autofix) return .none;
    // TODO https://github.com/zigtools/zls/issues/1093
    // if (server.client_capabilities.supports_code_action_fixall) return .fixall;
    if (server.client_capabilities.supports_apply_edits) {
        if (server.client_capabilities.supports_will_save_wait_until) return .will_save_wait_until;
        return .on_save;
    }
    return .none;
}

/// caller owns returned memory.
pub fn autofix(server: *Server, arena: std.mem.Allocator, handle: *const DocumentStore.Handle) error{OutOfMemory}!std.ArrayListUnmanaged(types.TextEdit) {
    if (!server.config.enable_ast_check_diagnostics) return .{};
    if (handle.tree.errors.len != 0) return .{};

    var diagnostics = std.ArrayListUnmanaged(types.Diagnostic){};
    try diagnostics_gen.getAstCheckDiagnostics(server, arena, handle.*, &diagnostics);
    if (diagnostics.items.len == 0) return .{};

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    var builder = code_actions.Builder{
        .arena = arena,
        .analyser = &analyser,
        .handle = handle,
        .offset_encoding = server.offset_encoding,
    };

    var actions = std.ArrayListUnmanaged(types.CodeAction){};
    var remove_capture_actions = std.AutoHashMapUnmanaged(types.Range, void){};
    for (diagnostics.items) |diagnostic| {
        try builder.generateCodeAction(diagnostic, &actions, &remove_capture_actions);
    }

    var text_edits = std.ArrayListUnmanaged(types.TextEdit){};
    for (actions.items) |action| {
        std.debug.assert(action.kind != null);
        std.debug.assert(action.edit != null);
        std.debug.assert(action.edit.?.changes != null);

        if (action.kind.? != .@"source.fixAll") continue;

        const changes = action.edit.?.changes.?.map;
        if (changes.count() != 1) continue;

        const edits: []const types.TextEdit = changes.get(handle.uri) orelse continue;

        try text_edits.appendSlice(arena, edits);
    }

    return text_edits;
}

fn initializeHandler(server: *Server, _: std.mem.Allocator, request: types.InitializeParams) Error!types.InitializeResult {
    var skip_set_fixall = false;

    if (request.clientInfo) |clientInfo| {
        log.info("client is '{s}-{s}'", .{ clientInfo.name, clientInfo.version orelse "<no version>" });

        if (std.mem.eql(u8, clientInfo.name, "Sublime Text LSP")) blk: {
            server.config.max_detail_length = 256;
            // TODO investigate why fixall doesn't work in sublime text
            server.client_capabilities.supports_code_action_fixall = false;
            skip_set_fixall = true;

            const version_str = clientInfo.version orelse break :blk;
            const version = std.SemanticVersion.parse(version_str) catch break :blk;
            // this indicates a LSP version for sublime text 3
            // this check can be made more precise if the version that fixed this issue is known
            if (version.major == 0) {
                server.config.include_at_in_builtins = true;
            }
        } else if (std.mem.eql(u8, clientInfo.name, "Visual Studio Code")) {
            server.client_capabilities.supports_code_action_fixall = true;
            skip_set_fixall = true;
        }
    }

    if (request.capabilities.general) |general| {
        var supports_utf8 = false;
        var supports_utf16 = false;
        var supports_utf32 = false;
        if (general.positionEncodings) |position_encodings| {
            for (position_encodings) |encoding| {
                switch (encoding) {
                    .@"utf-8" => supports_utf8 = true,
                    .@"utf-16" => supports_utf16 = true,
                    .@"utf-32" => supports_utf32 = true,
                }
            }
        }

        if (supports_utf8) {
            server.offset_encoding = .@"utf-8";
        } else if (supports_utf32) {
            server.offset_encoding = .@"utf-32";
        } else {
            server.offset_encoding = .@"utf-16";
        }
    }

    if (request.capabilities.textDocument) |textDocument| {
        server.client_capabilities.supports_publish_diagnostics = textDocument.publishDiagnostics != null;
        if (textDocument.hover) |hover| {
            if (hover.contentFormat) |content_format| {
                for (content_format) |format| {
                    if (format == .plaintext) {
                        break;
                    }
                    if (format == .markdown) {
                        server.client_capabilities.hover_supports_md = true;
                        break;
                    }
                }
            }
        }
        if (textDocument.completion) |completion| {
            if (completion.completionItem) |completionItem| {
                server.client_capabilities.label_details_support = completionItem.labelDetailsSupport orelse false;
                server.client_capabilities.supports_snippets = completionItem.snippetSupport orelse false;
                if (completionItem.documentationFormat) |documentation_format| {
                    for (documentation_format) |format| {
                        if (format == .plaintext) {
                            break;
                        }
                        if (format == .markdown) {
                            server.client_capabilities.completion_doc_supports_md = true;
                            break;
                        }
                    }
                }
            }
        }
        if (textDocument.synchronization) |synchronization| {
            server.client_capabilities.supports_will_save = synchronization.willSave orelse false;
            server.client_capabilities.supports_will_save_wait_until = synchronization.willSaveWaitUntil orelse false;
        }
        if (textDocument.codeAction) |codeaction| {
            if (codeaction.codeActionLiteralSupport) |literalSupport| {
                if (!skip_set_fixall) {
                    const fixall = std.mem.indexOfScalar(types.CodeActionKind, literalSupport.codeActionKind.valueSet, .@"source.fixAll") != null;
                    server.client_capabilities.supports_code_action_fixall = fixall;
                }
            }
        }
    }

    if (request.capabilities.workspace) |workspace| {
        server.client_capabilities.supports_apply_edits = workspace.applyEdit orelse false;
        server.client_capabilities.supports_configuration = workspace.configuration orelse false;
        if (workspace.didChangeConfiguration) |did_change| {
            if (did_change.dynamicRegistration orelse false) {
                server.client_capabilities.supports_workspace_did_change_configuration_dynamic_registration = true;
            }
        }
    }

    if (request.trace) |trace| {
        // To support --enable-message-tracing, only allow turning this on here
        if (trace != .off) {
            server.message_tracing_enabled = true;
        }
    }

    log.info("zls initializing", .{});
    log.info("{}", .{server.client_capabilities});
    log.info("Using offset encoding: {s}", .{@tagName(server.offset_encoding)});

    server.status = .initializing;

    if (server.runtime_zig_version) |zig_version_wrapper| {
        const zig_version = zig_version_wrapper.version;
        const zls_version = comptime std.SemanticVersion.parse(build_options.version) catch unreachable;

        const zig_version_simple = std.SemanticVersion{
            .major = zig_version.major,
            .minor = zig_version.minor,
            .patch = 0,
        };
        const zls_version_simple = std.SemanticVersion{
            .major = zls_version.major,
            .minor = zls_version.minor,
            .patch = 0,
        };

        switch (zig_version_simple.order(zls_version_simple)) {
            .lt => {
                server.showMessage(.Warning,
                    \\Zig `{}` is older than ZLS `{}`. Update Zig to avoid unexpected behavior.
                , .{ zig_version, zls_version });
            },
            .eq => {},
            .gt => {
                server.showMessage(.Warning,
                    \\Zig `{}` is newer than ZLS `{}`. Update ZLS to avoid unexpected behavior.
                , .{ zig_version, zls_version });
            },
        }
    }

    if (server.recording_enabled) {
        server.showMessage(.Info,
            \\This zls session is being recorded to {?s}.
        , .{server.config.record_session_path});
    }

    if (server.config.enable_ast_check_diagnostics and
        server.config.prefer_ast_check_as_child_process)
    {
        if (!std.process.can_spawn) {
            log.info("'prefer_ast_check_as_child_process' is ignored because your OS can't spawn a child process", .{});
        } else if (server.config.zig_exe_path == null) {
            log.info("'prefer_ast_check_as_child_process' is ignored because Zig could not be found", .{});
        }
    }

    return .{
        .serverInfo = .{
            .name = "zls",
            .version = build_options.version,
        },
        .capabilities = .{
            .positionEncoding = server.offset_encoding,
            .signatureHelpProvider = .{
                .triggerCharacters = &.{"("},
                .retriggerCharacters = &.{","},
            },
            .textDocumentSync = .{
                .TextDocumentSyncOptions = .{
                    .openClose = true,
                    .change = .Incremental,
                    .save = .{ .bool = true },
                    .willSave = true,
                    .willSaveWaitUntil = true,
                },
            },
            .renameProvider = .{ .bool = true },
            .completionProvider = .{
                .resolveProvider = false,
                .triggerCharacters = &[_][]const u8{ ".", ":", "@", "]", "/" },
                .completionItem = .{ .labelDetailsSupport = true },
            },
            .documentHighlightProvider = .{ .bool = true },
            .hoverProvider = .{ .bool = true },
            .codeActionProvider = .{ .bool = true },
            .declarationProvider = .{ .bool = true },
            .definitionProvider = .{ .bool = true },
            .typeDefinitionProvider = .{ .bool = true },
            .implementationProvider = .{ .bool = false },
            .referencesProvider = .{ .bool = true },
            .documentSymbolProvider = .{ .bool = true },
            .colorProvider = .{ .bool = false },
            .documentFormattingProvider = .{ .bool = true },
            .documentRangeFormattingProvider = .{ .bool = false },
            .foldingRangeProvider = .{ .bool = true },
            .selectionRangeProvider = .{ .bool = true },
            .workspaceSymbolProvider = .{ .bool = false },
            .workspace = .{
                .workspaceFolders = .{
                    .supported = false,
                    .changeNotifications = .{ .bool = false },
                },
            },
            .semanticTokensProvider = .{
                .SemanticTokensOptions = .{
                    .full = .{ .bool = true },
                    .range = .{ .bool = true },
                    .legend = .{
                        .tokenTypes = std.meta.fieldNames(semantic_tokens.TokenType),
                        .tokenModifiers = std.meta.fieldNames(semantic_tokens.TokenModifiers),
                    },
                },
            },
            .inlayHintProvider = .{ .bool = true },
        },
    };
}

fn initializedHandler(server: *Server, _: std.mem.Allocator, notification: types.InitializedParams) Error!void {
    _ = notification;

    if (server.status != .initializing) {
        log.warn("received a initialized notification but the server has not send a initialize request!", .{});
    }

    server.status = .initialized;

    if (server.client_capabilities.supports_workspace_did_change_configuration_dynamic_registration) {
        try server.registerCapability("workspace/didChangeConfiguration");
    }

    if (server.client_capabilities.supports_configuration)
        try server.requestConfiguration();
}

fn shutdownHandler(server: *Server, _: std.mem.Allocator, _: void) Error!?void {
    defer server.status = .shutdown;
    if (server.status != .initialized) return error.InvalidRequest; // received a shutdown request but the server is not initialized!
}

fn exitHandler(server: *Server, _: std.mem.Allocator, _: void) Error!void {
    server.status = switch (server.status) {
        .initialized => .exiting_failure,
        .shutdown => .exiting_success,
        else => unreachable,
    };
}

fn cancelRequestHandler(server: *Server, _: std.mem.Allocator, request: types.CancelParams) Error!void {
    _ = server;
    _ = request;
    // TODO implement $/cancelRequest
}

fn setTraceHandler(server: *Server, _: std.mem.Allocator, request: types.SetTraceParams) Error!void {
    server.message_tracing_enabled = request.value != .off;
}

fn registerCapability(server: *Server, method: []const u8) Error!void {
    const id = try std.fmt.allocPrint(server.allocator, "register-{s}", .{method});
    defer server.allocator.free(id);

    log.debug("Dynamically registering method '{s}'", .{method});

    server.sendRequest(
        .{ .string = id },
        "client/registerCapability",
        types.RegistrationParams{ .registrations = &.{
            types.Registration{
                .id = id,
                .method = method,
            },
        } },
    );
}

fn requestConfiguration(server: *Server) Error!void {
    if (server.recording_enabled) {
        log.info("workspace/configuration are disabled during a recording session!", .{});
        return;
    }

    const configuration_items = comptime config: {
        var comp_config: [std.meta.fields(Config).len]types.ConfigurationItem = undefined;
        inline for (std.meta.fields(Config), 0..) |field, index| {
            comp_config[index] = .{
                .section = "zls." ++ field.name,
            };
        }

        break :config comp_config;
    };

    server.sendRequest(
        .{ .string = "i_haz_configuration" },
        "workspace/configuration",
        types.ConfigurationParams{
            .items = &configuration_items,
        },
    );
}

fn handleConfiguration(server: *Server, json: std.json.Value) error{OutOfMemory}!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (server.replay_enabled) {
        log.info("workspace/configuration are disabled during a replay!", .{});
        return;
    }
    log.info("Setting configuration...", .{});

    // NOTE: Does this work with other editors?
    // Yes, String ids are officially supported by LSP
    // but not sure how standard this "standard" really is

    var new_zig_exe = false;
    const result = json.array;

    inline for (std.meta.fields(Config), result.items) |field, value| {
        const ft = if (@typeInfo(field.type) == .Optional)
            @typeInfo(field.type).Optional.child
        else
            field.type;
        const ti = @typeInfo(ft);

        if (value != .null) {
            const new_value: field.type = switch (ft) {
                []const u8 => switch (value) {
                    .string => |s| blk: {
                        const trimmed = std.mem.trim(u8, s, " ");
                        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "nil")) {
                            log.warn("Ignoring new value for \"zls.{s}\": the given new value is invalid", .{field.name});
                            break :blk @field(server.config, field.name);
                        }
                        var nv = try server.allocator.dupe(u8, trimmed);

                        if (comptime std.mem.eql(u8, field.name, "zig_exe_path")) {
                            if (server.config.zig_exe_path == null or !std.mem.eql(u8, nv, server.config.zig_exe_path.?)) {
                                new_zig_exe = true;
                            }
                        }

                        if (@field(server.config, field.name)) |prev_val| server.allocator.free(prev_val);

                        break :blk nv;
                    },
                    else => blk: {
                        log.warn("Ignoring new value for \"zls.{s}\": the given new value has an invalid type", .{field.name});
                        break :blk @field(server.config, field.name);
                    },
                },
                else => switch (ti) {
                    .Int => switch (value) {
                        .integer => |val| std.math.cast(ft, val) orelse blk: {
                            log.warn("Ignoring new value for \"zls.{s}\": the given new value is invalid", .{field.name});
                            break :blk @field(server.config, field.name);
                        },
                        else => blk: {
                            log.warn("Ignoring new value for \"zls.{s}\": the given new value has an invalid type", .{field.name});
                            break :blk @field(server.config, field.name);
                        },
                    },
                    .Bool => switch (value) {
                        .bool => |b| b,
                        else => blk: {
                            log.warn("Ignoring new value for \"zls.{s}\": the given new value has an invalid type", .{field.name});
                            break :blk @field(server.config, field.name);
                        },
                    },
                    .Enum => switch (value) {
                        .string => |s| blk: {
                            const trimmed = std.mem.trim(u8, s, " ");
                            break :blk std.meta.stringToEnum(field.type, trimmed) orelse inner: {
                                log.warn("Ignoring new value for \"zls.{s}\": the given new value is invalid", .{field.name});
                                break :inner @field(server.config, field.name);
                            };
                        },
                        else => blk: {
                            log.warn("Ignoring new value for \"zls.{s}\": the given new value has an invalid type", .{field.name});
                            break :blk @field(server.config, field.name);
                        },
                    },
                    else => @compileError("Not implemented for " ++ @typeName(ft)),
                },
            };
            // log.debug("setting configuration option '{s}' to '{any}'", .{ field.name, new_value });
            @field(server.config, field.name) = new_value;
        }
    }
    log.debug("{}", .{server.client_capabilities});

    configuration.configChanged(server.config, &server.runtime_zig_version, server.allocator, null) catch |err| {
        log.err("failed to update configuration: {}", .{err});
    };

    if (new_zig_exe)
        server.document_store.invalidateBuildFiles();
}

fn openDocumentHandler(server: *Server, arena: std.mem.Allocator, notification: types.DidOpenTextDocumentParams) Error!void {
    const handle = try server.document_store.openDocument(notification.textDocument.uri, notification.textDocument.text);

    if (server.client_capabilities.supports_publish_diagnostics) {
        const diagnostics = try diagnostics_gen.generateDiagnostics(server, arena, handle);
        server.sendNotification("textDocument/publishDiagnostics", diagnostics);
    }
}

fn changeDocumentHandler(server: *Server, arena: std.mem.Allocator, notification: types.DidChangeTextDocumentParams) Error!void {
    const handle = server.document_store.getHandle(notification.textDocument.uri) orelse return;

    const new_text = try diff.applyContentChanges(server.allocator, handle.text, notification.contentChanges, server.offset_encoding);

    try server.document_store.refreshDocument(handle.uri, new_text);

    if (server.client_capabilities.supports_publish_diagnostics) {
        const diagnostics = try diagnostics_gen.generateDiagnostics(server, arena, handle.*);
        server.sendNotification("textDocument/publishDiagnostics", diagnostics);
    }
}

fn saveDocumentHandler(server: *Server, arena: std.mem.Allocator, notification: types.DidSaveTextDocumentParams) Error!void {
    const uri = notification.textDocument.uri;

    try server.document_store.applySave(uri);

    if (server.getAutofixMode() == .on_save) {
        const handle = server.document_store.getHandle(uri) orelse return;
        var text_edits = try server.autofix(arena, handle);

        var workspace_edit = types.WorkspaceEdit{ .changes = .{} };
        try workspace_edit.changes.?.map.putNoClobber(arena, uri, try text_edits.toOwnedSlice(arena));

        server.sendRequest(
            .{ .string = "apply_edit" },
            "workspace/applyEdit",
            types.ApplyWorkspaceEditParams{
                .label = "autofix",
                .edit = workspace_edit,
            },
        );
    }
}

fn closeDocumentHandler(server: *Server, _: std.mem.Allocator, notification: types.DidCloseTextDocumentParams) error{}!void {
    server.document_store.closeDocument(notification.textDocument.uri);
}

fn willSaveWaitUntilHandler(server: *Server, arena: std.mem.Allocator, request: types.WillSaveTextDocumentParams) Error!?[]types.TextEdit {
    if (server.getAutofixMode() != .will_save_wait_until) return null;

    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    var text_edits = try server.autofix(arena, handle);

    return try text_edits.toOwnedSlice(arena);
}

fn semanticTokensFullHandler(server: *Server, arena: std.mem.Allocator, request: types.SemanticTokensParams) Error!?types.SemanticTokens {
    if (server.config.semantic_tokens == .none) return null;

    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    return try semantic_tokens.writeSemanticTokens(
        arena,
        &analyser,
        handle,
        null,
        server.offset_encoding,
        server.config.semantic_tokens == .partial,
    );
}

fn semanticTokensRangeHandler(server: *Server, arena: std.mem.Allocator, request: types.SemanticTokensRangeParams) Error!?types.SemanticTokens {
    if (server.config.semantic_tokens == .none) return null;

    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;
    const loc = offsets.rangeToLoc(handle.tree.source, request.range, server.offset_encoding);

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    return try semantic_tokens.writeSemanticTokens(
        arena,
        &analyser,
        handle,
        loc,
        server.offset_encoding,
        server.config.semantic_tokens == .partial,
    );
}

pub fn completionHandler(server: *Server, arena: std.mem.Allocator, request: types.CompletionParams) Error!?types.CompletionList {
    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    const source_index = offsets.positionToIndex(handle.text, request.position, server.offset_encoding);

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    return try completions.completionAtIndex(server, &analyser, arena, handle, source_index);
}

pub fn signatureHelpHandler(server: *Server, arena: std.mem.Allocator, request: types.SignatureHelpParams) Error!?types.SignatureHelp {
    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    if (request.position.character == 0) return null;

    const source_index = offsets.positionToIndex(handle.text, request.position, server.offset_encoding);

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    const signature_info = (try signature_help.getSignatureInfo(
        &analyser,
        arena,
        handle,
        source_index,
    )) orelse return null;

    var signatures = try arena.alloc(types.SignatureInformation, 1);
    signatures[0] = signature_info;

    return .{
        .signatures = signatures,
        .activeSignature = 0,
        .activeParameter = signature_info.activeParameter,
    };
}

fn gotoDefinitionHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.TextDocumentPositionParams,
) Error!?types.Definition {
    if (request.position.character == 0) return null;

    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;
    const source_index = offsets.positionToIndex(handle.text, request.position, server.offset_encoding);

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    return try goto.goto(&analyser, &server.document_store, arena, handle, source_index, true, server.offset_encoding);
}

fn gotoDeclarationHandler(
    server: *Server,
    arena: std.mem.Allocator,
    request: types.TextDocumentPositionParams,
) Error!?types.Definition {
    return try server.gotoDefinitionHandler(arena, request);
}

pub fn hoverHandler(server: *Server, arena: std.mem.Allocator, request: types.HoverParams) Error!?types.Hover {
    if (request.position.character == 0) return null;

    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;
    const source_index = offsets.positionToIndex(handle.text, request.position, server.offset_encoding);

    const markup_kind: types.MarkupKind = if (server.client_capabilities.hover_supports_md) .markdown else .plaintext;

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    const response = hover_handler.hover(&analyser, arena, handle, source_index, markup_kind);

    // TODO: Figure out a better solution for comptime interpreter diags
    if (server.client_capabilities.supports_publish_diagnostics) {
        const diagnostics = try diagnostics_gen.generateDiagnostics(server, arena, handle.*);
        server.sendNotification("textDocument/publishDiagnostics", diagnostics);
    }

    return response;
}

pub fn documentSymbolsHandler(server: *Server, arena: std.mem.Allocator, request: types.DocumentSymbolParams) Error!?[]types.DocumentSymbol {
    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;
    return try document_symbol.getDocumentSymbols(arena, handle.tree, server.offset_encoding);
}

pub fn formattingHandler(server: *Server, arena: std.mem.Allocator, request: types.DocumentFormattingParams) Error!?[]types.TextEdit {
    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    if (handle.tree.errors.len != 0) return null;

    const formatted = try handle.tree.render(arena);

    if (std.mem.eql(u8, handle.text, formatted)) return null;

    return if (diff.edits(arena, handle.text, formatted, server.offset_encoding)) |text_edits| text_edits.items else |_| null;
}

fn didChangeConfigurationHandler(server: *Server, arena: std.mem.Allocator, request: types.DidChangeConfigurationParams) Error!void {
    var new_zig_exe = false;

    // NOTE: VS Code seems to always respond with null
    if (request.settings != .null) {
        const cfg = std.json.parseFromValueLeaky(configuration.Configuration, arena, request.settings.object.get("zls") orelse request.settings, .{}) catch return;
        inline for (std.meta.fields(configuration.Configuration)) |field| {
            if (@field(cfg, field.name)) |value| {
                blk: {
                    if (@TypeOf(value) == []const u8) {
                        if (value.len == 0) {
                            break :blk;
                        }
                    }

                    if (comptime std.mem.eql(u8, field.name, "zig_exe_path")) {
                        if (cfg.zig_exe_path == null or !std.mem.eql(u8, value, cfg.zig_exe_path.?)) {
                            new_zig_exe = true;
                        }
                    }

                    if (@TypeOf(value) == []const u8) {
                        if (@field(server.config, field.name)) |existing| server.allocator.free(existing);
                        @field(server.config, field.name) = try server.allocator.dupe(u8, value);
                    } else {
                        @field(server.config, field.name) = value;
                    }
                    log.debug("setting configuration option '{s}' to '{any}'", .{ field.name, value });
                }
            }
        }

        configuration.configChanged(server.config, &server.runtime_zig_version, server.allocator, null) catch |err| {
            log.err("failed to update config: {}", .{err});
        };

        if (new_zig_exe)
            server.document_store.invalidateBuildFiles();
    } else if (server.client_capabilities.supports_configuration) {
        try server.requestConfiguration();
    }
}

pub fn renameHandler(server: *Server, arena: std.mem.Allocator, request: types.RenameParams) Error!?types.WorkspaceEdit {
    const response = try generalReferencesHandler(server, arena, .{ .rename = request });
    return if (response) |rep| rep.rename else null;
}

pub fn referencesHandler(server: *Server, arena: std.mem.Allocator, request: types.ReferenceParams) Error!?[]types.Location {
    const response = try generalReferencesHandler(server, arena, .{ .references = request });
    return if (response) |rep| rep.references else null;
}

pub fn documentHighlightHandler(server: *Server, arena: std.mem.Allocator, request: types.DocumentHighlightParams) Error!?[]types.DocumentHighlight {
    const response = try generalReferencesHandler(server, arena, .{ .highlight = request });
    return if (response) |rep| rep.highlight else null;
}

const GeneralReferencesRequest = union(enum) {
    rename: types.RenameParams,
    references: types.ReferenceParams,
    highlight: types.DocumentHighlightParams,

    pub fn uri(self: @This()) []const u8 {
        return switch (self) {
            .rename => |rename| rename.textDocument.uri,
            .references => |ref| ref.textDocument.uri,
            .highlight => |highlight| highlight.textDocument.uri,
        };
    }

    pub fn position(self: @This()) types.Position {
        return switch (self) {
            .rename => |rename| rename.position,
            .references => |ref| ref.position,
            .highlight => |highlight| highlight.position,
        };
    }
};

const GeneralReferencesResponse = union {
    rename: types.WorkspaceEdit,
    references: []types.Location,
    highlight: []types.DocumentHighlight,
};

pub fn generalReferencesHandler(server: *Server, arena: std.mem.Allocator, request: GeneralReferencesRequest) Error!?GeneralReferencesResponse {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const handle = server.document_store.getHandle(request.uri()) orelse return null;

    if (request.position().character <= 0) return null;

    const source_index = offsets.positionToIndex(handle.text, request.position(), server.offset_encoding);
    const pos_context = try Analyser.getPositionContext(server.allocator, handle.text, source_index, true);

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    // TODO: Make this work with branching types
    const decl = switch (pos_context) {
        .var_access => try analyser.getSymbolGlobal(source_index, handle),
        .field_access => |range| z: {
            const a = try analyser.getSymbolFieldAccesses(arena, handle, source_index, range);
            if (a) |b| {
                if (b.len != 0) break :z b[0];
            }

            break :z null;
        },
        .label => try Analyser.getLabelGlobal(source_index, handle),
        else => null,
    } orelse return null;

    const include_decl = switch (request) {
        .references => |ref| ref.context.includeDeclaration,
        else => true,
    };

    const locations = if (decl.decl.* == .label_decl)
        try references.labelReferences(arena, decl, server.offset_encoding, include_decl)
    else
        try references.symbolReferences(
            arena,
            &analyser,
            decl,
            server.offset_encoding,
            include_decl,
            server.config.skip_std_references,
            request != .highlight, // scan the entire workspace except for highlight
        );

    switch (request) {
        .rename => |rename| {
            var changes = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(types.TextEdit)){};

            for (locations.items) |loc| {
                const gop = try changes.getOrPutValue(arena, loc.uri, .{});
                try gop.value_ptr.append(arena, .{
                    .range = loc.range,
                    .newText = rename.newName,
                });
            }

            // TODO can we avoid having to move map from `changes` to `new_changes`?
            var new_changes: types.Map(types.DocumentUri, []const types.TextEdit) = .{};
            try new_changes.map.ensureTotalCapacity(arena, @intCast(changes.count()));

            var changes_it = changes.iterator();
            while (changes_it.next()) |entry| {
                new_changes.map.putAssumeCapacityNoClobber(entry.key_ptr.*, try entry.value_ptr.toOwnedSlice(arena));
            }

            return .{ .rename = .{ .changes = new_changes } };
        },
        .references => return .{ .references = locations.items },
        .highlight => {
            var highlights = try std.ArrayListUnmanaged(types.DocumentHighlight).initCapacity(arena, locations.items.len);
            const uri = handle.uri;
            for (locations.items) |loc| {
                if (!std.mem.eql(u8, loc.uri, uri)) continue;
                highlights.appendAssumeCapacity(.{
                    .range = loc.range,
                    .kind = .Text,
                });
            }
            return .{ .highlight = highlights.items };
        },
    }
}

fn inlayHintHandler(server: *Server, arena: std.mem.Allocator, request: types.InlayHintParams) Error!?[]types.InlayHint {
    if (!server.config.enable_inlay_hints) return null;

    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    const hover_kind: types.MarkupKind = if (server.client_capabilities.hover_supports_md) .markdown else .plaintext;
    const loc = offsets.rangeToLoc(handle.text, request.range, server.offset_encoding);

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    return try inlay_hints.writeRangeInlayHint(
        arena,
        server.config.*,
        &analyser,
        handle,
        loc,
        hover_kind,
        server.offset_encoding,
    );
}

fn codeActionHandler(server: *Server, arena: std.mem.Allocator, request: types.CodeActionParams) Error!?[]types.CodeAction {
    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    var analyser = Analyser.init(server.allocator, &server.document_store, &server.ip);
    defer analyser.deinit();

    var builder = code_actions.Builder{
        .arena = arena,
        .analyser = &analyser,
        .handle = handle,
        .offset_encoding = server.offset_encoding,
    };

    // as of right now, only ast-check errors may get a code action
    var diagnostics = std.ArrayListUnmanaged(types.Diagnostic){};
    if (server.config.enable_ast_check_diagnostics and handle.tree.errors.len == 0) {
        try diagnostics_gen.getAstCheckDiagnostics(server, arena, handle.*, &diagnostics);
    }

    var actions = std.ArrayListUnmanaged(types.CodeAction){};
    var remove_capture_actions = std.AutoHashMapUnmanaged(types.Range, void){};
    for (diagnostics.items) |diagnostic| {
        try builder.generateCodeAction(diagnostic, &actions, &remove_capture_actions);
    }

    return actions.items;
}

fn foldingRangeHandler(server: *Server, arena: std.mem.Allocator, request: types.FoldingRangeParams) Error!?[]types.FoldingRange {
    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    return try folding_range.generateFoldingRanges(arena, handle.tree, server.offset_encoding);
}

fn selectionRangeHandler(server: *Server, arena: std.mem.Allocator, request: types.SelectionRangeParams) Error!?[]*types.SelectionRange {
    const handle = server.document_store.getHandle(request.textDocument.uri) orelse return null;

    return try selection_range.generateSelectionRanges(arena, handle, request.positions, server.offset_encoding);
}

/// return true if there is a request with the given method name
fn requestMethodExists(method: []const u8) bool {
    const methods = comptime blk: {
        var methods: [types.request_metadata.len][]const u8 = undefined;
        for (types.request_metadata, &methods) |meta, *out| {
            out.* = meta.method;
        }
        break :blk methods;
    };

    return for (methods) |name| {
        if (std.mem.eql(u8, method, name)) break true;
    } else false;
}

/// return true if there is a notification with the given method name
fn notificationMethodExists(method: []const u8) bool {
    const methods = comptime blk: {
        var methods: [types.notification_metadata.len][]const u8 = undefined;
        for (types.notification_metadata, 0..) |meta, i| {
            methods[i] = meta.method;
        }
        break :blk methods;
    };

    return for (methods) |name| {
        if (std.mem.eql(u8, method, name)) break true;
    } else false;
}

const Message = struct {
    kind: enum {
        RequestMessage,
        NotificationMessage,
        ResponseMessage,
    },

    id: ?types.RequestId = null,
    method: ?[]const u8 = null,
    params: ?types.LSPAny = null,
    /// non null on success
    result: ?types.LSPAny = null,
    @"error": ?types.ResponseError = null,

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Message {
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        if (source != .object) return error.UnexpectedToken;
        const object = source.object;

        if (object.get("id")) |id_obj| {
            const msg_id = try std.json.parseFromValueLeaky(types.RequestId, allocator, id_obj, options);

            if (object.get("method")) |method_obj| {
                const msg_method = switch (method_obj) {
                    .string => |str| str,
                    else => return error.UnexpectedToken,
                };

                const msg_params = object.get("params") orelse .null;

                return .{
                    .kind = .RequestMessage,
                    .id = msg_id,
                    .method = msg_method,
                    .params = msg_params,
                };
            } else {
                const result = object.get("result") orelse .null;
                const error_obj = object.get("error") orelse .null;

                const err = try std.json.parseFromValueLeaky(?types.ResponseError, allocator, error_obj, options);

                if (result != .null and err != null) return error.UnexpectedToken;

                return .{
                    .kind = .ResponseMessage,
                    .id = msg_id,
                    .result = result,
                    .@"error" = err,
                };
            }
        } else {
            const msg_method = switch (object.get("method") orelse return error.UnexpectedToken) {
                .string => |str| str,
                else => return error.UnexpectedToken,
            };

            const msg_params = object.get("params") orelse .null;

            return .{
                .kind = .NotificationMessage,
                .method = msg_method,
                .params = msg_params,
            };
        }
    }
};

pub fn processJsonRpc(
    server: *Server,
    json: []const u8,
) void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = std.json.parseFromSlice(std.json.Value, server.allocator, json, .{}) catch |err| {
        log.err("failed to parse message: {}", .{err});
        return; // maybe panic?
    };
    defer tree.deinit();

    const message = std.json.parseFromValueLeaky(Message, tree.arena.allocator(), tree.value, .{}) catch |err| {
        log.err("failed to parse message: {}", .{err});
        return; // maybe panic?
    };

    server.processMessage(message) catch |err| switch (message.kind) {
        .RequestMessage => server.sendResponseError(message.id.?, .{
            .code = @intFromError(err),
            .message = @errorName(err),
        }),
        else => {},
    };
}

pub fn processMessage(server: *Server, message: Message) Error!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    switch (message.kind) {
        .RequestMessage => {
            if (!requestMethodExists(message.method.?)) return error.MethodNotFound;
        },
        .NotificationMessage => {
            if (!notificationMethodExists(message.method.?)) return error.MethodNotFound;
        },
        .ResponseMessage => {
            const id = switch (message.id.?) {
                .string => |str| str,
                .integer => return,
            };
            if (std.mem.startsWith(u8, id, "register")) {
                if (message.@"error") |err| {
                    log.err("Error response for '{s}': {}, {s}", .{ id, err.code, err.message });
                }
                return;
            }
            if (std.mem.eql(u8, id, "apply_edit")) return;

            if (std.mem.eql(u8, id, "i_haz_configuration")) {
                if (message.@"error" != null) return;
                try server.handleConfiguration(message.result.?);
                return;
            }

            log.warn("received response from client with id '{s}' that has no handler!", .{id});
            return;
        },
    }

    const method = message.method.?; // message cannot be a ResponseMessage

    switch (server.status) {
        .uninitialized => blk: {
            if (std.mem.eql(u8, method, "initialize")) break :blk;
            if (std.mem.eql(u8, method, "exit")) break :blk;

            return error.ServerNotInitialized; // server received a request before being initialized!
        },
        .initializing => blk: {
            if (std.mem.eql(u8, method, "initialized")) break :blk;
            if (std.mem.eql(u8, method, "$/progress")) break :blk;

            return error.InvalidRequest; // server received a request during initialization!
        },
        .initialized => {},
        .shutdown => blk: {
            if (std.mem.eql(u8, method, "exit")) break :blk;

            return error.InvalidRequest; // server received a request after shutdown!
        },
        .exiting_success,
        .exiting_failure,
        => unreachable,
    }

    const start_time = std.time.milliTimestamp();
    defer {
        // makes `zig build test` look nice
        if (!zig_builtin.is_test) {
            const end_time = std.time.milliTimestamp();
            log.debug("Took {}ms to process method {s}", .{ end_time - start_time, method });
        }
    }

    const method_map = .{
        .{ "initialized", initializedHandler },
        .{ "initialize", initializeHandler },
        .{ "shutdown", shutdownHandler },
        .{ "exit", exitHandler },
        .{ "$/cancelRequest", cancelRequestHandler },
        .{ "$/setTrace", setTraceHandler },
        .{ "textDocument/didOpen", openDocumentHandler },
        .{ "textDocument/didChange", changeDocumentHandler },
        .{ "textDocument/didSave", saveDocumentHandler },
        .{ "textDocument/didClose", closeDocumentHandler },
        .{ "textDocument/willSaveWaitUntil", willSaveWaitUntilHandler },
        .{ "textDocument/semanticTokens/full", semanticTokensFullHandler },
        .{ "textDocument/semanticTokens/range", semanticTokensRangeHandler },
        .{ "textDocument/inlayHint", inlayHintHandler },
        .{ "textDocument/completion", completionHandler },
        .{ "textDocument/signatureHelp", signatureHelpHandler },
        .{ "textDocument/definition", gotoDefinitionHandler },
        .{ "textDocument/typeDefinition", gotoDefinitionHandler },
        .{ "textDocument/implementation", gotoDefinitionHandler },
        .{ "textDocument/declaration", gotoDeclarationHandler },
        .{ "textDocument/hover", hoverHandler },
        .{ "textDocument/documentSymbol", documentSymbolsHandler },
        .{ "textDocument/formatting", formattingHandler },
        .{ "textDocument/rename", renameHandler },
        .{ "textDocument/references", referencesHandler },
        .{ "textDocument/documentHighlight", documentHighlightHandler },
        .{ "textDocument/codeAction", codeActionHandler },
        .{ "workspace/didChangeConfiguration", didChangeConfigurationHandler },
        .{ "textDocument/foldingRange", foldingRangeHandler },
        .{ "textDocument/selectionRange", selectionRangeHandler },
    };

    comptime {
        inline for (method_map) |method_info| {
            _ = method_info;
            // TODO validate that the method actually exists
            // TODO validate that direction is client_to_server
            // TODO validate that the handler accepts and returns the correct types
            // TODO validate that notification handler return Error!void
            // TODO validate handler parameter names
        }
    }

    @setEvalBranchQuota(10000);
    inline for (method_map) |method_info| {
        if (std.mem.eql(u8, method, method_info[0])) {
            const handler = method_info[1];

            const handler_info: std.builtin.Type.Fn = @typeInfo(@TypeOf(handler)).Fn;
            const ParamsType = handler_info.params[2].type.?; // TODO add error message on null
            var arena_allocator = std.heap.ArenaAllocator.init(server.allocator);
            defer arena_allocator.deinit();

            const params: ParamsType = if (ParamsType == void)
                void{}
            else
                std.json.parseFromValueLeaky(
                    ParamsType,
                    arena_allocator.allocator(),
                    message.params.?,
                    .{ .ignore_unknown_fields = true },
                ) catch |err| {
                    log.err("failed to parse params from {s}: {}", .{ method, err });
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                    return error.ParseError;
                };

            const response = blk: {
                const tracy_zone2 = tracy.trace(@src());
                defer tracy_zone2.end();
                tracy_zone2.setName(method);

                break :blk handler(server, arena_allocator.allocator(), params) catch |err| {
                    log.err("got {} error while handling {s}", .{ err, method });
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                    return error.InternalError;
                };
            };

            if (@TypeOf(response) == void) return;

            if (message.kind == .RequestMessage) {
                server.sendResponse(message.id.?, response);
            }

            return;
        }
    }

    switch (message.kind) {
        .RequestMessage => server.sendResponse(message.id.?, null),
        .NotificationMessage => return,
        .ResponseMessage => unreachable,
    }
}

pub fn create(
    allocator: std.mem.Allocator,
    config: *Config,
    config_path: ?[]const u8,
    recording_enabled: bool,
    replay_enabled: bool,
    message_tracing_enabled: bool,
) !*Server {
    const server = try allocator.create(Server);
    errdefer server.destroy();
    server.* = Server{
        .config = config,
        .runtime_zig_version = null,
        .allocator = allocator,
        .document_store = .{
            .allocator = allocator,
            .config = config,
            .runtime_zig_version = &server.runtime_zig_version,
        },
        .recording_enabled = recording_enabled,
        .replay_enabled = replay_enabled,
        .message_tracing_enabled = message_tracing_enabled,
        .status = .uninitialized,
    };

    var builtin_creation_dir = config_path;
    if (config_path) |path| {
        builtin_creation_dir = std.fs.path.dirname(path);
    }

    try configuration.configChanged(config, &server.runtime_zig_version, allocator, builtin_creation_dir);

    if (config.dangerous_comptime_experiments_do_not_enable) {
        server.ip = try InternPool.init(allocator);
    }

    return server;
}

pub fn destroy(server: *Server) void {
    server.document_store.deinit();
    server.ip.deinit(server.allocator);

    for (server.outgoing_messages.items) |message| {
        server.allocator.free(message);
    }
    server.outgoing_messages.deinit(server.allocator);

    if (server.runtime_zig_version) |zig_version| {
        zig_version.free();
    }

    server.allocator.destroy(server);
}
