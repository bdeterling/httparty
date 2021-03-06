require 'uri'
require 'oauth/consumer'
require 'oauth/client/helper'

module HTTParty
  class Request    
    SupportedHTTPMethods = [Net::HTTP::Get, Net::HTTP::Post, Net::HTTP::Put, Net::HTTP::Delete]
    
    attr_accessor :http_method, :path, :options
    
    def initialize(http_method, path, o={})
      self.http_method = http_method
      self.path = path
      self.options = {
        :limit => o.delete(:no_follow) ? 0 : 5, 
        :default_params => {},
      }.merge(o)
    end

    def path=(uri)
      @path = URI.parse(uri)
    end
    
    def uri
      @uri ||= begin
        uri = path.relative? ? URI.parse("#{options[:base_uri]}#{path}") : path
        uri.query = query_string(uri)
        uri
      end
    end
    
    def format
      options[:format]
    end
    
    def perform
      validate!
      setup_raw_request
      handle_response!(get_response)
    end

    private
      def http #:nodoc:
        http = Net::HTTP.new(uri.host, uri.port, options[:http_proxyaddr], options[:http_proxyport])
        http.use_ssl = (uri.port == 443)
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http
      end

      def setup_basic_auth
        @raw_request.basic_auth(options[:basic_auth][:username], options[:basic_auth][:password])
      end

      def setup_simple_oauth
        consumer = OAuth::Consumer.new(options[:simple_oauth][:key], options[:simple_oauth][:secret])
        oauth_options = { :request_uri => uri,
                          :consumer => consumer,
                          :token => nil,
                          :scheme => 'header',
                          :signature_method => options[:simple_oauth][:method],
                          :nonce => nil,
                          :timestamp => nil }
        @raw_request['authorization'] = OAuth::Client::Helper.new(@raw_request, oauth_options).header
      end

      def setup_raw_request
        @raw_request = http_method.new(uri.request_uri)
        
        if post? && options[:query]
          @raw_request.set_form_data(options[:query])
        end
        
        @raw_request.body = options[:body].is_a?(Hash) ? options[:body].to_params : options[:body] unless options[:body].blank?
        @raw_request.initialize_http_header options[:headers]

        setup_basic_auth if options[:basic_auth]
        setup_simple_oauth if options[:simple_oauth]
      end

      def perform_actual_request
        http.request(@raw_request)
      end

      def get_response #:nodoc:
        response = perform_actual_request
        options[:format] ||= format_from_mimetype(response['content-type'])
        response
      end
      
      def query_string(uri) #:nodoc:
        query_string_parts = []
        query_string_parts << uri.query unless uri.query.blank?

        if options[:query].is_a?(Hash)
          query_string_parts << options[:default_params].merge(options[:query]).to_params
        else
          query_string_parts << options[:default_params].to_params unless options[:default_params].blank?
          query_string_parts << options[:query] unless options[:query].blank?
        end
        
        query_string_parts.size > 0 ? query_string_parts.join('&') : nil
      end
      
      # Raises exception Net::XXX (http error code) if an http error occured
      def handle_response!(response) #:nodoc:
        case response
        when Net::HTTPSuccess
          parse_response(response.body)
        when Net::HTTPRedirection
          options[:limit] -= 1
          self.path = response['location']
          perform
        else
          response.instance_eval { class << self; attr_accessor :body_parsed; end }
          begin; response.body_parsed = parse_response(response.body); rescue; end
          response.error! # raises  exception corresponding to http error Net::XXX
        end
      end
      
      def parse_response(body) #:nodoc:
        return nil if body.nil? or body.empty?
        case format
        when :xml
          ToHashParser.from_xml(body)
        when :json
          JSON.parse(body)
        else
          body
        end
      end
  
      # Uses the HTTP Content-Type header to determine the format of the response
      # It compares the MIME type returned to the types stored in the AllowedFormats hash
      def format_from_mimetype(mimetype) #:nodoc:
        AllowedFormats.each { |k, v| return k if mimetype.include?(v) }
      end
      
      def validate! #:nodoc:
        raise HTTParty::RedirectionTooDeep, 'HTTP redirects too deep' if options[:limit].to_i <= 0
        raise ArgumentError, 'only get, post, put and delete methods are supported' unless SupportedHTTPMethods.include?(http_method)
        raise ArgumentError, ':headers must be a hash' if options[:headers] && !options[:headers].is_a?(Hash)
        raise ArgumentError, ':basic_auth must be a hash' if options[:basic_auth] && !options[:basic_auth].is_a?(Hash)
        raise ArgumentError, ':query must be hash if using HTTP Post' if post? && !options[:query].nil? && !options[:query].is_a?(Hash)
      end
      
      def post?
        Net::HTTP::Post == http_method
      end
  end
end
