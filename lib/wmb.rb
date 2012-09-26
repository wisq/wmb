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
    end

    class NilNode < Node
      def watch(rules); end
      def travel(rules); end

      def nil?
        true
      end
    end

    class FileNode < Node
      def watch(rules)
        stat = @path.stat
        @size  = stat.size
        @mtime = stat.mtime
      end

      def travel(rules)
        # nothing to do
      end
    end

    class DirNode < Node
      def initialize(path)
        super(path)
        @kids = {}
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
    end

    def load(file)
      @db = YAML.load_file(file)
    end

    def save(file)
      fh = Tempfile.open(File.basename(file), File.dirname(file))
      fh.puts @db.to_yaml
      fh.close
      fh.rename(file)
    ensure
      fh.close! if fh
    end

    def run
      new_db = Node.root
      new_db.travel(@rules)
      # prepare a change report here
      pp new_db
      @db = new_db
    end
  end
end
