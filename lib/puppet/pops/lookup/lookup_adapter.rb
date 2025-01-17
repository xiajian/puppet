require_relative 'data_adapter'
require_relative 'lookup_key'

module Puppet::Pops
module Lookup
# A LookupAdapter is a specialized DataAdapter that uses its hash to store data providers. It also remembers the compiler
# that it is attached to and maintains a cache of _lookup options_ retrieved from the data providers associated with the
# compiler's environment.
#
# @api private
class LookupAdapter < DataAdapter

  LOOKUP_OPTIONS_PREFIX = LOOKUP_OPTIONS + '.'
  LOOKUP_OPTIONS_PREFIX.freeze
  HASH = 'hash'.freeze
  MERGE = 'merge'.freeze

  def self.create_adapter(compiler)
    new(compiler)
  end

  def initialize(compiler)
    super()
    @compiler = compiler
    @lookup_options = {}
  end

  # Performs a lookup using global, environment, and module data providers. Merge the result using the given
  # _merge_ strategy. If the merge strategy is nil, then an attempt is made to find merge options in the
  # `lookup_options` hash for an entry associated with the key. If no options are found, the no merge is performed
  # and the first found entry is returned.
  #
  # @param key [String] The key to lookup
  # @param lookup_invocation [Invocation] the lookup invocation
  # @param merge [MergeStrategy,String,Hash{String => Object},nil] Merge strategy, merge strategy name, strategy and options hash, or nil (implies "first found")
  # @return [Object] the found object
  # @throw :no_such_key when the object is not found
  #
  def lookup(key, lookup_invocation, merge)
    # The 'lookup_options' key is reserved and not found as normal data
    if key == LOOKUP_OPTIONS || key.start_with?(LOOKUP_OPTIONS_PREFIX)
      lookup_invocation.with(:invalid_key, LOOKUP_OPTIONS) do
        throw :no_such_key
      end
    end

    key = LookupKey.new(key)
    lookup_invocation.lookup(key, key.module_name) do
      merge_explained = false
      if lookup_invocation.only_explain_options?
        catch(:no_such_key) { do_lookup(LookupKey::LOOKUP_OPTIONS, lookup_invocation, HASH) }
        nil
      else
        if merge.nil?
          # Used cached lookup_options
          merge = lookup_merge_options(key, lookup_invocation)
          lookup_invocation.report_merge_source(LOOKUP_OPTIONS) unless merge.nil?
        end
        lookup_invocation.with(:data, key.to_s) { do_lookup(key, lookup_invocation, merge) }
      end
    end
  end

  def lookup_global(key, lookup_invocation, merge_strategy)
    terminus = Puppet[:data_binding_terminus]

    # If global lookup is disabled, immediately report as not found
    if terminus == 'none' || terminus.nil? || terminus == ''
      lookup_invocation.report_not_found(name)
      throw :no_such_key
    end

    if(terminus.to_s == 'hiera')
      provider = global_provider(lookup_invocation)
      throw :no_such_key if provider.nil?
      return provider.key_lookup(key, lookup_invocation, merge_strategy)
    end

    lookup_invocation.with(:global, terminus) do
      catch(:no_such_key) do
        return lookup_invocation.report_found(key, Puppet::DataBinding.indirection.find(key.root_key,
          {:environment => environment, :variables => lookup_invocation.scope, :merge => merge_strategy}))
      end
      lookup_invocation.report_not_found(key)
      throw :no_such_key
    end
  rescue Puppet::DataBinding::LookupError => detail
    error = Puppet::Error.new("Lookup of key '#{lookup_invocation.top_key}' failed: #{detail.message}")
    error.set_backtrace(detail.backtrace)
    raise error
  end

  def lookup_in_environment(key, lookup_invocation, merge_strategy)
    provider = env_provider(lookup_invocation)
    throw :no_such_key if provider.nil?
    provider.key_lookup(key, lookup_invocation, merge_strategy)
  end

  def lookup_in_module(key, lookup_invocation, merge_strategy)
    module_name = lookup_invocation.module_name

    # Do not attempt to do a lookup in a module unless the name is qualified.
    throw :no_such_key if module_name.nil?

    provider = module_provider(lookup_invocation, module_name)
    if provider.nil?
      if environment.module(module_name).nil?
        lookup_invocation.report_module_not_found(module_name)
      else
        lookup_invocation.report_module_provider_not_found(module_name)
      end
      throw :no_such_key
    end
    provider.key_lookup(key, lookup_invocation, merge_strategy)
  end

  # Retrieve the merge options that match the given `name`.
  #
  # @param key [LookupKey] The key for which we want merge options
  # @param lookup_invocation [Invocation] the lookup invocation
  # @return [String,Hash,nil] The found merge options or nil
  #
  def lookup_merge_options(key, lookup_invocation)
    lookup_options = lookup_lookup_options(key, lookup_invocation)
    lookup_options.nil? ? nil : lookup_options[MERGE]
  end

  # Retrieve the lookup options that match the given `name`.
  #
  # @param key [LookupKey] The key for which we want lookup options
  # @param lookup_invocation [Puppet::Pops::Lookup::Invocation] the lookup invocation
  # @return [String,Hash,nil] The found lookup options or nil
  #
  def lookup_lookup_options(key, lookup_invocation)
    module_name = key.module_name

    # Retrieve the options for the module. We use nil as a key in case we have no module
    if !@lookup_options.include?(module_name)
      options = retrieve_lookup_options(module_name, lookup_invocation, MergeStrategy.strategy(HASH))
      raise Puppet::DataBinding::LookupError.new("value of #{LOOKUP_OPTIONS} must be a hash") unless options.nil? || options.is_a?(Hash)
      @lookup_options[module_name] = options
    else
      options = @lookup_options[module_name]
    end
    options.nil? ? nil : options[key.root_key]
  end

  private

  PROVIDER_STACK = [:lookup_global, :lookup_in_environment, :lookup_in_module].freeze

  def do_lookup(key, lookup_invocation, merge)
    merge_strategy = Puppet::Pops::MergeStrategy.strategy(merge)
    key.dig(lookup_invocation,
      merge_strategy.lookup(PROVIDER_STACK, lookup_invocation) { |m| send(m, key, lookup_invocation, merge_strategy) })
  end

  GLOBAL_ENV_MERGE = 'Global and Environment'.freeze

  # Retrieve lookup options that applies when using a specific module (i.e. a merge of the pre-cached
  # `env_lookup_options` and the module specific data)
  def retrieve_lookup_options(module_name, lookup_invocation, merge_strategy)
    meta_invocation = Invocation.new(lookup_invocation.scope)
    meta_invocation.lookup(LookupKey::LOOKUP_OPTIONS, lookup_invocation.module_name) do
      meta_invocation.with(:meta, LOOKUP_OPTIONS) do
        opts = env_lookup_options(meta_invocation, merge_strategy)
        catch(:no_such_key) do
          module_opts = lookup_in_module(LookupKey::LOOKUP_OPTIONS, meta_invocation, merge_strategy)
          opts = if opts.nil?
            module_opts
          else
            env_name =
            merge_strategy.lookup([GLOBAL_ENV_MERGE, "Module #{lookup_invocation.module_name}"], meta_invocation) do |n|
              meta_invocation.with(:scope, n) { meta_invocation.report_found(LOOKUP_OPTIONS,  n == GLOBAL_ENV_MERGE ? opts : module_opts) }
            end
          end
        end
        opts
      end
    end
  end

  # Retrieve and cache lookup options specific to the environment of the compiler that this adapter is attached to (i.e. a merge
  # of global and environment lookup options).
  def env_lookup_options(lookup_invocation, merge_strategy)
    if !instance_variable_defined?(:@env_lookup_options)
      @global_lookup_options = nil
      catch(:no_such_key) { @global_lookup_options = lookup_global(LookupKey::LOOKUP_OPTIONS, lookup_invocation, merge_strategy) }
      @env_only_lookup_options = nil
      catch(:no_such_key) { @env_only_lookup_options = lookup_in_environment(LookupKey::LOOKUP_OPTIONS, lookup_invocation, merge_strategy) }
      if @global_lookup_options.nil?
        @env_lookup_options = @env_only_lookup_options
      elsif @env_only_lookup_options.nil?
        @env_lookup_options = @global_lookup_options
      else
        @env_lookup_options = merge_strategy.merge(@global_lookup_options, @env_only_lookup_options)
      end
    end
    @env_lookup_options
  end

  def global_provider(lookup_invocation)
    @global_provider = GlobalDataProvider.new unless instance_variable_defined?(:@global_provider)
    @global_provider
  end

  def env_provider(lookup_invocation)
    @env_provider = initialize_env_provider(lookup_invocation) unless instance_variable_defined?(:@env_provider)
    @env_provider
  end

  def module_provider(lookup_invocation, module_name)
    # Test if the key is present for the given module_name. It might be there even if the
    # value is nil (which indicates that no module provider is configured for the given name)
    unless self.include?(module_name)
      self[module_name] = initialize_module_provider(lookup_invocation, module_name)
    end
    self[module_name]
  end

  def initialize_module_provider(lookup_invocation, module_name)
    mod = environment.module(module_name)
    return nil if mod.nil?

    metadata = mod.metadata
    binding = false
    provider_name = metadata.nil? ? nil : metadata['data_provider']
    if provider_name.nil?
      provider_name = bound_module_provider_name(module_name)
      binding = !provider_name.nil?
    end

    mp = nil
    if mod.has_hiera_conf?
      mp = ModuleDataProvider.new(module_name)
      # A version 5 hiera.yaml trumps a data provider setting or binding in the module
      if mp.config(lookup_invocation).version >= 5
        unless provider_name.nil? || Puppet[:strict] == :off
          if binding
            Puppet.warn_once(:deprecation, "ModuleBinding#data_provider-#{module_name}",
              "Defining data_provider '#{provider_name}' as a Puppet::Binding is deprecated. The binding is ignored since a '#{HieraConfig::CONFIG_FILE_NAME}' with version >= 5 is present")
          else
            Puppet.warn_once(:deprecation, "metadata.json#data_provider-#{module_name}",
              "Defining \"data_provider\": \"#{provider_name}\" in metadata.json is deprecated. It is ignored since a '#{HieraConfig::CONFIG_FILE_NAME}' with version >= 5 is present", mod.metadata_file)
          end
        end
        provider_name = nil
      end
    end

    if provider_name.nil?
      mp
    else
      unless Puppet[:strict] == :off
        if binding
          msg = "Defining data_provider '#{provider_name}' as a Puppet::Binding is deprecated"
          msg += ". A '#{HieraConfig::CONFIG_FILE_NAME}' file should be used instead" if mp.nil?
          Puppet.warn_once(:deprecation, "ModuleBinding#data_provider-#{module_name}", msg)
        else
          msg = "Defining \"data_provider\": \"#{provider_name}\" in metadata.json is deprecated"
          msg += ". A '#{HieraConfig::CONFIG_FILE_NAME}' file should be used instead" if mp.nil?
          Puppet.warn_once(:deprecation, "metadata.json#data_provider-#{module_name}", msg, mod.metadata_file)
        end
      end

      case provider_name
      when 'none'
        nil
      when 'hiera'
        mp || ModuleDataProvider.new(module_name)
      when 'function'
        ModuleDataProvider.new(module_name, HieraConfig.v4_function_config(Pathname(mod.path), "#{module_name}::data"))
      else
        injector = Puppet.lookup(:injector) { nil }
        provider = injector.lookup(nil,
          Puppet::Plugins::DataProviders::Registry.hash_of_module_data_providers,
          Puppet::Plugins::DataProviders::MODULE_DATA_PROVIDERS_KEY)[provider_name]
        unless provider
          raise Puppet::Error.new("Environment '#{environment.name}', cannot find module_data_provider '#{provider_name}'")
        end
        # Provider is configured per module but cached using compiler life cycle so it must be cloned
        provider.clone
      end
    end
  end

  def bound_module_provider_name(module_name)
    injector = Puppet.lookup(:injector) { nil }
    injector.nil? ? nil : injector.lookup(nil,
      Puppet::Plugins::DataProviders::Registry.hash_of_per_module_data_provider,
      Puppet::Plugins::DataProviders::PER_MODULE_DATA_PROVIDER_KEY)[module_name]
  end

  def initialize_env_provider(lookup_invocation)
    env_conf = environment.configuration
    return nil if env_conf.nil? || env_conf.path_to_env.nil?

    # Get the name of the data provider from the environment's configuration
    provider_name = env_conf.environment_data_provider
    env_path = Pathname(env_conf.path_to_env)
    config_path = env_path + HieraConfig::CONFIG_FILE_NAME

    ep = nil
    if config_path.exist?
      ep = EnvironmentDataProvider.new
      # A version 5 hiera.yaml trumps any data provider setting in the environment.conf
      if ep.config(lookup_invocation).version >= 5
        unless provider_name.nil? || Puppet[:strict] == :off
          Puppet.warn_once(:deprecation, 'environment.conf#data_provider',
            "Defining environment_data_provider='#{provider_name}' in environment.conf is deprecated", env_path + 'environment.conf')

          unless provider_name == 'hiera'
            Puppet.warn_once(:deprecation, 'environment.conf#data_provider_overridden',
              "The environment_data_provider='#{provider_name}' setting is ignored since '#{config_path}' version >= 5", env_path + 'environment.conf')
          end
        end
        provider_name = nil
      end
    end

    if provider_name.nil?
      ep
    else
      unless Puppet[:strict] == :off
        msg = "Defining environment_data_provider='#{provider_name}' in environment.conf is deprecated"
        msg += ". A '#{HieraConfig::CONFIG_FILE_NAME}' file should be used instead" if ep.nil?
        Puppet.warn_once(:deprecation, 'environment.conf#data_provider', msg, env_path + 'environment.conf')
      end

      case provider_name
      when 'none'
        nil
      when 'hiera'
        # Use hiera.yaml or default settings if it is missing
        ep || EnvironmentDataProvider.new
      when 'function'
        EnvironmentDataProvider.new(HieraConfigV5.v4_function_config(env_path, 'environment::data'))
      else
         injector = Puppet.lookup(:injector) { nil }

        # Support running tests without an injector being configured == using a null implementation
        return nil unless injector

        # Get the service (registry of known implementations)
        provider = injector.lookup(nil,
          Puppet::Plugins::DataProviders::Registry.hash_of_environment_data_providers,
          Puppet::Plugins::DataProviders::ENV_DATA_PROVIDERS_KEY)[provider_name]
        unless provider
          raise Puppet::Error.new("Environment '#{environment.name}', cannot find environment_data_provider '#{provider_name}'")
        end
        provider
      end
    end
  end

  # @return [Puppet::Node::Environment] the environment of the compiler that this adapter is associated with
  def environment
    @compiler.environment
  end
end
end
end

require_relative 'invocation'
require_relative 'global_data_provider'
require_relative 'environment_data_provider'
require_relative 'module_data_provider'
