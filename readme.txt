A compile-time rename tool for Jai projects. It hooks into your existing build.jai to accurately rename symbols across your entire codebase, using the compiler's own type-checked AST to find all references.


---------

Hey oh no, this looks awfully complicated for a simple rename... Well we have to hook into the compliation because we're not going to just make our own thing that does some section of the compliation when that's already done for us. Maybe when the jai compiler is self-hosted we can simplify this though.

---------

integration: 

1. Copy the modules/rename/ directory into your project's modules/ folder (or anywhere accessible).

2. Add two things to your build.jai:

   a. #load the module at the top level:

      #load "modules/rename/module.jai";

   b. Add three lines inside your #run block:

      #run {

          // ... your existing setup ...

          is_renaming := rename_parse_args(); // (1)

          // After setting build options, before set_build_options():
          if is_renaming  options.output_type = .NO_OUTPUT;

          // ... set_build_options, compiler_begin_intercept, add_build_file ...

          // inside your message loop:
          while true {
              message := compiler_wait_for_message();
              if message.kind == .ERROR   exit(1);

              if is_renaming  rename_handle_message(message); // (2)

              if message.kind == .COMPLETE break;
          }

          // after the message loop:
          if is_renaming  rename_finish(); // (3)
      };


The reason we intrude into your build.jai file is because we have to compile the code, if it were a plugin then it wouldn't have access to the inner loop or something (it didn't work as a plugin I forget exactly why), and it can't be its own standalone program because it needs to build your project, and only your build.jai file knows how to do that, so we have to intrude.

---------

Usage:

Preview a Rename:

  jai build.jai - -rename <file>@<line>:<col> <new_name>

  Compiles your project, finds all references to the symbol at the given
  location, and prints a preview showing what would change. No files are
  modified.

Apply a Rename:

  jai build.jai - -rename <file>@<line>:<col> <new_name> -y

  Same as above, but actually writes the changes to disk.

Not using it:

  jai build.jai

  When -rename is not on the command line, the rename tool is completely
  inactive. Your build works exactly as before.


---------

arguments:

  <file>@<line>:<col>   Location of the symbol to rename. Line and column
                        are 1-based. The file path is relative to your
                        working directory.

  <new_name>            The new name for the symbol.

  -y                    Apply the rename. Without this flag, only a preview is shown.

---------

example:

  # preview renaming a local variable
  jai build.jai - -rename src/main.jai@42:5 new_variable_name

