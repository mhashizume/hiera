require 'hiera/util'
require 'hiera/recursive_guard'

begin
  require 'deep_merge'
rescue LoadError
end

class Hiera
  module Backend
    INTERPOLATION = /%\{([^\}]*)\}/
    SCOPE_INTERPOLATION = /%\{scope\(['"]([^\}]*)["']\)\}/
    HIERA_INTERPOLATION = /%\{hiera\(['"]([^\}]*)["']\)\}/
    INTERPOLATION_TYPE = /^([^\(]+)\(/

    class << self
      # Data lives in /var/lib/hiera by default.  If a backend
      # supplies a datadir in the config it will be used and
      # subject to variable expansion based on scope
      def datadir(backend, scope)
        backend = backend.to_sym
        default = Hiera::Util.var_dir

        if Config.include?(backend) && !Config[backend].nil?
          parse_string(Config[backend][:datadir] || default, scope)
        else
          parse_string(default, scope)
        end
      end

      # Finds the path to a datafile based on the Backend#datadir
      # and extension
      #
      # If the file is not found nil is returned
      def datafile(backend, scope, source, extension)
        file = File.join([datadir(backend, scope), "#{source}.#{extension}"])

        unless File.exist?(file)
          Hiera.debug("Cannot find datafile #{file}, skipping")

          return nil
        end

        return file
      end

      # Constructs a list of data sources to search
      #
      # If you give it a specific hierarchy it will just use that
      # else it will use the global configured one, failing that
      # it will just look in the 'common' data source.
      #
      # An override can be supplied that will be pre-pended to the
      # hierarchy.
      #
      # The source names will be subject to variable expansion based
      # on scope
      def datasources(scope, override=nil, hierarchy=nil)
        if hierarchy
          hierarchy = [hierarchy]
        elsif Config.include?(:hierarchy)
          hierarchy = [Config[:hierarchy]].flatten
        else
          hierarchy = ["common"]
        end

        hierarchy.insert(0, override) if override

        hierarchy.flatten.map do |source|
          source = parse_string(source, scope)
          yield(source) unless source == "" or source =~ /(^\/|\/\/|\/$)/
        end
      end

      # Parse a string like <code>'%{foo}'</code> against a supplied
      # scope and additional scope.  If either scope or
      # extra_scope includes the variable 'foo', then it will
      # be replaced else an empty string will be placed.
      #
      # If both scope and extra_data has "foo", then the value in scope
      # will be used.
      #
      # @param data [String] The string to perform substitutions on.
      #   This will not be modified, instead a new string will be returned.
      # @param scope [#[]] The primary source of data for substitutions.
      # @param extra_data [#[]] The secondary source of data for substitutions.
      # @return [String] A copy of the data with all instances of <code>%{...}</code> replaced.
      #
      # @api public
      def parse_string(data, scope, extra_data={})
        interpolate(data, Hiera::RecursiveGuard.new, scope, extra_data)
      end

      def interpolate(data, recurse_guard, scope, extra_data)
        if data =~ INTERPOLATION
          interpolation_variable = $1
          recurse_guard.check(interpolation_variable) do
            interpolate_method = get_interpolation_method(interpolation_variable)
            interpolated_data = send(interpolate_method, data, scope, extra_data)
            interpolate(interpolated_data, recurse_guard, scope, extra_data)
          end
        else
          data
        end
      end
      private :interpolate

      def get_interpolation_method(interpolation_variable)
        case interpolation_variable.match(INTERPOLATION_TYPE)[1]
        when 'hiera' then :hiera_interpolate
        when 'scope' then :scope_interpolate
        end
      end

      def scope_interpolate(data, scope, extra_data)
        data.sub(SCOPE_INTERPOLATION) do
          value = $1
          scope_val = scope[value]
          if scope_val.nil? || scope_val == :undefined
            scope_val = extra_data[value]
          end
          scope_val
        end
      end
      private :scope_interpolate

      def hiera_interpolate(data, scope, extra_data)
        data.sub(HIERA_INTERPOLATION) do
          value = $1
          lookup(value, nil, scope, nil, :priority)
        end
      end
      private :hiera_interpolate

      # Parses a answer received from data files
      #
      # Ultimately it just pass the data through parse_string but
      # it makes some effort to handle arrays of strings as well
      def parse_answer(data, scope, extra_data={})
        if data.is_a?(Numeric) or data.is_a?(TrueClass) or data.is_a?(FalseClass)
          return data
        elsif data.is_a?(String)
          return parse_string(data, scope, extra_data)
        elsif data.is_a?(Hash)
          answer = {}
          data.each_pair do |key, val|
            interpolated_key = parse_string(key, scope, extra_data)
            answer[interpolated_key] = parse_answer(val, scope, extra_data)
          end

          return answer
        elsif data.is_a?(Array)
          answer = []
          data.each do |item|
            answer << parse_answer(item, scope, extra_data)
          end

          return answer
        end
      end

      def resolve_answer(answer, resolution_type)
        case resolution_type
        when :array
          [answer].flatten.uniq.compact
        when :hash
          answer # Hash structure should be preserved
        else
          answer
        end
      end

      # Merges two hashes answers with the configured merge behavior.
      #         :merge_behavior: {:native|:deep|:deeper}
      #
      # Deep merge options use the Hash utility function provided by [deep_merge](https://github.com/peritor/deep_merge)
      #
      #  :native => Native Hash.merge
      #  :deep   => Use Hash.deep_merge
      #  :deeper => Use Hash.deep_merge!
      #
      def merge_answer(left,right)
        case Config[:merge_behavior]
        when :deeper,'deeper'
          left.deep_merge!(right)
        when :deep,'deep'
          left.deep_merge(right)
        else # Native and undefined
          left.merge(right)
        end
      end

      # Calls out to all configured backends in the order they
      # were specified.  The first one to answer will win.
      #
      # This lets you declare multiple backends, a possible
      # use case might be in Puppet where a Puppet module declares
      # default data using in-module data while users can override
      # using JSON/YAML etc.  By layering the backends and putting
      # the Puppet one last you can override module author data
      # easily.
      #
      # Backend instances are cached so if you need to connect to any
      # databases then do so in your constructor, future calls to your
      # backend will not create new instances
      def lookup(key, default, scope, order_override, resolution_type)
        @backends ||= {}
        answer = nil

        Config[:backends].each do |backend|
          if constants.include?("#{backend.capitalize}_backend") || constants.include?("#{backend.capitalize}_backend".to_sym)
            @backends[backend] ||= Backend.const_get("#{backend.capitalize}_backend").new
            new_answer = @backends[backend].lookup(key, scope, order_override, resolution_type)

            if not new_answer.nil?
              case resolution_type
              when :array
                raise Exception, "Hiera type mismatch: expected Array and got #{new_answer.class}" unless new_answer.kind_of? Array or new_answer.kind_of? String
                answer ||= []
                answer << new_answer
              when :hash
                raise Exception, "Hiera type mismatch: expected Hash and got #{new_answer.class}" unless new_answer.kind_of? Hash
                answer ||= {}
                answer = merge_answer(new_answer,answer)
              else
                answer = new_answer
                break
              end
            end
          end
        end

        answer = resolve_answer(answer, resolution_type) unless answer.nil?
        answer = parse_string(default, scope) if answer.nil? and default.is_a?(String)

        return default if answer.nil?
        return answer
      end
    end
  end
end
