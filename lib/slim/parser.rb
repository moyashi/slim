module Slim
  # Parses Slim code and transforms it to a Temple expression
  # @api private
  class Parser
    include Temple::Mixins::Options

    set_default_options :tabsize  => 4,
                        :encoding => 'utf-8',
                        :default_tag => 'div'

    class SyntaxError < StandardError
      attr_reader :error, :file, :line, :lineno, :column

      def initialize(error, file, line, lineno, column)
        @error = error
        @file = file || '(__TEMPLATE__)'
        @line = line.to_s
        @lineno = lineno
        @column = column
      end

      def to_s
        line = @line.strip
        column = @column + line.size - @line.size
        %{#{error}
  #{file}, Line #{lineno}
    #{line}
    #{' ' * column}^
}
      end
    end

    def initialize(options = {})
      super
      @tab = ' ' * @options[:tabsize]
    end

    # Compile string to Temple expression
    #
    # @param [String] str Slim code
    # @return [Array] Temple expression representing the code]]
    def call(str)
      # Set string encoding if option is set
      if options[:encoding] && str.respond_to?(:encoding)
        old_enc = str.encoding
        str = str.dup if str.frozen?
        str.force_encoding(options[:encoding])
        # Fall back to old encoding if new encoding is invalid
        str.force_encoding(old_enc) unless str.valid_encoding?
      end

      result = [:multi]
      reset(str.split($/), [result])

      parse_line while next_line

      reset
      result
    end

    private

    DELIMITERS = {
      '(' => ')',
      '[' => ']',
      '{' => '}',
    }.freeze

    ATTR_SHORTCUT = {
      '#' => 'id',
      '.' => 'class',
    }.freeze

    DELIMITER_REGEX = /\A[\(\[\{]/
    ATTR_NAME_REGEX = '\A\s*(\w[:\w-]*)'
    CLASS_ID_REGEX = /\A(#|\.)(\w[\w-]*\w|\w+)/
    TAG_REGEX = /\A([#\.]|\w[\w:-]*\w|\w+)/

    def reset(lines = nil, stacks = nil)
      # Since you can indent however you like in Slim, we need to keep a list
      # of how deeply indented you are. For instance, in a template like this:
      #
      #   doctype       # 0 spaces
      #   html          # 0 spaces
      #    head         # 1 space
      #       title     # 4 spaces
      #
      # indents will then contain [0, 1, 4] (when it's processing the last line.)
      #
      # We uses this information to figure out how many steps we must "jump"
      # out when we see an de-indented line.
      @indents = [0]

      # Whenever we want to output something, we'll *always* output it to the
      # last stack in this array. So when there's a line that expects
      # indentation, we simply push a new stack onto this array. When it
      # processes the next line, the content will then be outputted into that
      # stack.
      @stacks = stacks

      @lineno = 0
      @lines = lines
      @line = @orig_line = nil
    end

    def next_line
      if @lines.empty?
        @orig_line = @line = nil
      else
        @orig_line = @lines.shift
        @lineno += 1
        @line = @orig_line.dup
      end
    end

    def get_indent(line)
      # Figure out the indentation. Kinda ugly/slow way to support tabs,
      # but remember that this is only done at parsing time.
      line[/\A[ \t]*/].gsub("\t", @tab).size
    end

    def parse_line
      if @line =~ /\A\s*\Z/
        @stacks.last << [:newline]
        return
      end

      indent = get_indent(@line)

      # Remove the indentation
      @line.lstrip!

      # If there's more stacks than indents, it means that the previous
      # line is expecting this line to be indented.
      expecting_indentation = @stacks.size > @indents.size

      if indent > @indents.last
        # This line was actually indented, so we'll have to check if it was
        # supposed to be indented or not.
        syntax_error!('Unexpected indentation') unless expecting_indentation

        @indents << indent
      else
        # This line was *not* indented more than the line before,
        # so we'll just forget about the stack that the previous line pushed.
        @stacks.pop if expecting_indentation

        # This line was deindented.
        # Now we're have to go through the all the indents and figure out
        # how many levels we've deindented.
        while indent < @indents.last
          @indents.pop
          @stacks.pop
        end

        # This line's indentation happens lie "between" two other line's
        # indentation:
        #
        #   hello
        #       world
        #     this      # <- This should not be possible!
        syntax_error!('Malformed indentation') if indent != @indents.last
      end

      parse_line_indicators
    end

    def parse_line_indicators
      case @line
      when /\A\//
        # Found a comment block.
        if @line =~ %r{\A/!( ?)(.*)\Z}
          # HTML comment
          @stacks.last << [:html, :comment, parse_text_block($2, @indents.last + $1.size + 2)]
        elsif @line =~ %r{\A/\[\s*(.*?)\s*\]\s*\Z}
          # HTML conditional comment
          block = [:multi]
          @stacks.last << [:slim, :condcomment, $1, block]
          @stacks << block
        else
          # Slim comment
          parse_comment_block
        end
      when /\A([\|'])( ?)(.*)\Z/
        # Found a text block.
        trailing_ws = $1 == "'"
        @stacks.last << parse_text_block($3, @indents.last + $2.size + 1)
        @stacks.last << [:static, ' '] if trailing_ws
      when /\A-/
        # Found a code block.
        # We expect the line to be broken or the next line to be indented.
        block = [:multi]
        @line.slice!(0)
        @stacks.last << [:slim, :control, parse_broken_line, block]
        @stacks << block
      when /\A=/
        # Found an output block.
        # We expect the line to be broken or the next line to be indented.
        @line =~ /\A=(=?)('?)/
        @line = $'
        block = [:multi]
        @stacks.last << [:slim, :output, $1.empty?, parse_broken_line, block]
        @stacks.last << [:static, ' '] unless $2.empty?
        @stacks << block
      when /\A(\w+):\s*\Z/
        # Embedded template detected. It is treated as block.
        @stacks.last << [:slim, :embedded, $1, parse_text_block]
      when /\Adoctype\s+/i
        # Found doctype declaration
        @stacks.last << [:html, :doctype, $'.strip]
      when TAG_REGEX
        # Found a HTML tag.
        parse_tag($&)
      else
        syntax_error! 'Unknown line indicator'
      end
      @stacks.last << [:newline]
    end

    def parse_comment_block
      while !@lines.empty? && (@lines.first =~ /\A\s*\Z/ || get_indent(@lines.first) > @indents.last)
        next_line
        @stacks.last << [:newline]
      end
    end

    def parse_text_block(first_line = nil, text_indent = nil)
      result = [:multi]
      if !first_line || first_line.empty?
        text_indent = nil
      else
        result << [:slim, :interpolate, first_line]
      end

      empty_lines = 0
      until @lines.empty?
        if @lines.first =~ /\A\s*\Z/
          next_line
          result << [:newline]
          empty_lines += 1 if text_indent
        else
          indent = get_indent(@lines.first)
          break if indent <= @indents.last

          if empty_lines > 0
            result << [:slim, :interpolate, "\n" * empty_lines]
            empty_lines = 0
          end

          next_line
          @line.lstrip!

          # The text block lines must be at least indented
          # as deep as the first line.
          offset = text_indent ? indent - text_indent : 0
          syntax_error!('Unexpected text indentation') if offset < 0

          result << [:newline] << [:slim, :interpolate, (text_indent ? "\n" : '') + (' ' * offset) + @line]

          # The indentation of first line of the text block
          # determines the text base indentation.
          text_indent ||= indent
        end
      end
      result
    end

    def parse_broken_line
      broken_line = @line.strip
      while broken_line =~ /[,\\]\Z/
        next_line || syntax_error!('Unexpected end of file')
        broken_line << "\n" << @line.strip
      end
      broken_line
    end

    def parse_tag(tag)
      if tag == '#' || tag == '.'
        tag = options[:default_tag]
      else
        @line.slice!(0, tag.size)
      end

      tag = [:html, :tag, tag, parse_attributes]
      @stacks.last << tag

      case @line
      when /\A\s*:\s*/
        # Block expansion
        @line = $'
        (@line =~ TAG_REGEX) || syntax_error!('Expected tag')
        content = [:multi]
        tag << content
        i = @stacks.size
        @stacks << content
        parse_tag($1)
        @stacks.delete_at(i)
      when /\A\s*=(=?)('?)/
        # Handle output code
        block = [:multi]
        @line = $'
        content = [:slim, :output, $1 != '=', parse_broken_line, block]
        tag << content
        @stacks.last << [:static, ' '] unless $2.empty?
        @stacks << block
      when /\A\s*\//
        # Closed tag. Do nothing
      when /\A\s*\Z/
        # Empty content
        content = [:multi]
        tag << content
        @stacks << content
      when /\A( ?)(.*)\Z/
        # Text content
        tag << parse_text_block($2, @orig_line.size - @line.size + $1.size)
      end
    end

    def parse_attributes
      attributes = [:html, :attrs]

      # Find any literal class/id attributes
      while @line =~ CLASS_ID_REGEX
        # The class/id attribute is :static instead of :slim :text,
        # because we don't want text interpolation in .class or #id shortcut
        attributes << [:html, :attr, ATTR_SHORTCUT[$1], [:static, $2]]
        @line = $'
      end

      # Check to see if there is a delimiter right after the tag name
      delimiter = nil
      if @line =~ DELIMITER_REGEX
        delimiter = DELIMITERS[$&]
        @line.slice!(0)
      end

      orig_line = @orig_line
      lineno = @lineno
      while true
        # Parse attributes
        attr_regex = delimiter ? /#{ATTR_NAME_REGEX}(=|\s|(?=#{Regexp.escape delimiter}))/ : /#{ATTR_NAME_REGEX}=/
        while @line =~ attr_regex
          @line = $'
          name = $1
          if delimiter && $2 != '='
            attributes << [:slim, :attr, name, false, 'true']
          elsif @line =~ /\A["']/
            # Value is quoted (static)
            @line = $'
            attributes << [:html, :attr, name, [:slim, :interpolate, parse_quoted_attribute($&)]]
          else
            # Value is ruby code
            escape = @line[0] != ?=
            @line.slice!(0) unless escape
            attributes << [:slim, :attr, name, escape, parse_ruby_attribute(delimiter)]
          end
        end

        # No ending delimiter, attribute end
        break unless delimiter

        # Find ending delimiter
        if @line =~ /\A\s*#{Regexp.escape delimiter}/
          @line = $'
          break
        end

        # Found something where an attribute should be
        @line.lstrip!
        syntax_error!('Expected attribute') unless @line.empty?

        # Attributes span multiple lines
        @stacks.last << [:newline]
        next_line || syntax_error!("Expected closing delimiter #{delimiter}",
                                   :orig_line => orig_line,
                                   :lineno => lineno,
                                   :column => orig_line.size)
      end

      attributes
    end

    def parse_ruby_attribute(outer_delimiter)
      value, count, delimiter, close_delimiter = '', 0, nil, nil

      # Attribute ends with space or attribute delimiter
      end_regex = /\A[\s#{Regexp.escape outer_delimiter.to_s}]/

      until @line.empty? || (count == 0 && @line =~ end_regex)
        if count > 0
          if @line[0] == delimiter[0]
            count += 1
          elsif @line[0] == close_delimiter[0]
            count -= 1
          end
        elsif @line =~ DELIMITER_REGEX
          count = 1
          delimiter, close_delimiter = $&, DELIMITERS[$&]
        end
        value << @line.slice!(0)
      end

      syntax_error!("Expected closing attribute delimiter #{close_delimiter}") if count != 0
      syntax_error!('Invalid empty attribute') if value.empty?

      # Remove attribute wrapper which doesn't belong to the ruby code
      # e.g id=[hash[:a] + hash[:b]]
      value = value[1..-2] if value =~ DELIMITER_REGEX &&
        DELIMITERS[$&] == value[-1, 1]

      value
    end

    def parse_quoted_attribute(quote)
      value, count = '', 0

      until @line.empty? || (count == 0 && @line[0] == quote[0])
        if count > 0
          if @line[0] == ?{
            count += 1
          elsif @line[0] == ?}
            count -= 1
          end
        elsif @line =~ /\A#\{/
          value << @line.slice!(0)
          count = 1
        end
        value << @line.slice!(0)
      end

      syntax_error!("Expected closing brace }") if count != 0
      @line.slice!(0)
      value
    end

    # Helper for raising exceptions
    def syntax_error!(message, args = {})
      args[:orig_line] ||= @orig_line
      args[:line] ||= @line
      args[:lineno] ||= @lineno
      args[:column] ||= args[:orig_line] && args[:line] ?
                        args[:orig_line].size - args[:line].size : 0
      raise SyntaxError.new(message, options[:file],
                            args[:orig_line], args[:lineno], args[:column])
    end
  end
end
