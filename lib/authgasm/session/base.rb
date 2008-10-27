module Authgasm
  module Session # :nodoc:
    # = Base
    #
    # This is the muscle behind Authgasm. For detailed information on how to use this please refer to the README. For detailed method explanations see below.
    class Base
      include Config
      
      class << self
        # Returns true if a controller have been set and can be used properly. This MUST be set before anything can be done. Similar to how ActiveRecord won't allow you to do anything
        # without establishing a DB connection. By default this is done for you automatically, but if you are using Authgasm in a unique way outside of rails, you need to assign a controller
        # object to Authgasm via Authgasm::Session::Base.controller = obj.
        def activated?
          !controller.blank?
        end
        
        def controller=(value) # :nodoc:
          controllers[Thread.current] = value
        end
        
        def controller # :nodoc:
          controllers[Thread.current]
        end
        
        # A convenince method. The same as:
        #
        #   session = UserSession.new
        #   session.create
        def create(*args)
          session = new(*args)
          session.save
        end
        
        # Same as create but calls create!, which raises an exception when authentication fails
        def create!(*args)
          session = new(*args)
          session.save!
        end
        
        # Finds your session by session, then cookie, and finally basic http auth. Perfect for that global before_filter to find your logged in user:
        #
        #   before_filter :load_user
        #
        #   def load_user
        #     @user_session = UserSession.find
        #     @current_user = @user_session && @user_session.record
        #   end
        #
        # Accepts a single parameter as the id. See initialize for more information on ids. Lastly, how it finds the session can be modified via configuration.
        def find(id = nil)
          args = [id].compact
          session = new(*args)
          find_with.each do |find_method|
            if session.send("valid_#{find_method}?")
              if session.record.class.column_names.include?("last_request_at")
                session.record.last_request_at = Time.now
                session.record.save_from_session(false)
              end
              return session
            end
          end
          nil
        end
        
        def klass # :nodoc:
          @klass ||=
            if klass_name
              klass_name.constantize
            else
              nil
            end
        end
        
        def klass_name # :nodoc:
          @klass_name ||= 
            if guessed_name = name.scan(/(.*)Session/)[0]
              @klass_name = guessed_name[0]
            end
        end
        
        private
          def controllers
            @@controllers ||= {}
          end
      end
    
      attr_accessor :login_with, :new_session, :remember_me
      attr_reader :record, :unauthorized_record
      attr_writer :id
    
      # You can initialize a session by doing any of the following:
      #
      #   UserSession.new
      #   UserSession.new(login, password)
      #   UserSession.new(:login => login, :password => password)
      #
      # If a user has more than one session you need to pass an id so that Authgasm knows how to differentiate the sessions. The id MUST be a Symbol.
      #
      #   UserSession.new(:my_id)
      #   UserSession.new(login, password, :my_id)
      #   UserSession.new({:login => loing, :password => password}, :my_id)
      #
      # Ids are rarely used, but they can be useful. For example, what if users allow other users to login into their account via proxy? Now that user can "technically" be logged into 2 accounts at once.
      # To solve this just pass a id called :proxy, or whatever you want. Authgasm will separate everything out.
      def initialize(*args)
        raise NotActivated.new(self) unless self.class.activated?
        
        create_configurable_methods!
        
        self.id = args.pop if args.last.is_a?(Symbol)
        
        case args.size
        when 1
          credentials_or_record = args.first
          case credentials_or_record
          when Hash
            self.credentials = credentials_or_record
          else
            self.unauthorized_record = credentials_or_record
          end
        else
          send("#{login_field}=", args[0])
          send("#{password_field}=", args[1])
          self.remember_me = args[2]
        end
      end
      
      # Your login credentials in hash format. Usually {:login => "my login", :password => "<protected>"} depending on your configuration.
      # Password is protected as a security measure. The raw password should never be publicly accessible.
      def credentials
        {login_field => send(login_field), password_field => "<Protected>"}
      end
      
      # Lets you set your loging and password via a hash format.
      def credentials=(values)
        return if values.blank? || !values.is_a?(Hash)
        raise(ArgumentError, "Only 2 credentials are allowed: #{login_field} and #{password_field}") if (values.keys - [login_field.to_sym, login_field.to_s, password_field.to_sym, password_field.to_s]).size > 0
        values.each { |field, value| send("#{field}=", value) }
      end
      
      # Resets everything, your errors, record, cookies, and session. Basically "logs out" a user.
      def destroy
        errors.clear
        @record = nil
        controller.cookies.delete cookie_key
        controller.session[session_key] = nil
        true
      end
      
      # The errors in Authgasm work JUST LIKE ActiveRecord. In fact, it uses the exact same ActiveRecord errors class. Use it the same way:
      #
      # === Example
      #
      #  class UserSession
      #    before_validation :check_if_awesome
      #
      #    private
      #      def check_if_awesome
      #        errors.add(:login, "must contain awesome") if login && !login.include?("awesome")
      #        errors.add_to_base("You must be awesome to log in") unless record.awesome?
      #      end
      #  end
      def errors
        @errors ||= Errors.new(self)
      end
      
      # Allows you to set a unique identifier for your session, so that you can have more than 1 session at a time. A good example when this might be needed is when you want to have a normal user session
      # and a "secure" user session. The secure user session would be created only when they want to modify their billing information, or other sensative information. Similar to me.com. This requires 2
      # user sessions. Just use an id for the "secure" session and you should be good.
      #
      # You can set the id a number of ways:
      #
      #   session = Session.new(:secure)
      #   session = Session.new("username", "password", :secure)
      #   session = Session.new({:username => "username", :password => "password"}, :secure)
      #   session.id = :secure
      #
      # Just be sure and set your id before you validate / create / update your session.
      def id
        @id
      end
      
      def inspect # :nodoc:
        details = {}
        case login_with
        when :unauthorized_record
          details[:unauthorized_record] = "<protected>"
        else
          details[login_field.to_sym] = send(login_field)
          details[password_field.to_sym] = "<protected>"
        end
        "#<#{self.class.name} #{details.inspect}>"
      end
      
      
      def new_session?
        new_session != false
      end
      
      # Allows users to be remembered via a cookie.
      def remember_me?
        remember_me == true || remember_me == "true" || remember_me == "1"
      end
      
      # When to expire the cookie. See remember_me_for configuration option to change this.
      def remember_me_until
        return unless remember_me?
        remember_me_for.from_now
      end
      
      # Creates / updates a new user session for you. It does all of the magic:
      #
      # 1. validates
      # 2. sets session
      # 3. sets cookie
      # 4. updates magic fields
      def save
        if valid?
          update_session!
          controller.cookies[cookie_key] = {
            :value => record.send(remember_token_field),
            :expires => remember_me_until
          }
          
          record.login_count = record.login_count + 1 if record.respond_to?(:login_count)
          
          if record.respond_to?(:current_login_at)
            record.last_login_at = record.current_login_at if record.respond_to?(:last_login_at)
            record.current_login_at = Time.now
          end
          
          if record.respond_to?(:current_login_ip)
            record.last_login_ip = record.current_login_ip if record.respond_to?(:last_login_ip)
            record.current_login_ip = controller.request.remote_ip
          end
          
          record.save_from_session(false)
          
          self.new_session = false
          self
        end
      end
      
      # Same as save but raises an exception when authentication fails
      def save!
        result = save
        raise SessionInvalid.new(self) unless result
        result
      end
      
      # Sometimes you don't want to create a session via credentials (login and password). Maybe you already have the record. Just set this record to this and it will be authenticated when you try to validate
      # the session. Basically this is another form of credentials, you are just skipping username and password validation.
      def unauthorized_record=(value)
        self.login_with = :unauthorized_record
        @unauthorized_record = value
      end
      
      def valid?
        errors.clear
        temp_record = unauthorized_record
        
        case login_with
        when :credentials
          errors.add(login_field, "can not be blank") if login.blank?
          errors.add(password_field, "can not be blank") if protected_password.blank?
          return false if errors.count > 0

          temp_record = klass.send(find_by_login_method, send(login_field))

          if temp_record.blank?
            errors.add(login_field, "was not found")
            return false
          end
          
          unless temp_record.send(verify_password_method, protected_password)
            errors.add(password_field, "is invalid")
            return false
          end
        when :unauthorized_record
          if temp_record.blank?
            errors.add_to_base("You can not log in with a blank record.")
            return false
          end
          
          if temp_record.new_record?
            errors.add_to_base("You can not login with a new record.") if temp_record.new_record?
            return false
          end
        else
          errors.add_to_base("You must provide some form of credentials before logging in.")
          return false
        end

        [:approved, :confirmed, :inactive].each do |required_status|
          if temp_record.respond_to?("#{required_status}?") && !temp_record.send("#{required_status}?") 
            errors.add_to_base("Your account has not been #{required_status}")       
            return false
          end
        end
        
        # All is good, lets set the record
        @record = temp_record
        
        true
      end
      
      def valid_http_auth?
        controller.authenticate_with_http_basic do |login, password|
          if !login.blank? && !password.blank?
            send("#{login_method}=", login)
            send("#{password_method}=", password)
            result = valid?
            if result
              update_session!
              return result
            end
          end
        end
        
        false
      end
      
      def valid_cookie?
        if cookie_credentials
          self.unauthorized_record = klass.send("find_by_#{remember_token_field}", cookie_credentials)
          result = valid?
          if result
            update_session!
            self.new_session = false
            return result
          end
        end
        
        false
      end
      
      def valid_session?
        if session_credentials
          self.unauthorized_record = klass.send("find_by_#{remember_token_field}", cookie_credentials)
          result = valid?
          if result
            self.new_session = false
            return result
          end
        end
        
        false
      end
      
      private
        def controller
          self.class.controller
        end
        
        def cookie_credentials
          controller.cookies[cookie_key]
        end
        
        def create_configurable_methods!
          return if respond_to?(login_field) # already created these methods
          
          self.class.class_eval <<-"end_eval", __FILE__, __LINE__
            attr_reader :#{login_field}
            
            def #{login_field}=(value)
              self.login_with = :credentials
              @#{login_field} = value
            end
            
            def #{password_field}=(value)
              self.login_with = :credentials
              @#{password_field} = value
            end

            def #{password_field}; end
          end_eval
        end
        
        def klass
          self.class.klass
        end
      
        def klass_name
          self.class.klass_name
        end
        
        # The password should not be accessible publicly. This way forms using form_for don't fill the password with the attempted password. The prevent this we just create this method that is private.
        def protected_password
          @password
        end
        
        def session_credentials
          controller.session[session_key]
        end
        
        def update_session!
          controller.session[session_key] = record && record.send(remember_token_field)
        end
    end
  end
end