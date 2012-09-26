require 'yaml'
require 'pathname'
require 'forwardable'

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
        rules.mode = mode
      end

      root.prune!
      root
    end

    extend Forwardable
    def_delegator :@kids, :[]

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

    # Delete children who have the same mode as their closest ancestor.
    def prune!(parent_mode = nil)
      parent_mode = self.mode if self.mode

      @kids.delete_if { |_, kid| kid.mode == parent_mode } unless parent_mode.nil?
      @kids.values.each { |kid| kid.prune!(parent_mode) }
    end
  end
end
