# frozen_string_literal: true

module Authlogic
  # Mixed into `Authlogic::ActsAsAuthentic::Base` and
  # `Authlogic::Session::Foundation`.
  module Config
    E_USE_NORMAL_RAILS_VALIDATION = <<~EOS
      This Authlogic configuration option (%s) is deprecated. Use normal
      ActiveRecord validations instead. For example, instead of the Authlogic
      method validates_length_of_email_field_options, you can use

          validates :email, length: { ... }

      These deprecated Authlogic methods will be removed in the next major version.
    EOS

    def self.extended(klass)
      klass.class_eval do
        # TODO: Is this a confusing name, given this module is mixed into
        # both `Authlogic::ActsAsAuthentic::Base` and
        # `Authlogic::Session::Foundation`? Perhaps a more generic name, like
        # `authlogic_config` would be better?
        class_attribute :acts_as_authentic_config
        self.acts_as_authentic_config ||= {}
      end
    end

    private

    def deprecate_authlogic_config(method_name)
      ::ActiveSupport::Deprecation.warn(
        format(E_USE_NORMAL_RAILS_VALIDATION, method_name)
      )
    end

    # This is a one-liner method to write a config setting, read the config
    # setting, and also set a default value for the setting.
    def rw_config(key, value, default_value = nil)
      if value.nil?
        acts_as_authentic_config.include?(key) ? acts_as_authentic_config[key] : default_value
      else
        self.acts_as_authentic_config = acts_as_authentic_config.merge(key => value)
        value
      end
    end
  end
end
