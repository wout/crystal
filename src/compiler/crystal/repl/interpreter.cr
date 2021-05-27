require "./repl"
require "ffi"
require "colorize"

class Crystal::Repl::Interpreter
  record CallFrame,
    compiled_def : CompiledDef,
    instructions : Array(UInt8),
    nodes : Hash(Int32, ASTNode),
    ip : Pointer(UInt8),
    stack : Pointer(UInt8),
    stack_bottom : Pointer(UInt8),
    block_caller_frame_index : Int32,
    constant_index : Int32

  @pry_node : ASTNode?

  def initialize(@context : Context)
    @local_vars = LocalVars.new(@context)

    @instructions = [] of Instruction
    @nodes = {} of Int32 => ASTNode

    # TODO: what if the stack is exhausted?
    # TODO: use 8MB for this, and on the heap
    @stack = Pointer(UInt8).malloc(8096)
    @call_stack = [] of CallFrame
    @constants = Pointer(UInt8).null

    @main_visitor = MainVisitor.new(program)
    @top_level_visitor = TopLevelVisitor.new(program)
    @cleanup_transformer = CleanupTransformer.new(program)

    @compiled_def = nil
    @pry = false
    @pry_node = nil
  end

  def initialize(interpreter : Interpreter, compiled_def : CompiledDef, stack : Pointer(UInt8))
    @context = interpreter.@context
    @local_vars = compiled_def.local_vars.dup

    @instructions = [] of Instruction
    @nodes = {} of Int32 => ASTNode

    @stack = stack
    @call_stack = [] of CallFrame
    @constants = interpreter.@constants

    meta_vars = MetaVars.new
    compiled_def.local_vars.each_name_and_type do |name, type|
      meta_vars[name] = MetaVar.new(name, type)
    end

    @main_visitor = MainVisitor.new(
      interpreter.@context.program,
      vars: meta_vars,
      typed_def: compiled_def.def)
    @main_visitor.scope = compiled_def.def.owner
    @main_visitor.path_lookup = compiled_def.def.owner # TODO: this is probably not right

    @top_level_visitor = interpreter.@top_level_visitor
    @cleanup_transformer = interpreter.@cleanup_transformer

    @compiled_def = compiled_def
    @pry = false
    @pry_node = nil
  end

  def interpret(node : ASTNode) : Value
    node = program.normalize(node)

    @top_level_visitor.backup do
      node.accept @top_level_visitor
    end

    @main_visitor.backup do
      node.accept @main_visitor
    end

    node = node.transform(@cleanup_transformer)

    # Declare local variables
    # TODO: reuse previously declared variables
    @main_visitor.meta_vars.each do |name, meta_var|
      @local_vars.declare(name, meta_var.type)
    end

    compiled_def = @compiled_def

    compiler =
      if compiled_def
        Compiler.new(@context, @local_vars, scope: compiled_def.def.owner, def: compiled_def.def)
      else
        Compiler.new(@context, @local_vars)
      end
    compiler.compile(node)

    @instructions = compiler.instructions
    @nodes = compiler.nodes

    if @context.decompile
      if compiled_def
        puts "=== #{compiled_def.def.owner}##{compiled_def.def.name} ==="
      else
        puts "=== top-level ==="
      end
      puts @local_vars
      puts Disassembler.disassemble(@instructions, @local_vars)

      if compiled_def
        puts "=== #{compiled_def.def.owner}##{compiled_def.def.name} ==="
      else
        puts "=== top-level ==="
      end
    end

    time = Time.monotonic
    value = interpret(node.type)
    if @context.stats
      puts "Elapsed: #{Time.monotonic - time}"
    end

    value
  end

  def local_var_keys
    @local_vars.names
  end

  def interpret(node_type : Type) : Value
    stack_bottom = @stack

    # Shift stack to leave ream for local vars
    # Previous runs that wrote to local vars would have those values
    # written to @stack alreay
    stack_bottom_after_local_vars = stack_bottom + @local_vars.bytesize
    stack = stack_bottom_after_local_vars

    # Reserve space for constants
    @constants = @constants.realloc(@context.constants.bytesize)

    instructions = @instructions
    nodes = @nodes
    ip = instructions.to_unsafe
    return_value = Pointer(UInt8).null

    compiled_def = @compiled_def

    @call_stack << CallFrame.new(
      compiled_def: CompiledDef.new(
        context: @context,
        def: compiled_def ? compiled_def.def : Def.new("main").tap { |a_def| a_def.owner = program },
        args_bytesize: 0,
        instructions: instructions,
        nodes: @nodes,
        local_vars: @local_vars,
      ),
      instructions: instructions,
      nodes: nodes,
      ip: ip,
      stack: stack,
      stack_bottom: stack_bottom,
      block_caller_frame_index: -1,
      constant_index: -1,
    )

    while true
      if @context.trace
        puts

        call_frame = @call_stack.last
        a_def = call_frame.compiled_def.def
        offset = (ip - instructions.to_unsafe).to_i32
        puts "In: #{a_def.owner}##{a_def.name}"
        node = nodes[offset]?
        puts "Node: #{node}" if node
        puts Slice.new(@stack, stack - @stack).hexdump

        Disassembler.disassemble_one(instructions, offset, current_local_vars, STDOUT)
        puts
      end

      pry(ip, instructions, nodes, stack_bottom) if @pry

      op_code = next_instruction OpCode

      {% begin %}
        case op_code
          {% for name, instruction in Crystal::Repl::Instructions %}
            {% operands = instruction[:operands] %}
            {% pop_values = instruction[:pop_values] %}

            in .{{name.id}}?
              {% for operand in operands %}
                {{operand.var}} = next_instruction {{operand.type}}
              {% end %}

              {% for pop_value, i in pop_values %}
                {% pop = pop_values[pop_values.size - i - 1] %}
                {{ pop.var }} = stack_pop({{pop.type}})
              {% end %}

              {% if instruction[:push] %}
                stack_push({{instruction[:code]}})
              {% else %}
                {{instruction[:code]}}
              {% end %}
          {% end %}
        end
      {% end %}

      if @context.trace
        puts Slice.new(@stack, stack - @stack).hexdump
      end
    end

    if stack != stack_bottom_after_local_vars
      raise "BUG: data left on stack (#{stack - stack_bottom_after_local_vars} bytes): #{Slice.new(@stack, stack - @stack)}"
    end

    Value.new(@context, return_value, node_type)
  end

  private def current_local_vars
    if call_frame = @call_stack.last?
      call_frame.compiled_def.local_vars
    else
      @local_vars
    end
  end

  private macro call(compiled_def, block_caller_frame_index = -1, constant_index = -1)
    # At the point of a call like:
    #
    #     foo(x, y)
    #
    # x and y will already be in the stack, ready to be used
    # as the function arguments in the target def.
    #
    # After the call, we want the stack to be at the point
    # where it doesn't have the call args, ready to push
    # return call's return value.
    %stack_before_call_args = stack - {{compiled_def}}.args_bytesize
    @call_stack[-1] = @call_stack.last.copy_with(
      ip: ip,
      stack: %stack_before_call_args,
    )

    %call_frame = CallFrame.new(
      compiled_def: {{compiled_def}},
      instructions: {{compiled_def}}.instructions,
      nodes: {{compiled_def}}.nodes,
      ip: {{compiled_def}}.instructions.to_unsafe,
      # We need to adjust the call stack to start right
      # after the target def's local variables.
      stack: %stack_before_call_args + {{compiled_def}}.local_vars.bytesize,
      stack_bottom: %stack_before_call_args,
      block_caller_frame_index: {{block_caller_frame_index}},
      constant_index: {{constant_index}},
    )

    @call_stack << %call_frame

    instructions = %call_frame.compiled_def.instructions
    nodes = %call_frame.compiled_def.nodes
    ip = %call_frame.ip
    stack = %call_frame.stack
    stack_bottom = %call_frame.stack_bottom
  end

  private macro call_with_block(compiled_def)
    call({{compiled_def}}, block_caller_frame_index: @call_stack.size - 1)
  end

  private macro call_block(compiled_block)
    # At this point the stack has the yield expressions, so after the call
    # we must go back to before the yield expressions
    %stack_before_call_args = stack - {{compiled_block}}.args_bytesize
    @call_stack[-1] = @call_stack.last.copy_with(
      ip: ip,
      stack: %stack_before_call_args,
    )

    copied_call_frame = @call_stack[@call_stack.last.block_caller_frame_index].copy_with(
      instructions: {{compiled_block}}.instructions,
      nodes: {{compiled_block}}.nodes,
      ip: {{compiled_block}}.instructions.to_unsafe,
      stack: stack,
    )
    @call_stack << copied_call_frame

    instructions = copied_call_frame.instructions
    nodes = copied_call_frame.nodes
    ip = copied_call_frame.ip
    stack_bottom = copied_call_frame.stack_bottom
  end

  private macro lib_call(lib_function)
    %target_def = lib_function.def
    %cif = lib_function.call_interface
    %fn = lib_function.symbol

    # Assume C calls don't have more than 100 arguments
    # TODO: for speed, maybe compute these offsets and sizes back in the Compiler
    %pointers = uninitialized StaticArray(Pointer(Void), 100)
    %offset = 0
    %i = %target_def.args.size - 1
    %target_def.args.reverse_each do |arg|
      %arg_bytesize = sizeof_type(arg.type)
      %pointers[%i] = (stack - %offset - %arg_bytesize).as(Void*)
      %offset -= %arg_bytesize
      %i -= 1
    end
    %cif.call(%fn, %pointers.to_unsafe, stack.as(Void*))

    %return_bytesize = sizeof_type(%target_def.type)

    (stack + %offset).move_from(stack, %return_bytesize)
    stack = stack + %offset + %return_bytesize
  end

  private macro leave(size)
    if @call_stack.size == 1
      @call_stack.pop
      return_value = Pointer(UInt8).malloc({{size}})
      return_value.copy_from(stack_bottom_after_local_vars, {{size}})
      stack -= {{size}}
      break
    else
      # Remember the point the stack reached
      old_stack = stack
      %previous_call_frame = @call_stack.pop
      %call_frame = @call_stack.last

      # Restore ip, instructions and stack bottom
      instructions = %call_frame.compiled_def.instructions
      nodes = %call_frame.compiled_def.nodes
      ip = %call_frame.ip
      stack_bottom = %call_frame.stack_bottom
      stack = %call_frame.stack

      # Copy the return value to a constant, if the frame was for a constant
      if %previous_call_frame.constant_index != -1
        (old_stack - {{size}}).copy_to(@constants + %previous_call_frame.constant_index + 1, {{size}})
      end

      # Ccopy the return value
      stack_move_from(old_stack - {{size}}, {{size}})

      # TODO: clean up stack
    end
  end

  private macro set_ip(ip)
    ip = instructions.to_unsafe + {{ip}}
  end

  private macro set_local_var(index, size)
    stack_move_to(stack_bottom + {{index}}, {{size}})
  end

  private macro get_local_var(index, size)
    stack_move_from(stack_bottom + {{index}}, {{size}})
  end

  private macro get_local_var_pointer(index)
    stack_bottom + {{index}}
  end

  private macro get_ivar_pointer(offset)
    self_class_pointer + offset
  end

  private macro get_const(index, size)
    # TODO: make this atomic
    %initialized = @constants[{{index}}]
    if %initialized == 1_u8
      stack_move_from(@constants + {{index}} + 1, {{size}})
    else
      @constants[{{index}}] = 1_u8
      %compiled_def = @context.constants.index_to_compiled_def({{index}})
      call(%compiled_def, constant_index: {{index}})
    end
  end

  private macro pry
    @pry = true
  end

  private macro next_instruction(t)
    value = ip.as({{t}}*).value
    ip += sizeof({{t}})
    value
  end

  private macro self_class_pointer
    get_local_var_pointer(0).as(Pointer(Pointer(UInt8))).value
  end

  private macro stack_pop(t)
    value = (stack - sizeof({{t}})).as({{t}}*).value
    stack_shrink_by(sizeof({{t}}))
    value
  end

  private macro stack_push(value)
    %temp = {{value}}
    stack.as(Pointer(typeof({{value}}))).value = %temp
    stack_grow_by(sizeof(typeof({{value}})))
  end

  private macro stack_copy_to(pointer, size)
    (stack - {{size}}).copy_to({{pointer}}, {{size}})
  end

  private macro stack_move_to(pointer, size)
    stack_copy_to({{pointer}}, {{size}})
    stack_shrink_by({{size}})
  end

  private macro stack_move_from(pointer, size)
    stack.copy_from({{pointer}}, {{size}})
    stack_grow_by({{size}})
  end

  private macro stack_grow_by(size)
    stack += {{size}}
  end

  private macro stack_shrink_by(size)
    stack -= {{size}}
  end

  private def sizeof_type(type : Type) : Int32
    program.size_of(type.sizeof_type).to_i32
  end

  private def type_from_type_id(id : Int32) : Type
    program.llvm_id.type_from_id(id)
  end

  private macro type_id_bytesize
    8
  end

  def define_primitives
    exception = program.types["Exception"]?
    if exception
      call_stack = exception.types["CallStack"]?
      if call_stack
        unwind_signature = CallSignature.new(
          name: "unwind",
          arg_types: [] of Type,
          block: nil,
          named_args: nil,
        )

        matches = call_stack.metaclass.lookup_matches(unwind_signature)
        unless matches.empty?
          unwind_def = matches.matches.not_nil!.first.def
          unwind_def.body = Primitive.new("repl_call_stack_unwind")
        end
      end

      raise_without_backtrace_signature = CallSignature.new(
        name: "raise_without_backtrace",
        arg_types: [exception] of Type,
        block: nil,
        named_args: nil,
      )

      matches = program.lookup_matches(raise_without_backtrace_signature)
      unless matches.empty?
        raise_without_backtrace_def = matches.matches.not_nil!.first.def
        raise_without_backtrace_def.body = Primitive.new("repl_raise_without_backtrace")
      end
    end

    lib_instrinsics = program.types["LibIntrinsics"]?
    if lib_instrinsics
      %w(memcpy memmove memset debugtrap).each do |function_name|
        match = lib_instrinsics.lookup_first_def(function_name, false)
        match.body = Primitive.new("repl_intrinsics_#{function_name}") if match
      end
    end

    lib_m = program.types["LibM"]?
    if lib_m
      %w[32 64].each do |bits|
        %w[ceil cos exp exp2 log log2 log10].each do |function_name|
          match = lib_m.lookup_first_def("#{function_name}_f#{bits}", false)
          match.body = Primitive.new("repl_#{function_name}_f#{bits}") if match
        end
      end
    end
  end

  private def define_primitive_raise_without_backtrace
  end

  private def program
    @context.program
  end

  private def pry(ip, instructions, nodes, stack_bottom)
    call_frame = @call_stack.last
    compiled_def = call_frame.compiled_def
    a_def = compiled_def.def
    local_vars = compiled_def.local_vars
    offset = (ip - instructions.to_unsafe).to_i32
    node = nodes[offset]?
    pry_node = @pry_node
    if node && (location = node.location) && different_node_line?(node, pry_node)
      whereami(a_def, location)

      interpreter = Interpreter.new(self, compiled_def, stack_bottom)

      while @pry
        print "pry> "
        line = gets
        unless line
          @pry = false
          @pry_node = nil
          break
        end

        case line
        when "continue"
          @pry = false
          @pry_node = nil
          break
        when "next", "step"
          @pry_node = node
          break
        when "whereami"
          whereami(a_def, location)
          next
        end

        begin
          parser = Parser.new(
            line,
            string_pool: @context.program.string_pool,
            def_vars: [local_vars.names.to_set]
          )
          line_node = parser.parse

          value = interpreter.interpret(line_node)
          puts value
        rescue ex : Crystal::CodeError
          ex.color = true
          ex.error_trace = true
          puts ex
          next
        rescue ex : Exception
          ex.inspect_with_backtrace(STDOUT)
          next
        end
      end
    end
  end

  private def whereami(a_def : Def, location : Location)
    puts "From: #{location} #{a_def.owner}##{a_def.name}:"
    puts
    filename = location.filename
    case filename
    when String
      lines = File.read_lines(filename)

      {location.line_number - 5, 1}.max.upto({location.line_number + 5, lines.size}.min) do |line_number|
        line = lines[line_number - 1]
        if line_number == location.line_number
          print " => "
        else
          print "    "
        end
        print line_number.colorize.blue
        print ": "
        puts line
      end
      puts
    end
  end

  private def different_node_line?(node : ASTNode, previous_node : ASTNode?)
    return true unless previous_node
    return true if node.location.not_nil!.filename != previous_node.location.not_nil!.filename

    node.location.not_nil!.line_number != previous_node.location.not_nil!.line_number
  end
end
