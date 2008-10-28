module Authgasm
  module ActsAsAuthentic # :nodoc:
    def self.included(base)
      base.extend(ClassMethods)
    end
    
    # = Acts As Authentic
    # Provides and "acts_as" method to include in your models to help with authentication. See method below.
    module ClassMethods
      # Call this method in your model to add in basic authentication madness:
      #
      # 1. Adds various validations for the login field
      # 2. Adds various validations for the password field
      # 3. Handles password encryption
      # 4. Adds usefule methods to dealing with authentication
      #
      # === Methods
      # For example purposes lets assume you have a User model.
      #
      #   Class method name           Description
      #   User.unique_token           returns unique token generated by your :crypto_provider
      #   User.crypto_provider        The class that you set in your :crypto_provider option
      #   User.forget_all!            Resets all records so they will not be remembered on their next visit. Basically makes their cookies invalid
      #
      #   Named Scopes
      #   User.logged_in              Find all users who are logged in, based on your :logged_in_timeout option
      #   User.logged_out             Same as above, but logged out
      #
      #   Isntace method name
      #   user.password=              Method name based on the :password_field option. This is used to set the password. Pass the *raw* password to this
      #   user.confirm_password=      Confirms the password, needed to change the password
      #   user.valid_password?(pass)  Based on the valid of :password_field. Determines if the password passed is valid. The password could be encrypted or raw.
      #   user.randomize_password!    Basically resets the password to a random password using only letters and numbers
      #   user.logged_in?             Based on the :logged_in_timeout option. Tells you if the user is logged in or not
      #   user.forget!                Changes their remember token, making their cookie invalid.
      #
      # === Options
      # * <tt>session_class:</tt> default: "#{name}Session", the related session class. Used so that you don't have to repeat yourself here. A lot of the configuration will be based off of the configuration values of this class.
      # * <tt>crypto_provider:</tt> default: Authgasm::Sha256CryptoProvider, class that provides Sha256 encryption. What ultimately encrypts your password.
      # * <tt>crypto_provider_type:</tt> default: options[:crypto_provider].respond_to?(:decrypt) ? :encryption : :hash. You can explicitly set this if you wish. Since encryptions and hashes are handled different this is the flag Authgasm uses.
      # * <tt>login_field:</tt> default: options[:session_class].login_field, the name of the field used for logging in
      # * <tt>login_field_type:</tt> default: options[:login_field] == :email ? :email : :login, tells authgasm how to validation the field, what regex to use, etc.
      # * <tt>password_field:</tt> default: options[:session_class].password_field, the name of the field to set the password, *NOT* the field the encrypted password is stored
      # * <tt>crypted_password_field:</tt> default: depends on which columns are present, checks: crypted_password, encrypted_password, password_hash, pw_hash, if none are present defaults to crypted_password. This is the name of column that your encrypted password is stored.
      # * <tt>password_salt_field:</tt> default: depends on which columns are present, checks: password_salt, pw_salt, salt, if none are present defaults to password_salt. This is the name of the field your salt is stored, only relevant for a hash crypto provider.
      # * <tt>remember_token_field:</tt> default: options[:session_class].remember_token_field, the name of the field your remember token is stored. What the cookie stores so the session can be "remembered"
      # * <tt>logged_in_timeout:</tt> default: 10.minutes, this allows you to specify a time the determines if a user is logged in or out. Useful if you want to count how many users are currently logged in.
      # * <tt>session_ids:</tt> default: [nil], the sessions that we want to automatically reset when a user is created or updated so you don't have to worry about this. Set to [] to disable. Should be an array of ids. See Authgasm::Session::Base#initialize for information on ids. The order is important. The first id should be your main session, the session they need to log into first. This is generally nil, meaning so explicitly set id.
      def acts_as_authentic(options = {})
        # Setup default options
        options[:session_class] ||= "#{name}Session".constantize
        options[:crypto_provider] ||= Sha512CryptoProvider
        options[:crypto_provider_type] ||= options[:crypto_provider].respond_to?(:decrypt) ? :encryption : :hash
        options[:login_field] ||= options[:session_class].login_field
        options[:login_field_type] ||= options[:login_field] == :email ? :email : :login
        options[:password_field] ||= options[:session_class].password_field
        options[:crypted_password_field] ||=
          (columns.include?("crypted_password") && :crypted_password) ||
          (columns.include?("encrypted_password") && :encrypted_password) ||
          (columns.include?("password_hash") && :password_hash) ||
          (columns.include?("pw_hash") && :pw_hash) ||
          :crypted_password
        options[:password_salt_field] ||= 
          (columns.include?("password_salt") && :password_salt) ||
          (columns.include?("pw_salt") && :pw_salt) ||
          (columns.include?("salt") && :salt) ||
          :password_salt
        options[:remember_token_field] ||= options[:session_class].remember_token_field
        options[:logged_in_timeout] ||= 10.minutes
        options[:session_ids] ||= [nil]
        
        # Validations
        case options[:login_field_type]
        when :email
          validates_length_of options[:login_field], :within => 6..100
          email_name_regex  = '[\w\.%\+\-]+'
          domain_head_regex = '(?:[A-Z0-9\-]+\.)+'
          domain_tld_regex  = '(?:[A-Z]{2}|com|org|net|edu|gov|mil|biz|info|mobi|name|aero|jobs|museum)'
          email_regex       = /\A#{email_name_regex}@#{domain_head_regex}#{domain_tld_regex}\z/i
          validates_format_of options[:login_field], :with => email_regex, :message => "should look like an email address."
        else
          validates_length_of options[:login_field], :within => 2..100
          validates_format_of options[:login_field], :with => /\A\w[\w\.\-_@]+\z/, :message => "use only letters, numbers, and .-_@ please."
        end
        
        validates_uniqueness_of options[:login_field]
        validates_uniqueness_of options[:remember_token_field]
        validate :validate_password
        validates_numericality_of :login_count, :only_integer => :true, :greater_than_or_equal_to => 0, :allow_nil => true if column_names.include?("login_count")
        
        if column_names.include?("last_click_at")
          named_scope :logged_in, lambda { {:conditions => ["last_click_at > ?", options[:logged_in_timeout].ago]} }
          named_scope :logged_out, lambda { {:conditions => ["last_click_at <= ?", options[:logged_in_timeout].ago]} }
        end
        
        after_create :create_sessions!
        before_update :find_my_sessions
        after_update :update_sessions!
        
        # Attributes
        attr_writer "confirm_#{options[:password_field]}"
        attr_accessor "tried_to_set_#{options[:password_field]}"
        
        # Class methods
        class_eval <<-"end_eval", __FILE__, __LINE__
          def self.unique_token
            crypto_provider.encrypt(Time.now.to_s + (1..10).collect{ rand.to_s }.join)
          end
          
          def self.crypto_provider
            #{options[:crypto_provider]}
          end
          
          def self.forget_all!
            # Paginate these to save on memory
            records = nil
            i = 0
            begin
              records = find(:all, :limit => 50, :offset => i)
              records.each { |record| records.update_attribute(:#{options[:remember_token_field]}, unique_token) }
              i += 50
            end while !records.blank?
          end
        end_eval
        
        # Instance methods
        if column_names.include?("last_click_at")
          class_eval <<-"end_eval", __FILE__, __LINE__
            def logged_in?
              !last_click_at.nil? && last_click_at > #{options[:logged_in_timeout].to_i}.seconds.ago
            end
          end_eval
        end
        
        case options[:crypto_provider_type]
        when :hash
          class_eval <<-"end_eval", __FILE__, __LINE__
            def #{options[:password_field]}=(pass)
              return if pass.blank?
              self.tried_to_set_#{options[:password_field]} = true
              @#{options[:password_field]} = pass
              self.#{options[:remember_token_field]} = self.class.unique_token
              self.#{options[:password_salt_field]} = self.class.unique_token
              self.#{options[:crypted_password_field]} = crypto_provider.encrypt(@#{options[:password_field]} + #{options[:password_salt_field]})
            end
            
            def valid_#{options[:password_field]}?(attempted_password)
              return false if attempted_password.blank?
              attempted_password == #{options[:crypted_password_field]} || #{options[:crypted_password_field]} == crypto_provider.encrypt(attempted_password + #{options[:password_salt_field]})
            end
          end_eval
        when :encryption
          class_eval <<-"end_eval", __FILE__, __LINE__
            def #{options[:password_field]}=(pass)
              return if pass.blank?
              self.tried_to_set_#{options[:password_field]} = true
              @#{options[:password_field]} = pass
              self.#{options[:remember_token_field]} = self.class.unique_token
              self.#{options[:crypted_password_field]} = crypto_provider.encrypt(@#{options[:password_field]})
            end
          
            def valid_#{options[:password_field]}?(attemtped_password)
              return false if attempted_password.blank?
              attempted_password == #{options[:crypted_password_field]} || #{options[:crypted_password_field]} = crypto_provider.decrypt(attempted_password)
            end
          end_eval
        end
        
        class_eval <<-"end_eval", __FILE__, __LINE__
          def #{options[:password_field]}; end
          def confirm_#{options[:password_field]}; end
          
          def crypto_provider
            self.class.crypto_provider
          end
          
          def forget!
            update_attribute(:#{options[:remember_token_field]}, self.class.unique_token)
          end
          
          def randomize_#{options[:password_field]}!
            chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
            newpass = ""
            1.upto(10) { |i| newpass << chars[rand(chars.size-1)] }
            self.#{options[:password_field]} = newpass
            self.confirm_#{options[:password_field]} = newpass
          end
          
          def save_from_session(*args)
            @saving_from_session = true
            result = save(*args)
            @saving_from_session = false
            result
          end
          
          protected
            def create_sessions!
              return if !#{options[:session_class]}.activated? || #{options[:session_ids].inspect}.blank?
              
              # We only want to automatically login into the first session, since this is the main session. The other sessions are sessions
              # that need to be created after logging into the main session.
              session_id = #{options[:session_ids].inspect}.first
              
              # If we are already logged in, ignore this completely. All that we care about is updating ourself.
              next if #{options[:session_class]}.find(*[session_id].compact)
              
              # Log me in
              args = [self, session_id].compact
              #{options[:session_class]}.create(*args)
            end
            
            def find_my_sessions
              return if @saving_from_session || !#{options[:session_class]}.activated?
              
              @my_sessions = []
              #{options[:session_ids].inspect}.each do |session_id|
                session = #{options[:session_class]}.find(*[session_id].compact)
                
                # Ignore if we can't find the session or the session isn't this record
                next if !session || session.record != self
                
                @my_sessions << session
              end
            end
            
            def update_sessions!
              return if @saving_from_session || !#{options[:session_class]}.activated?
              
              @my_sessions.each do |stale_session|
                stale_session.unauthorized_record = self
                stale_session.save
              end
              @my_sessions = nil
            end
            
            def tried_to_set_password?
              tried_to_set_password == true
            end
            
            def validate_password
              if new_record? || tried_to_set_#{options[:password_field]}?
                if @#{options[:password_field]}.blank?
                  errors.add(:#{options[:password_field]}, "can not be blank")
                else
                  errors.add(:confirm_#{options[:password_field]}, "did not match") if @confirm_#{options[:password_field]} != @#{options[:password_field]}
                end
              end
            end
        end_eval
      end
    end
  end
end

ActiveRecord::Base.send(:include, Authgasm::ActsAsAuthentic)