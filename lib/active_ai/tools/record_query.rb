require "json"

module ActiveAI
  module Tools
    # Read-only database access for the model, through ActiveRecord only — never SQL.
    #
    # The app hands the tool the relation of roots the current user may reach, and
    # an optional context for ActiveAI::Readable `if:` conditions. The model picks a
    # root by id, one declared collection association of it, and declared scopes to
    # narrow that association; it gets back only declared attributes.
    #
    #   def instance_tools
    #     [ActiveAI::Tools::RecordQuery.new(roots: @user.accounts, context: @user)]
    #   end
    #
    # The root boundary is the app's: a root id outside `roots` is "not found".
    # Everything runs while ActiveRecord prevents writes, and on PostgreSQL inside a
    # READ ONLY transaction with a statement timeout.
    class RecordQuery < ActiveAI::Tool::Base
      DEFAULT_LIMIT        = 50
      MAX_LIMIT            = 200
      STATEMENT_TIMEOUT_MS = 5_000

      tool_name "query_records"
      description "Read records from the application's database. Call with only root_id to list " \
                  "what can be read under that root: each association with its scopes and returned " \
                  "attributes. Then call with an association, and optionally scopes to narrow it."

      param :root_id,     type: :string,  description: "Id of the record to read under"
      param :association, type: :string,  description: "Association to read; omit to list what is readable", required: false
      param :scopes,      type: :array,   description: "Scopes to apply in order, each { name, args }", required: false,
                          items: {
                            type: "object",
                            properties: {
                              name: { type: "string" },
                              args: { type: "array", items: { type: %w[string number boolean] } }
                            },
                            required: %w[name]
                          }
      param :limit,       type: :integer, description: "Maximum records to return (default #{DEFAULT_LIMIT})", required: false

      def initialize(roots:, context: nil, max_limit: MAX_LIMIT, statement_timeout_ms: STATEMENT_TIMEOUT_MS)
        unless roots.is_a?(ActiveRecord::Relation)
          raise ActiveAI::ConfigurationError, "#{self.class.name} roots: must be an ActiveRecord::Relation, got #{roots.class}"
        end

        @roots                = roots
        @context              = context
        @max_limit            = max_limit
        @statement_timeout_ms = statement_timeout_ms
      end

      # Fires record_query.active_ai with what was asked, for whom (context:), and the
      # outcome — rows returned, truncation, or the refusal — but never the rows.
      def call(root_id:, association: nil, scopes: [], limit: nil)
        ActiveAI::Instrumentation.instrument("record_query.active_ai", {
          root_class:  @roots.klass.name,
          root_id:     root_id.to_s,
          association: association.presence&.to_s,
          scopes:      Array(scopes),
          limit:       limit,
          context:     @context
        }) do |event|
          result = read(root_id, association, scopes, limit)
          event.merge!(summary(result))
          result.to_json
        end
      end

      private

      def read(root_id, association, scopes, limit)
        read_only do
          root = @roots.find_by(@roots.klass.primary_key => root_id)
          next failure("No #{@roots.klass.model_name.human.downcase} #{root_id}.") unless root

          association.blank? ? catalog(root) : query(root, association.to_s, Array(scopes), limit)
        end
      rescue ActiveRecord::ReadOnlyError
        failure("That query tried to write; this tool only reads.")
      rescue ActiveRecord::QueryCanceled
        failure("That query took longer than #{@statement_timeout_ms} ms and was cancelled. Narrow it with scopes.")
      rescue ActiveRecord::StatementInvalid => error
        failure("The database rejected that query: #{(error.cause || error).message.lines.first.to_s.strip}")
      end

      def summary(result)
        if result.key?(:error)
          { outcome: :refused, reason: result[:error] }
        elsif result.key?(:records)
          { outcome: :read, returned: result[:returned], truncated: result[:truncated] }
        else
          { outcome: :catalog, associations: result[:associations].map { |entry| entry[:association] } }
        end
      end

      def catalog(root)
        associations = readable_associations(root).map do |name|
          model = target_model(root.class, name)
          {
            association: name.to_s,
            scopes:      model.ai_readable_scopes.map { |scope, about| { name: scope.to_s, description: about }.compact },
            attributes:  model.ai_readable_attributes.map(&:to_s)
          }
        end

        { root: root_label(root), associations: associations }
      end

      def query(root, association, scopes, limit)
        unless readable_associations(root).include?(association.to_sym)
          return failure("#{association} is not readable. Call with only root_id to list what is.")
        end

        model    = target_model(root.class, association.to_sym)
        bound    = root.association(association.to_sym).scope
        relation = bound

        scopes.each do |entry|
          entry = entry.is_a?(Hash) ? entry.stringify_keys : { "name" => entry.to_s }
          name  = entry["name"].to_s
          return failure("#{name} is not a readable scope on #{association}.") unless model.ai_readable_scopes.key?(name.to_sym)

          begin
            result = relation.public_send(name, *Array(entry["args"]))
          rescue ArgumentError => error
            return failure("#{name}: #{error.message}")
          end
          unless result.is_a?(ActiveRecord::Relation) && result.klass == model
            raise ActiveAI::ConfigurationError, "#{model.name}.#{name} is declared ai_readable but did not return a #{model.name} relation"
          end

          relation = result
        end

        # A declared scope may call unscoped or rewrite a condition; re-applying the
        # root's association as a subquery keeps the result inside the root anyway.
        relation = relation.where(model.primary_key => bound.select(model.primary_key))
        records(model, relation, limit)
      end

      def records(model, relation, limit)
        limit   = (limit.presence || DEFAULT_LIMIT).to_i.clamp(1, @max_limit)
        fetched = relation.limit(limit + 1).to_a
        rows    = fetched.first(limit).map do |record|
          model.ai_readable_attributes.to_h { |attribute| [attribute, record.public_send(attribute)] }
        end

        { records: rows, returned: rows.size, truncated: fetched.size > limit }
      end

      def readable_associations(root)
        root.class.ai_readable_associations.keys.select do |name|
          root.class.ai_readable_association?(name, root, @context)
        end
      end

      def target_model(owner, name)
        reflection = owner.reflect_on_association(name)
        unless reflection&.collection?
          raise ActiveAI::ConfigurationError, "#{owner.name} declares ai_readable association #{name}, which is not a has_many"
        end

        model = reflection.klass
        unless model.include?(ActiveAI::Readable)
          raise ActiveAI::ConfigurationError, "#{model.name} is reachable through #{owner.name}##{name} but does not include ActiveAI::Readable"
        end
        unless model.primary_key.is_a?(String)
          raise ActiveAI::ConfigurationError, "#{model.name} has a composite primary key; #{self.class.name} needs a single-column key"
        end

        model
      end

      def read_only(&)
        ActiveRecord::Base.while_preventing_writes do
          connection = @roots.klass.connection
          if connection.adapter_name.match?(/postg/i) && !connection.transaction_open?
            connection.transaction do
              connection.execute("SET TRANSACTION READ ONLY")
              connection.execute("SET LOCAL statement_timeout = #{@statement_timeout_ms.to_i}")
              yield
            end
          else
            yield
          end
        end
      end

      def root_label(root)
        "#{root.class.name} #{root.id}"
      end

      def failure(message)
        { error: message }
      end
    end
  end
end
