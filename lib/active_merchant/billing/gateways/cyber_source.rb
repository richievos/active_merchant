module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    
    # A convenience class that wraps Response and provides some readers for accessing
    # returned data from CyberSource in a more idiomatic manner.
    class CyberSourceResponse < Response
      # The set of custom values stored with the Customer Profile when creating or 
      # updating a Customer Profile.
      def custom_values
        params.values_at('merchantDefinedDataField1', 'merchantDefinedDataField2', 
          'merchantDefinedDataField3', 'merchantDefinedDataField4').compact
      end
      
      # A returned token from CyberSource that identifies a Customer Profile. Any 
      # further interactions with the Profile (updating, cancelling, authorizing-with)
      # must use this token.
      def token; params["subscriptionID"]; end
    end
    
    # See the remote and mocked unit test files for example usage.  Pay special attention to the contents of the options hash.
    #
    # Initial setup instructions can be found in http://cybersource.com/support_center/implementation/downloads/soap_api/SOAP_toolkits.pdf
    # 
    # Debugging 
    # If you experience an issue with this gateway be sure to examine the transaction information from a general transaction search inside the CyberSource Business
    # Center for the full error messages including field names.   
    #
    # Important Notes
    # * AVS and CVV only work against the production server.  You will always get back X for AVS and no response for CVV against the test server. 
    # * Nexus is the list of states or provinces where you have a physical presence.  Nexus is used to calculate tax.  Leave blank to tax everyone.  
    # * If you want to calculate VAT for overseas customers you must supply a registration number in the options hash as vat_reg_number. 
    # * productCode is a value in the line_items hash that is used to tell CyberSource what kind of item you are selling.  It is used when calculating tax/VAT.
    # * All transactions use dollar values.
    # * In order to transact in multiple currencies, the desired currencies must be enabled on your CyberSource account. This can be accomplished by contacting CyberSource support (a link is available from the Business Center).
    class CyberSourceGateway < Gateway
      
      TEST_URL = 'https://ics2wstest.ic3.com/commerce/1.x/transactionProcessor'
      LIVE_URL = 'https://ics2ws.ic3.com/commerce/1.x/transactionProcessor'
          
      # visa, master, american_express, discover
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]
      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.homepage_url = 'http://www.cybersource.com'
      self.display_name = 'CyberSource'
  
      # map credit card to the CyberSource expected representation
      cattr_accessor :credit_card_codes
      @@credit_card_codes = {
        :visa  => '001',
        :master => '002',
        :american_express => '003',
        :discover => '004'
      }

      # map response codes to something humans can read
      @@response_codes = {
        :r100 => "Successful transaction",
        :r101 => "Request is missing one or more required fields" ,
        :r102 => "One or more fields contains invalid data",
        :r150 => "General failure",
        :r151 => "The request was received but a server time-out occurred",
        :r152 => "The request was received, but a service timed out",
        :r200 => "The authorization request was approved by the issuing bank but declined by CyberSource because it did not pass the AVS check",
        :r201 => "The issuing bank has questions about the request",
        :r202 => "Expired card", 
        :r203 => "General decline of the card", 
        :r204 => "Insufficient funds in the account", 
        :r205 => "Stolen or lost card", 
        :r207 => "Issuing bank unavailable", 
        :r208 => "Inactive card or card not authorized for card-not-present transactions", 
        :r209 => "American Express Card Identifiction Digits (CID) did not match", 
        :r210 => "The card has reached the credit limit", 
        :r211 => "Invalid card verification number", 
        :r221 => "The customer matched an entry on the processor's negative file", 
        :r230 => "The authorization request was approved by the issuing bank but declined by CyberSource because it did not pass the card verification check", 
        :r231 => "Invalid account number",
        :r232 => "The card type is not accepted by the payment processor",
        :r233 => "General decline by the processor",
        :r234 => "A problem exists with your CyberSource merchant configuration",
        :r235 => "The requested amount exceeds the originally authorized amount",
        :r236 => "Processor failure",
        :r237 => "The authorization has already been reversed",
        :r238 => "The authorization has already been captured",
        :r239 => "The requested transaction amount must match the previous transaction amount",
        :r240 => "The card type sent is invalid or does not correlate with the credit card number",
        :r241 => "The request ID is invalid",
        :r242 => "You requested a capture, but there is no corresponding, unused authorization record.",
        :r243 => "The transaction has already been settled or reversed",
        :r244 => "The bank account number failed the validation check",
        :r246 => "The capture or credit is not voidable because the capture or credit information has already been submitted to your processor",
        :r247 => "You requested a credit for a capture that was previously voided",
        :r250 => "The request was received, but a time-out occurred with the payment processor",
        :r254 => "Your CyberSource account is prohibited from processing stand-alone refunds",
        :r255 => "Your CyberSource account is not configured to process the service in the country you specified" 
      }

      # Creates a new CyberSourceGateway object.
      #
      # This call requires:
      # 
      # - :login =>  your username 
      # - :password =>  the transaction key you generated in the Business Center       
      #
      # This call allows: 
      # - :test => true   sets the gateway to test mode
      # - :vat_reg_number => your VAT registration number
      # - :nexus => "WI CA QC" sets the states/provinces where you have a physical presense for tax purposes
      # - :ignore_avs => true   don't want to use AVS so continue processing even if AVS would have failed 
      # - :ignore_cvv => true   don't want to use CVV so continue processing even if CVV would have failed 
      def initialize(options = {})
        requires!(options, :login, :password)
        @options = options
        super
      end  

      # Should run against the test servers or not?
      def test?
        @options[:test] || Base.gateway_mode == :test
      end
      
      
      # Allows for authorizing a payment against a credit_card.
      #
      # This call requires:
      # - an amount of money (as a Money object or positive integer)
      # - either
      #   - a valid credit_card object 
      #   - an options hash containing at least:
      #     - a :billing_address
      #     - an :order_id
      #     - a valid :email address
      # - or
      #   - a token from CyberSource (retrieved from the store API call) that is linked to a 
      #     valid credit card
      #   - an options hash containing at least an :order_id key
      #
      # This call allows:
      # - a :persist in the options hash. If set to true, the customer information will be saved,
      #   and a token (available via response.token) will be returned for usage in future 
      #   transactions.
      # - a :currency in the options hash (3-letter currency code, per ISO 4217). Default: "USD". 
      #   A full list of supported currency codes is available at:
      #   http://apps.cybersource.com/library/documentation/sbc/quickref/currencies.pdf
      # - a :custom in the options hash. This can be an Array of up to four items that will
      #   be sent to CyberSource for storage along with the rest of the customer Profile information.
      #   Note that each item in the Array will have to_s called on it, so plan for your own
      #   mapping/serialization carefully.
      def authorize(money, credit_card_or_token, options = {})
        requires!(options, :order_id)
        setup_address_hash(options)
        commit(build_auth_request(money, credit_card_or_token, options), options )
      end

      # Capture an authorization that has previously been requested
      def capture(money, authorization, options = {})
        setup_address_hash(options)
        commit(build_capture_request(money, authorization, options), options)
      end

      # Allows for a combined authorize and capture.
      #
      # This call has the same requirements and options as authorize.
      def purchase(money, credit_card, options = {})
        requires!(options, :order_id, :email)
        setup_address_hash(options)
        commit(build_purchase_request(money, credit_card, options), options)
      end
      
      def void(identification, options = {})
        commit(build_void_request(identification, options), options)
      end

      def credit(money, identification, options = {})
        commit(build_credit_request(money, identification, options), options)
      end
      
      # Allows for storing credit card information. In CyberSource, this is done behind the scenes by 
      # creating a Profile.
      #
      # This call requires:
      # - a valid credit card (storage of invalid cards is not allowed)
      # - an address be specified in the options hash (as with authorize)
      #
      # This call allows:
      # - a :currency in the options hash (3-letter currency code, per ISO 4217). Default: "USD".
      # - a :custom option in the options hash. This can be an Array of up to four items that will
      #   be sent to CyberSource for storage along with the rest of the customer Profile information.
      #   Note that each item in the Array will have to_s called on it, so plan for your own
      #   mapping/serialization carefully.
      def store(credit_card, options = {})
        setup_address_hash(options)
        commit(build_store_request(credit_card, options), options)
      end
      
      # Allows for retrieving stored Profile information.
      #
      # This call requires:
      # - a token from CyberSource (retrieved when using store to create a Profile).
      def retrieve(identification, options={})
        commit(build_retrieve_request(identification, options), options)
      end
      
      # Allows for updating stored Profile information.
      #
      # This call requires:
      # - a token from CyberSource (retrieved when using store to create a Profile).
      #
      # This call allows:
      # - a valid credit card object be specified in the options hash (as with the first 
      #   parameter to store) as :credit_card
      # - an address be specified in the options hash (as with authorize)
      def update(identification, options={})
        commit(build_update_request(identification, options), options)
      end
      
      # Allows for removing stored Profile information. In CyberSource, there's no *real* way 
      # to remove Profile information. Instead, we actually just cancel the Profile, which
      # means we are no longer able to authorize against it. Since Profiles are PCI compliant, 
      # the only information about customers that will still be readily available are name and
      # address (credit card numbers are masked).
      #
      # This call requires:
      # - a token from CyberSource (retrieved when using store to create a Profile).
      def unstore(identification, options={})
        commit(build_unstore_request(identification, options), options)
      end

      # CyberSource requires that you provide line item information for tax calculations
      # If you do not have prices for each item or want to simplify the situation then pass in one fake line item that costs the subtotal of the order
      #
      # The line_item hash goes in the options hash and should look like 
      # 
      #         :line_items => [
      #           {
      #             :declared_value => '1',
      #             :quantity => '2',
      #             :code => 'default',
      #             :description => 'Giant Walrus',
      #             :sku => 'WA323232323232323'
      #           },
      #           {
      #             :declared_value => '6',
      #             :quantity => '1',
      #             :code => 'default',
      #             :description => 'Marble Snowcone',
      #             :sku => 'FAKE1232132113123'
      #           }
      #         ]
      #
      # This functionality is only supported by this particular gateway may
      # be changed at any time
      def calculate_tax(credit_card, options)
        requires!(options,  :line_items)
        setup_address_hash(options)
        commit(build_tax_calculation_request(credit_card, options), options)
      end
      
      private                       
      # Create all address hash key value pairs so that we still function if we were only provided with one or two of them 
      def setup_address_hash(options)
        options[:billing_address] = options[:billing_address] || options[:address] || {}
        options[:shipping_address] = options[:shipping_address] || {}
      end
      
      def build_auth_request(money, credit_card_or_token, options)
        xml = Builder::XmlMarkup.new :indent => 2
        
        if credit_card_or_token.respond_to?(:display_number)
          requires!(options, :email)

          add_address(xml, credit_card_or_token, options[:billing_address], options)
          add_purchase_data(xml, money, true, options)
          add_credit_card(xml, credit_card_or_token)
          add_store_information(xml) if options[:persist]
          add_auth_service(xml)
          add_business_rules_data(xml)
          add_create_service(xml) if options[:persist]
        else
          add_purchase_data(xml, money, true, options)
          add_recurring_subscription_info(xml, credit_card_or_token)
          add_auth_service(xml)
        end

        xml.target!
      end
      
      def build_store_request(credit_card, options)
        xml = Builder::XmlMarkup.new :indent => 2
        add_address(xml, credit_card, options[:billing_address], options)
        add_purchase_data(xml, 0, false)
        add_credit_card(xml, credit_card)
        add_store_information(xml)
        add_custom_information(xml, options[:custom]) unless options[:custom].blank?
        add_create_service(xml)
        xml.target!
      end
      
      def build_update_request(identification, options)
        xml = Builder::XmlMarkup.new :indent => 2
        add_address(xml, options[:credit_card], options[:billing_address], options) if options[:billing_address]
        add_credit_card(xml, options[:credit_card]) if options[:credit_card]
        add_update_information(xml, identification)
        add_custom_information(xml, options[:custom]) unless options[:custom].blank?
        add_update_service(xml)
        xml.target!
      end
      
      def build_retrieve_request(identification, options)
        # CyberSource requires this (put into the XML as merchantReferenceCode) to be set to *something*, 
        # although it doesn't care about its contents otherwise.
        options[:order_id] = Time.now.to_i.to_s
        
        xml = Builder::XmlMarkup.new :indent => 2
        add_recurring_subscription_info(xml, identification)
        xml.tag! "paySubscriptionRetrieveService", { 'run' => 'true' }
        
        xml.target!
      end
      
      def build_unstore_request(identification, options)
        options[:order_id] = Time.now.to_i.to_s
        
        xml = Builder::XmlMarkup.new :indent => 2
        add_update_information(xml, identification, true)
        add_update_service(xml)
        xml.target!
      end

      def build_tax_calculation_request(credit_card, options)
        xml = Builder::XmlMarkup.new :indent => 2
        add_address(xml, credit_card, options[:billing_address], options, false)
        add_address(xml, credit_card, options[:shipping_address], options, true)
        add_line_item_data(xml, options)
        add_purchase_data(xml, 0, false, options)
        add_tax_service(xml)
        add_business_rules_data(xml)
        xml.target!
      end
 
      def build_capture_request(money, authorization, options)
        order_id, request_id, request_token = authorization.split(";")
        options[:order_id] = order_id

        xml = Builder::XmlMarkup.new :indent => 2
        add_purchase_data(xml, money, true, options)
        add_capture_service(xml, request_id, request_token)
        add_business_rules_data(xml)
        xml.target!
      end 

      def build_purchase_request(money, credit_card, options)
        xml = Builder::XmlMarkup.new :indent => 2
        add_address(xml, credit_card, options[:billing_address], options)
        add_purchase_data(xml, money, true, options)
        add_credit_card(xml, credit_card)
        add_store_information(xml) if options[:persist]
        add_purchase_service(xml, options)
        add_business_rules_data(xml)
        add_create_service(xml) if options[:persist]
        xml.target!
      end
      
      def build_void_request(identification, options)
        order_id, request_id, request_token = identification.split(";")
        options[:order_id] = order_id
        
        xml = Builder::XmlMarkup.new :indent => 2
        add_void_service(xml, request_id, request_token)
        xml.target!
      end

      def build_credit_request(money, identification, options)
        order_id, request_id, request_token = identification.split(";")
        options[:order_id] = order_id
        
        xml = Builder::XmlMarkup.new :indent => 2
        add_purchase_data(xml, money, true, options)
        add_credit_service(xml, request_id, request_token)
        
        xml.target!
      end

      def add_business_rules_data(xml)
        return xml unless @options[:ignore_avs] || @options[:ignore_cvv]
        
        xml.tag! 'businessRules' do
          xml.tag!('ignoreAVSResult', 'true') if @options[:ignore_avs]
          xml.tag!('ignoreCVResult', 'true') if @options[:ignore_cvv]
        end 
      end
      
      def add_line_item_data(xml, options)
        options[:line_items].each_with_index do |value, index|
          xml.tag! 'item', {'id' => index} do
            xml.tag! 'unitPrice', amount(value[:declared_value])  
            xml.tag! 'quantity', value[:quantity]
            xml.tag! 'productCode', value[:code] || 'shipping_only'
            xml.tag! 'productName', value[:description]
            xml.tag! 'productSKU', value[:sku]
          end
        end
      end
      
      def add_merchant_data(xml, options)
        xml.tag! 'merchantID', @options[:login]
        xml.tag! 'merchantReferenceCode', options[:order_id]
        xml.tag! 'clientLibrary' ,'Ruby Active Merchant'
        xml.tag! 'clientLibraryVersion',  '1.0'
        xml.tag! 'clientEnvironment' , 'Linux'
      end
      
      def add_recurring_subscription_info(xml, identification)
        xml.tag! "recurringSubscriptionInfo" do
          xml.tag! "subscriptionID", identification
        end
      end

      def add_purchase_data(xml, money = 0, include_grand_total = false, options={})
        xml.tag! 'purchaseTotals' do
          xml.tag! 'currency', options[:currency] || currency(money)
          xml.tag!('grandTotalAmount', amount(money))  if include_grand_total
        end
      end

      def add_address(xml, credit_card, address, options, shipTo = false)      
        xml.tag! shipTo ? 'shipTo' : 'billTo' do
          xml.tag! 'firstName', credit_card.first_name if credit_card
          xml.tag! 'lastName', credit_card.last_name if credit_card
          xml.tag! 'street1', address[:address1]
          xml.tag! 'street2', address[:address2]
          xml.tag! 'city', address[:city]
          xml.tag! 'state', address[:state]
          xml.tag! 'postalCode', address[:zip]
          xml.tag! 'country', address[:country]
          xml.tag! 'email', options[:email]
        end 
      end

      def add_credit_card(xml, credit_card)      
        xml.tag! 'card' do
          xml.tag! 'accountNumber', credit_card.number
          xml.tag! 'expirationMonth', format(credit_card.month, :two_digits)
          xml.tag! 'expirationYear', format(credit_card.year, :four_digits)
          xml.tag!('cvNumber', credit_card.verification_value) unless (@options[:ignore_cvv] || credit_card.verification_value.blank? )
          xml.tag! 'cardType', @@credit_card_codes[card_brand(credit_card).to_sym]
        end
      end

      def add_tax_service(xml)
        xml.tag! 'taxService', {'run' => 'true'} do
          xml.tag!('nexus', @options[:nexus]) unless @options[:nexus].blank?
          xml.tag!('sellerRegistration', @options[:vat_reg_number]) unless @options[:vat_reg_number].blank?
        end
      end

      def add_auth_service(xml)
        xml.tag! 'ccAuthService', {'run' => 'true'} 
      end
      
      def add_store_information(xml)
        xml.tag! "recurringSubscriptionInfo" do
          xml.tag! "amount", "0.00"
          xml.tag! "frequency", "on-demand"
        end
      end
      
      def add_update_information(xml, identification, should_cancel=false)
        xml.tag! "recurringSubscriptionInfo" do
          xml.tag! "subscriptionID", identification
          xml.tag! "status", "cancel" if should_cancel
          xml.tag! "amount", "0.00"
        end
      end
      
      def add_custom_information(xml, custom_data)
        xml.tag! "merchantDefinedData" do
          custom_data.first(4).each_with_index do |item, idx|
            xml.tag! "field#{idx+1}", item.to_s
          end
        end
      end
      
      def add_create_service(xml)
        xml.tag! "paySubscriptionCreateService", { 'run' => 'true' }
      end
      
      def add_update_service(xml)
        xml.tag! "paySubscriptionUpdateService", { 'run' => 'true' }
      end

      def add_capture_service(xml, request_id, request_token)
        xml.tag! 'ccCaptureService', {'run' => 'true'} do
          xml.tag! 'authRequestID', request_id
          xml.tag! 'authRequestToken', request_token
        end
      end

      def add_purchase_service(xml, options)
        xml.tag! 'ccAuthService', {'run' => 'true'}
        xml.tag! 'ccCaptureService', {'run' => 'true'}
      end
      
      def add_void_service(xml, request_id, request_token)
        xml.tag! 'voidService', {'run' => 'true'} do
          xml.tag! 'voidRequestID', request_id
          xml.tag! 'voidRequestToken', request_token
        end
      end

      def add_credit_service(xml, request_id, request_token)
        xml.tag! 'ccCreditService', {'run' => 'true'} do
          xml.tag! 'captureRequestID', request_id
          xml.tag! 'captureRequestToken', request_token
        end
      end
      
      # Where we actually build the full SOAP request using builder
      def build_request(body, options)
        xml = Builder::XmlMarkup.new :indent => 2
          xml.instruct!
          xml.tag! 's:Envelope', {'xmlns:s' => 'http://schemas.xmlsoap.org/soap/envelope/'} do
            xml.tag! 's:Header' do
              xml.tag! 'wsse:Security', {'s:mustUnderstand' => '1', 'xmlns:wsse' => 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd'} do
                xml.tag! 'wsse:UsernameToken' do
                  xml.tag! 'wsse:Username', @options[:login]
                  xml.tag! 'wsse:Password', @options[:password], 'Type' => 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText'
                end
              end
            end
            xml.tag! 's:Body', {'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance', 'xmlns:xsd' => 'http://www.w3.org/2001/XMLSchema'} do
              xml.tag! 'requestMessage', {'xmlns' => 'urn:schemas-cybersource-com:transaction-data-1.32'} do
                add_merchant_data(xml, options)
                xml << body
              end
            end
          end
        xml.target! 
      end
      
      # Contact CyberSource, make the SOAP request, and parse the reply into a Response object
      def commit(request, options)
        response = parse(ssl_post(test? ? TEST_URL : LIVE_URL, build_request(request, options)))
        
        success = response[:decision] == "ACCEPT"
        message = @@response_codes[('r' + response[:reasonCode]).to_sym] rescue response[:message] 
        authorization = success ? [ options[:order_id], response[:requestID], response[:requestToken] ].compact.join(";") : nil

        CyberSourceResponse.new(success, message, response, 
          :test => test?, 
          :authorization => authorization,
          :avs_result => { :code => response[:avsCode] },
          :cvv_result => response[:cvCode]
        )
      end
      
      # Parse the SOAP response
      # Technique inspired by the Paypal Gateway
      def parse(xml)
        reply = {}
        xml = REXML::Document.new(xml)
        if root = REXML::XPath.first(xml, "//c:replyMessage")
          root.elements.to_a.each do |node|
            case node.name
            when 'c:reasonCode'
              reply[:message] = reply(node.text)
            else
              parse_element(reply, node)
            end
          end
        elsif root = REXML::XPath.first(xml, "//soap:Fault") 
          parse_element(reply, root)
          reply[:message] = "#{reply[:faultcode]}: #{reply[:faultstring]}"
        end
        return reply
      end     

      def parse_element(reply, node)
        if node.has_elements?
          node.elements.each{|e| parse_element(reply, e) }
        else
          if node.parent.name =~ /item/
            parent = node.parent.name + (node.parent.attributes["id"] ? "_" + node.parent.attributes["id"] : '')
            reply[(parent + '_' + node.name).to_sym] = node.text
          else  
            reply[node.name.to_sym] = node.text
          end
        end
        return reply
      end
    end 
  end 
end 