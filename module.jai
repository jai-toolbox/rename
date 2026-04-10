#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Sort";
#import "Basic";

#scope_module

Symbol_Rename_Request :: struct {
    filename:  string;
    line:      s32;
    character: s32;
    new_name:  string;
}

Rename_Edit :: struct {
    filename:   string;
    line:       s32;
    char_start: s32;
    char_end:   s32;
    new_text:   string;
}

Buffered_Reference :: struct {
    resolved_declaration: *Code_Declaration;
    filename:   string;
    line:       s32;
    char_start: s32;
    char_end:   s32;
    name:       string;
}

Buffered_Block :: struct {
    block: *Code_Block;
}

rename_request:      Symbol_Rename_Request;
rename_auto_confirm: bool;
rename_active:       bool;
rename_all_references: [..] Buffered_Reference;
rename_all_blocks:     [..] Buffered_Block;

get_node_filename :: (node: *Code_Node) -> string {
    if node == null          return "";
    if !node.enclosing_load  return "";
    return node.enclosing_load.fully_pathed_filename;
}

buffer_node :: (all_references: *[..] Buffered_Reference, node: *Code_Node) {
    if node == null  return;

    if node.kind == {
        case .IDENT;
            ident := cast(*Code_Ident) node;
            if ident.resolved_declaration == null  return;
            if ident.name.count == 0               return;

            ref: Buffered_Reference;
            ref.resolved_declaration = ident.resolved_declaration;
            ref.filename   = get_node_filename(node);
            ref.line       = node.l0;
            ref.char_start = node.c0;
            ref.char_end   = node.c0 + cast(s32) ident.name.count;
            ref.name       = ident.name;
            array_add(all_references, ref);

        case .DECLARATION;
            decl := cast(*Code_Declaration) node;
            if decl.name.count == 0  return;

            ref: Buffered_Reference;
            ref.resolved_declaration = decl;
            ref.filename   = get_node_filename(node);
            ref.line       = node.l0;
            ref.char_start = node.c0;
            ref.char_end   = node.c0 + cast(s32) decl.name.count;
            ref.name       = decl.name;
            array_add(all_references, ref);
    }
}

buffer_block :: (all_blocks: *[..] Buffered_Block, block: *Code_Block) {
    if block == null  return;
    for all_blocks.*  { if it.block == block  return; }
    array_add(all_blocks, .{block});
}

buffer_block_recursive :: (all_blocks: *[..] Buffered_Block, block: *Code_Block) {
    if block == null  return;
    buffer_block(all_blocks, block);
    for block.statements {
        if it == null  continue;
        if it.kind == {
            case .IF;
                ifc := cast(*Code_If) it;
                if ifc.then_block  buffer_block_recursive(all_blocks, ifc.then_block);
                if ifc.else_block  buffer_block_recursive(all_blocks, ifc.else_block);
            case .WHILE;
                wh := cast(*Code_While) it;
                if wh.block  buffer_block_recursive(all_blocks, wh.block);
            case .FOR;
                fc := cast(*Code_For) it;
                if fc.block  buffer_block_recursive(all_blocks, fc.block);
            case .BLOCK;
                buffer_block_recursive(all_blocks, cast(*Code_Block) it);
        }
    }
}

find_parent_block :: (all_blocks: [] Buffered_Block, decl: *Code_Declaration) -> *Code_Block {
    for bb: all_blocks {
        for bb.block.members {
            if cast(*Code_Node) it == cast(*Code_Node) decl  return bb.block;
        }
    }
    return null;
}

resolve_path :: (path: string, cwd: string) -> string {
    if path.count == 0                               return path;
    if path.count >= 2 && path[1] == #char ":"       return path;
    if path[0] == #char "/"                          return path;

    result := tprint("%/%", cwd, path);
    for i: 0..result.count-1 {
        if result[i] == #char "\\"  result[i] = #char "/";
    }
    return result;
}

find_last :: (s: string, c: u8) -> s64 {
    i := s.count - 1;
    while i >= 0 {
        if s[i] == c  return i;
        i -= 1;
    }
    return -1;
}

