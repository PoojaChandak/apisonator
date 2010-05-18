module ThreeScale
  module Backend
    class Metric
      autoload :Collection, '3scale/backend/metric/collection'

      include Storable

      attr_accessor :service_id
      attr_accessor :id
      attr_accessor :parent_id
      attr_accessor :name
      
      # Load all metrics associated to the given service id.
      def self.load_all(service_id)
        Collection.new(service_id)
      end

      def self.load_all_ids(service_id)
        storage.smembers(encode_key("metrics/service_id:#{service_id}/ids"))
      end

      def self.load_name(service_id, id)
        storage.get(encode_key("metric/service_id:#{service_id}/id:#{id}/name"))
      end

      def self.save(attributes)
        metrics = new(attributes)
        metrics.save
        metrics
      end

      def save
        storage.set(encode_key("metric/service_id:#{service_id}/name:#{name}/id"), id)
        storage.set(encode_key("metric/service_id:#{service_id}/id:#{id}/name"), name)
        storage.set(encode_key("metric/service_id:#{service_id}/id:#{id}/parent_id"), parent_id) if parent_id

        storage.sadd(encode_key("metrics/service_id:#{service_id}/ids"), id)

        save_children
      end

      def children
        @children ||= []
      end

      attr_writer :children

      private

      def save_children
        children.each do |child|
          child.service_id = service_id
          child.parent_id  = id
          child.save
        end
      end
    end
  end
end