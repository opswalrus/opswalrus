module OpsWalrus
  module Traversable
    # the yield block visits the node and returns children that should be visited
    def pre_order_traverse(root, observed_nodes = Set.new, &visit_fn_block)
      # there shouldn't be any cycles in a tree, but we're going to make sure!
      return if observed_nodes.include?(root)
      observed_nodes << root

      children = visit_fn_block.call(root)
      children&.each do |child_node|
        pre_order_traverse(child_node, observed_nodes, &visit_fn_block)
      end
    end
  end
end
