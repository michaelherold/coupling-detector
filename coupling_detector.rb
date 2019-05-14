require "csv"
require "pry"
require "rugged"
require "stackprof"

class Graph
	extend Forwardable
	include Enumerable

	def initialize
		@nodes = []
	end

	def_delegators :nodes, :each, :sort_by!

	def add(filename, edges)
		node = nodes.find(-> { Node.new(filename) }) { |n| n.for?(filename) }

		edges.each { |edge| node.add_edge(edge) }
		unless node.in?(self)
			node.graph = self
			nodes << node
		end
	end

	def to_adjacency_matrix
		files = to_node_list

		map { |node| files.map { |file| node.connections_to(file) } }
			.tap { |table| table.unshift(files) }
	end

	def to_node_list
		map(&:filename)
	end

	def to_edge_list
		map(&:to_edge_list)
	end

	private

	attr_reader :nodes
end

class Node
	def initialize(filename, graph = nil)
		@filename = filename
		@graph = graph
		@edges = Hash.new { |h, k| h[k] = 0 }
	end

	attr_reader :filename
	attr_accessor :graph

	def add_edge(filename)
		edges[filename] += 1
	end

	def connections_to(file)
		if edge?(file)
			edges[file]
		else
			0
		end
	end

	def edge?(file)
		edges.key?(file)
	end

	def for?(file)
		filename == file
	end

	def in?(graph)
		self.graph == graph
	end

	def to_edge_list
		edges.keys.map { |edge| [filename, edge] }
	end

	private

	attr_reader :edges
end

def edges_from_diff(diff)
	diff
		.each_delta
		.map { |delta| delta.new_file[:path] }
		.reject { |edge| edge =~ REJECTED_PATHS }
end

def with_profiling(name, &block)
	StackProf.run(mode: :cpu, out: "#{name}.dump", raw: true, &block)
end

def with_timing(action)
	print "#{action} ".ljust(30, ".")
	start_time = Time.now
	yield if block_given?
	puts format(" Finished. Took %0.2f seconds", Time.now - start_time)
end

start_time = Time.now
graph = Graph.new
repo = Rugged::Repository.discover(__dir__)

PARTIAL_REMAP = /(?<remap>\{((?<old>[^\s]+)? => (?<new>[^\s]+)?)\})/
FULL_REMAP = /(?<remap>((?<old>[^\s]+)? => (?<new>[^\s]+)?))/
REJECTED_PATHS = /(assets|design-system|views|db\/|\.yml|spec|config\/|gitignore|Gemfile)/

with_profiling("building-graph") do
	with_timing("Building graph") do
		repo.walk(repo.head.target.oid).take(1_000).each_cons(2) do |commit, parent|
			diff = commit.diff(parent)
			edges = edges_from_diff(diff)

			edges.each_with_index do |edge, index|
				graph.add(edge, edges[index..-1].reject { |e| e == edge })
			end
		end
	end
end

with_timing("Sorting graph") do
	graph.sort_by!(&:filename)
end

with_timing("Writing node list") do
	CSV.open("node_list.csv", "wb") do |csv|
		csv << %w(file)
		graph.to_node_list.each { |node| csv << [node] }
	end
end

with_timing("Writing edge list") do
	CSV.open("edge_list.csv", "wb") do |csv|
		csv << %w(from to)
		graph.to_edge_list.each { |edges| edges.map { |row| csv << row } }
	end
end

with_timing("Writing adjacency matrix") do
	CSV.open("adjacency_matrix.csv", "wb") do |csv|
		graph.to_adjacency_matrix.each { |row| csv << row }
	end
end

puts format("\nTook %0.2f seconds", Time.now - start_time)
