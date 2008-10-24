module Authgasm
  module Session
    # = ActiveRecord Trickery
    #
    # Authgasm looks like ActiveRecord, sounds like ActiveRecord, but its not ActiveRecord. That's the goal here. This is useful for the various rails helper methods such as form_for, error_messages_for, etc.
    # These helpers exptect various methods to be present. This adds in those methods into Authgasm.
    module ActiveRecordTrickery
      def self.included(klass) # :nodoc:
        klass.extend ClassMethods
        klass.send(:include, InstanceMethods)
      end
      
      module ClassMethods # :nodoc:
        def human_attribute_name(attribute_key_name, options = {})
          attribute_key_name.humanize
        end
      end
      
      module InstanceMethods # :nodoc:
        def id
          nil
        end
      
        def new_record?
          true
        end
      end
    end
  end
end