require 'yaml'
require 'pathname'
require 'forwardable'
require 'tempfile'

module WMB
  class Rules
    def self.load_file(file)
      parse(YAML.load_file(file))
    end

    def self.parse(hash)
      root = Rules.new(Pathname.new('/'))

      hash.each do |raw_path, mode|
        path = Pathname.new(raw_path)
        rules = root
        path.each_filename do |part|
          path  = rules.path + part
          rules = (rules[part] ||= Rules.new(path))
        end
        rules.mode = mode.to_sym
      end

      root.prune!
      root
    end

    extend Forwardable
    def_delegator :@kids, :[]
    def_delegator :@kids, :each
    def_delegator :@kids, :empty?

    attr_accessor :mode
    attr_reader :path

    def initialize(path)
      @path = path
      @kids = {}
    end

    def []=(name, rules)
      raise "Not a Rules object: #{rules.inspect}" unless rules.kind_of?(self.class)
      @kids[name] = rules
    end

    def watch?
      @mode == :watch
    end

    def unwatch?
      @mode && !watch?
    end

    def blocks_watch?
      unwatch? && @kids.empty?
    end

    # Delete children who have the same mode as their closest ancestor.
    def prune!(parent_mode = nil)
      parent_mode = self.mode if self.mode

      @kids.delete_if { |_, kid| kid.mode == parent_mode } unless parent_mode.nil?
      @kids.values.each { |kid| kid.prune!(parent_mode) }
    end
  end

  class Watcher
    class Node
      def self.create(path)
        stat = path.stat
        cls = (stat.directory? ? DirNode : FileNode)
        cls.new(path)
      rescue Errno::ENOENT
        NilNode.new(path)
      end

      def self.root
        DirNode.new(Pathname.new('/'))
      end

      def initialize(path)
        @path = path
      end

      def changes(other)
        if other.class != self.class
          ["became a #{other.description(false)}"]
        else
          local_changes(other)
        end
      end
    end

    class NilNode < Node
      def watch(rules); end
      def travel(rules); end

      def nil?
        true
      end
    end

    class FileNode < Node
      attr_reader :size, :mtime

      def watch(rules)
        stat = @path.stat
        @size  = stat.size
        @mtime = stat.mtime
      end

      def travel(rules)
        # nothing to do
      end

      def count_recursive
        1
      end

      def keys
        []
      end

      def description(full = true)
        path = " #{@path}" if full
        "file#{path}"
      end

      def local_changes(other)
        output = []
        if @size != other.size
          output << "size changed: #{@size} -> #{other.size}" if @size != other.size
        else
          output << "modified" if @mtime != other.mtime
        end
        output
      end
    end

    class DirNode < Node
      extend Forwardable
      def_delegator :@kids, :[]
      def_delegator :@kids, :keys

      def initialize(path)
        super(path)
        @kids = {}
      end

      def description(full = true)
        path = " #{@path}" if full
        "directory#{path} with #{count_recursive} children"
      end

      def count_recursive
        @kids.values.inject(1) { |sum, kid| sum + kid.count_recursive }
      end

      def local_changes(other)
        []
      end

      def travel(rules)
        rules.each do |path, rule|
          if !rule.blocks_watch?
            kid = Node.create(rule.path)
            if rule.watch?
              kid.watch(rule)
            else
              kid.travel(rule)
            end
            @kids[path] = kid unless kid.nil?
          end
        end
      end

      def watch(rules)
        @path.each_child do |subpath|
          key  = subpath.basename.to_s
          rule = rules[key] if rules

          kid = Node.create(subpath)
          if !rule
            kid.watch(nil)
          elsif rule.unwatch?
            if rule.empty?
              kid = nil
            else
              kid.travel(rule)
            end
          else
            kid.watch(rule)
          end

          @kids[key] = kid unless kid.nil?
        end
      end
    end

    def initialize(rules)
      @rules = rules
      @db = Node.root
    end

    def load(file)
      @db = YAML.load_file(file)
    end

    def save(file)
      fh = Tempfile.open(File.basename(file), File.dirname(file))
      fh.puts @db.to_yaml
      fh.close
      File.rename(fh.path, file)
    ensure
      fh.close! if fh
    end

    def run
      new_db = Node.root
      new_db.travel(@rules)

      changes = report(@db, new_db)
      puts *changes unless changes.empty?

      @db = new_db
    end

    private

    def report(db1, db2)
      output = []
      (db1.keys | db2.keys).each do |key|
        node1 = db1[key]
        node2 = db2[key]

        if !node1 && node2
          output << "Added: #{node2.description}"
        elsif node1 && !node2
          output << "Deleted: #{node1.description}"
        else
          output += node1.changes(node2).map {|out| "Changed: #{node1.description} #{out}"}
          output += report(node1, node2)
        end
      end

      output
    end
  end
end