find_first :: (s: string, c: u8) -> s64 {
    for i: 0..s.count-1 {
        if s[i] == c  return i;
    }
    return -1;
}

parse_location :: (arg: string, cwd: string) -> (ok: bool, filename: string, line: s32, col: s32) {
    at_index := find_last(arg, #char "@");
    if at_index < 1  return false, "", 0, 0;

    filename_part := slice(arg, 0, at_index);
    rest := slice(arg, at_index + 1, arg.count - at_index - 1);

    colon_index := find_first(rest, #char ":");
    if colon_index < 1  return false, "", 0, 0;

    line_str := slice(rest, 0, colon_index);
    col_str  := slice(rest, colon_index + 1, rest.count - colon_index - 1);

    ok: bool;
    line_val: s64;
    col_val:  s64;

    line_val, ok = string_to_int(line_str);
    if !ok  return false, "", 0, 0;

    col_val, ok = string_to_int(col_str);
    if !ok  return false, "", 0, 0;

    return true, resolve_path(filename_part, cwd), cast(s32) line_val, cast(s32) col_val;
}

#scope_export

rename_parse_args :: () -> bool {
    args := get_build_options().compile_time_command_line;
    cwd  := get_working_directory();

    found_rename := false;
    i := 0;
    while i < args.count {
        if args[i] == "-rename" {
            found_rename = true;
            i += 1;

            if i < args.count {
                ok, filename, line, col := parse_location(args[i], cwd);
                if ok {
                    rename_request.filename  = filename;
                    rename_request.line      = line;
                    rename_request.character = col;
                    i += 1;
                }
            }

            if i < args.count && args[i][0] != #char "-" {
                rename_request.new_name = args[i];
                i += 1;
            }

            continue;
        }

        if args[i] == "-y" {
            rename_auto_confirm = true;
            i += 1;
            continue;
        }

        i += 1;
    }

    if found_rename
    && rename_request.filename.count > 0
    && rename_request.line > 0
    && rename_request.character > 0
    && rename_request.new_name.count > 0 {
        rename_active = true;
        log("Rename: '%' at %:%:% -> '%'",
            rename_request.filename, rename_request.filename,
            rename_request.line, rename_request.character,
            rename_request.new_name);
        return true;
    }

    if found_rename {
        log_error("Incomplete rename arguments. Usage: -rename <file>@<line>:<col> <new_name> [-y]");
    }

    return false;
}

rename_handle_message :: (message: *Message) {
    if !rename_active  return;

    if message.kind == {
        case .TYPECHECKED;
            tc := cast(*Message_Typechecked) message;
            for tc.all {
                buffer_node(*rename_all_references, it.expression);
                for sub: it.subexpressions {
                    buffer_node(*rename_all_references, sub);
                }
            }

            for tc.structs {
                s := it.expression;
                if s.block {
                    buffer_block(*rename_all_blocks, s.block);
                    for s.block.members    buffer_node(*rename_all_references, it);
                    for s.block.statements buffer_node(*rename_all_references, it);
                }
                if s.arguments_block {
                    buffer_block(*rename_all_blocks, s.arguments_block);
                    for s.arguments_block.members  buffer_node(*rename_all_references, it);
                }
                if s.constants_block {
                    buffer_block(*rename_all_blocks, s.constants_block);
                    for s.constants_block.members  buffer_node(*rename_all_references, it);
                }
            }

            for tc.procedure_bodies {
                body := it.expression;
                if body.block  buffer_block_recursive(*rename_all_blocks, body.block);
            }
    }
}

rename_finish :: () {
    if !rename_active  return;

    request := rename_request;

    log("Collected % references, % blocks", rename_all_references.count, rename_all_blocks.count);

    // resolve target
    target_declaration: *Code_Declaration;
    old_name: string;

    for rename_all_references {
        if it.line != request.line              continue;
        if request.character < it.char_start    continue;
        if request.character >= it.char_end     continue;
        if it.filename.count == 0               continue;

        if it.filename == request.filename
        || ends_with(it.filename, request.filename)
        || ends_with(request.filename, it.filename) {
            target_declaration = it.resolved_declaration;
            old_name = it.name;
            break;
        }
    }

    if target_declaration == null {
        log_error("No symbol found at %:%:%", request.filename, request.line, request.character);
        return;
    }

    // collision check
    target_block := find_parent_block(rename_all_blocks, target_declaration);
    if target_block != null {
        for rename_all_references {
            if it.resolved_declaration == target_declaration  continue;
            if it.name != request.new_name                    continue;
            other_decl := it.resolved_declaration;
            if other_decl == null  continue;
            other_block := find_parent_block(rename_all_blocks, other_decl);
            if other_block == target_block {
                decl_file := get_node_filename(cast(*Code_Node) other_decl);
                log_error("Rename would collide with existing symbol '%' declared at %:%:%",
                    request.new_name, decl_file, other_decl.l0, other_decl.c0);
                return;
            }
        }
    }

    // preview
    File_Count :: struct {
        filename: string;
        count:    s32;
    }

    decl_file := get_node_filename(cast(*Code_Node) target_declaration);
    file_counts: [..] File_Count;
    total := 0;

    for ref: rename_all_references {
        if ref.resolved_declaration != target_declaration  continue;
        total += 1;
        found := false;
        for *fc: file_counts {
            if fc.filename == ref.filename { fc.count += 1; found = true; break; }
        }
        if !found  array_add(*file_counts, File_Count.{ref.filename, 1});
    }

    log("Rename Preview");
    log(" ");
    log("  Symbol:      '%'", old_name);
    log("  New name:    '%'", request.new_name);
    log("  Declared at: %:%:%", decl_file, target_declaration.l0, target_declaration.c0);
    log(" ");
    log("  Total occurrences: %", total);
    log(" ");
    log("  Files affected:");
    for file_counts  log("    %  (% occurrences)", it.filename, it.count);

    if !rename_auto_confirm {
        log(" ");
        log("This is a preview. Add -y to apply the rename.");
        return;
    }

    collected_edits: [..] Rename_Edit;

    for rename_all_references {
        if it.resolved_declaration != target_declaration  continue;

        edit: Rename_Edit;
        edit.filename   = it.filename;
        edit.line       = it.line;
        edit.char_start = it.char_start;
        edit.char_end   = it.char_end;
        edit.new_text   = request.new_name;

        already := false;
        for collected_edits {
            if it.filename == edit.filename && it.line == edit.line && it.char_start == edit.char_start {
                already = true; break;
            }
        }
        if !already  array_add(*collected_edits, edit);
    }

    log(" ");
    log("Applying % edits...", collected_edits.count);

    if collected_edits.count == 0 { log("Nothing to rename."); return; }

    quick_sort(collected_edits, (a: Rename_Edit, b: Rename_Edit) -> s64 {
        if a.line != b.line  return cast(s64)(b.line - a.line);
        return cast(s64)(b.char_start - a.char_start);
    });

    files_done: [..] string;

    for edit: collected_edits {
        already_done := false;
        for files_done  if it == edit.filename { already_done = true; break; }
        if already_done  continue;

        array_add(*files_done, edit.filename);

        contents, success := read_entire_file(edit.filename);
        if !success { log_error("Could not read '%'", edit.filename); continue; }

        lines := split(contents, "\n");
        count := 0;

        for e: collected_edits {
            if e.filename != edit.filename  continue;
            line_idx := e.line - 1;
            if line_idx < 0 || line_idx >= lines.count  continue;

            line := lines[line_idx];
            col_start := e.char_start - 1;
            col_end   := e.char_end - 1;
            if col_start < 0 || col_end > line.count  continue;

            new_line := join(
                slice(line, 0, col_start),
                e.new_text,
                slice(line, col_end, line.count - col_end)
            );
            lines[line_idx] = new_line;
            count += 1;
        }

        new_contents := join(..lines, separator = "\n");
        write_entire_file(edit.filename, new_contents);
        log("  Renamed % occurrences in '%'", count, edit.filename);
    }

    log(" ");
    log("Done.");
}
