require_relative 'function_provider'

module Puppet::Pops
module Lookup
# @api private
class LookupKeyFunctionProvider < FunctionProvider
  TAG = 'lookup_key'.freeze

  # Performs a lookup with the assumption that a recursive check has been made.
  #
  # @param key [LookupKey] The key to lookup
  # @param lookup_invocation [Invocation] The current lookup invocation
  # @param merge [MergeStrategy,String,Hash{String => Object},nil] Merge strategy, merge strategy name, strategy and options hash, or nil (implies "first found")
  # @return [Object] the found object
  # @throw :no_such_key when the object is not found
  def unchecked_key_lookup(key, lookup_invocation, merge)
    lookup_invocation.with(:data_provider, self) do
      MergeStrategy.strategy(merge).lookup(locations, lookup_invocation) do |location|
        if location.nil?
          value = lookup_key(key.root_key, lookup_invocation, nil, merge)
          lookup_invocation.report_found(key.root_key, validate_data_value(self, value))
        else
          lookup_invocation.with(:location, location) do
            if location.exist?
              value = lookup_key(key.root_key, lookup_invocation, location.location, merge)
              lookup_invocation.report_found(key.root_key, validate_data_value(self, value))
            else
              lookup_invocation.report_location_not_found
              throw :no_such_key
            end
          end
        end
      end
    end
  end

  def label
    'Lookup Key'
  end

  private

  def lookup_key(key, lookup_invocation, location, merge)
    ctx = function_context(lookup_invocation, location)
    ctx.data_hash ||= {}
    catch(:no_such_key) do
      hash = ctx.data_hash
      hash[key] = ctx.function.call(lookup_invocation.scope, key, options(location), Context.new(ctx, lookup_invocation)) unless hash.include?(key)
      return hash[key]
    end
    lookup_invocation.report_not_found(key)
    throw :no_such_key
  end
end

class V3BackendFunctionProvider < LookupKeyFunctionProvider
  TAG = 'v3_backend'.freeze

  def lookup_key(key, lookup_invocation, location, merge)
    @backend ||= instantiate_backend(lookup_invocation)
    @backend.lookup(key, lookup_invocation.scope, nil, convert_merge(merge), context = {:recurse_guard => nil})
  end

  private

  def instantiate_backend(lookup_invocation)
    begin
      require 'hiera/backend'
      require "hiera/backend/#{@name.downcase}_backend"
      backend = Hiera::Backend.const_get("#{@name.capitalize}_backend").new
      return backend.method(:lookup).arity == 4 ? Hiera::Backend::Backend1xWrapper.new(backend) : backend
    rescue LoadError => e
      lookup_invocation.report_text { "Unable to load backend '#{@name}': #{e.message}" }
      throw :no_such_key
    rescue NameError => e
      lookup_invocation.report_text { "Unable to instantiate backend '#{@name}': #{e.message}" }
      throw :no_such_key
    end
  end

  # Converts a lookup 'merge' parameter argument into a Hiera 'resolution_type' argument.
  #
  # @param merge [String,Hash,nil] The lookup 'merge' argument
  # @return [Symbol,Hash,nil] The Hiera 'resolution_type'
  def convert_merge(merge)
    case merge
    when nil
    when 'first'
      # Nil is OK. Defaults to Hiera :priority
      nil
    when Puppet::Pops::MergeStrategy
      convert_merge(merge.configuration)
    when 'unique'
      # Equivalent to Hiera :array
      :array
    when 'hash'
      # Equivalent to Hiera :hash with default :native merge behavior. A Hash must be passed here
      # to override possible Hiera deep merge config settings.
      { :behavior => :native }
    when 'deep'
      # Equivalent to Hiera :hash with :deeper merge behavior.
      { :behavior => :deeper }
    when Hash
      strategy = merge['strategy']
      if strategy == 'deep'
        result = { :behavior => :deeper }
        # Remaining entries must have symbolic keys
        merge.each_pair { |k,v| result[k.to_sym] = v unless k == 'strategy' }
        result
      else
        convert_merge(strategy)
      end
    else
      raise Puppet::DataBinding::LookupError, "Unrecognized value for request 'merge' parameter: '#{merge}'"
    end
  end
end
end
end
