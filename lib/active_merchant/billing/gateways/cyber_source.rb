module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # == Setup
    # In order to work with CyberSource, you must have an account. You can {register for an evaluation
    # account}[https://apps.cybersource.com/cgi-bin/register/reg_form.pl]; this will provide you with
    # a CyberSource ID (also referred to as a merchantID), as well as a login to the CyberSource
    # Business Center.
    #
    # This gateway implementation uses CyberSource's SOAP API. In order to use the SOAP API, you must
    # generate an encrytion key that will be used as your "password" for API requests. The instructions
    # for generating this key can be found in page 9 of the SOAP Toolkits API document listed under
    # References.
    #
    # You should update the fixtures.yml file to reflect your merchantID and generated encrytion key
    # for login and password, respectively.
    #
    # == Usage
    # Example usage can be found in CyberSourceTest and RemoteCyberSourceTest. This gateway conforms
    # to the ActiveMerchant API, and so provides the basic authorize, capture, purchase, void and
    # credit functionality.
    #
    # This gateway implementation also provides the following additional functionality:
    #
    # * the ability to store, update, retrieve and unstore stored customer details (credit card,
    #   address, etc.)
    # * the ability to store customer details from a previous authorization
    # * the ability to authorize and purchase using stored customer details
    # * the ability to calculate_tax, given an address and a list of line items
    #
    # CyberSource maintains the notion of Customer Profiles for storing customer details. For more
    # information, check out the Secure Data Suite User's and Developer's Guides. Note that this data
    # storage functionality uses the same underpinnings as CyberSource's recurring billing functionality,
    # so much of the documentation is intermingled.
    #
    # == Debugging
    # CyberSource has provided a SOAPUI[http://soapui.org/] project that is modestly invaluable for
    # both development and debugging. After {downloading the project}[http://files.onedesigncompany.com/active-merchant/cybersource-soapui-project.zip], you
    # should open up `CyberSource Web Service SoapUI Project (Template).xml` in your text editor of choice
    # and replace "[Your Merchant ID Here]" with your merchantID and "[Your EBC SOAP Key Here]" with your
    # generated encryption key. Then, you can import the Project into SOAPUI and see pre-built (and working)
    # SOAP API requests and responses.
    #
    # If you experience an issue with this gateway be sure to examine the transaction information
    # from a general transaction search inside the CyberSource Business Center for the full error
    # messages including field names.
    #
    # == Notes
    # * All transactions use dollar values.
    # * AVS and CVV only work against the production server. On the test server, you will always
    #   get back an 'X' for AVS and no response for CVV.
    # * In order to transact in multiple currencies, the desired currencies must be enabled on your
    #   CyberSource account. This can be accomplished by contacting CyberSource support (a link is
    #   available from the CyberSource Business Center).
    #
    # = References
    # * {SOAP Toolkits for CyberSource's Web Services: Developer Guide (PDF)}[http://www.cybersource.com/support_center/implementation/downloads/soap_api/SOAP_toolkits.pdf]
    # * {CyberSource Business Center (Test)}[https://ebctest.cybersource.com/]
    # * {CyberSource Business Center (Live)}[https://ebc.cybersource.com/]
    # * {CyberSource Secure Data Suite: User's Guide}[http://apps.cybersource.com/library/documentation/dev_guides/Secure_Data_Suite_UG/html/]
    # * {CyberSource Secure Data Suite: Developers's Guide}[http://apps.cybersource.com/library/documentation/dev_guides/Recurring_Billing_IG/html/]
    # * {List of CyberSource Quick References}[http://www.cybersource.com/support_center/support_documentation/quick_references/]
    # * {A full list of CyberSource supported currency codes (PDF)}[http://apps.cybersource.com/library/documentation/sbc/quickref/currencies.pdf]
    # * {CyberSource Credit Card Services: For the Simple Order API}[http://apps.cybersource.com/library/documentation/dev_guides/CC_Svcs_SO_API/html/]
    # * {CyberSource SOAPUI Project}[http://files.onedesigncompany.com/active-merchant/cybersource-soapui-project.zip]
    class CyberSourceGateway < Gateway
      SIXTY_DAYS_AGO = (60 * 86400)

      # A convenience class that wraps ActiveMerchant::Billing::Response and provides some
      # readers for accessing returned data from CyberSource in a more idiomatic manner.
      class Response < ActiveMerchant::Billing::Response
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

      TEST_URL = 'https://ics2wstest.ic3.com/commerce/1.x/transactionProcessor'
      LIVE_URL = 'https://ics2ws.ic3.com/commerce/1.x/transactionProcessor'

      self.supported_cardtypes = [:visa, :master, :american_express, :discover]
      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.homepage_url = 'http://www.cybersource.com'
      self.display_name = 'CyberSource'

      # map CreditCard to the CyberSource expected representation
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
      # - :vat_reg_number => your VAT registration number. Required if you want to calculate VAT for
      #   overseas customers
      # - :nexus => "WI CA QC" sets the list of states or provinces where you have a physical presence
      #   and is used to  calculate tax. Leave this blank to tax everyone.
      # - :ignore_avs => true   don't want to use AVS so continue processing even if AVS would have failed
      # - :ignore_cvv => true   don't want to use CVV so continue processing even if CVV would have failed
      def initialize(options = {})
        requires!(options, :login, :password)
        @options = options
        super
      end

      # Returns true if transactions will run against CyberSource's test gateway. Note that if this option
      # is specified, it will override the setting of Base.gateway_mode.
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
      #     valid CreditCard
      #   - an options hash containing at least an :order_id key
      #
      # This call allows:
      # - a :persist in the options hash. If set to true, the customer information will be saved,
      #   and a token (available via response.token) will be returned for usage in future
      #   transactions.
      # - a :currency in the options hash (3-letter currency code, per ISO 4217). Default: "USD".
      # - a :custom in the options hash. This can be an Array of up to four items that will
      #   be sent to CyberSource for storage along with the rest of the customer Profile information.
      #   Note that each item in the Array will have to_s called on it, so plan for your own
      #   mapping/serialization carefully.
      def authorize(money, credit_card_or_token, options = {})
         # :order_id is always required. :email is only required if using a credit card, so we check
         # it in build_auth_request instead of here.
        requires!(options, :order_id)
        setup_address_hash(options)
        commit(build_auth_request(money, credit_card_or_token, options), options )
      end

      # Allows for capturing an authorization.
      #
      # This call requires:
      # - an amount of money equal to or less than the amount of the authorization
      # - an authorization code (e.g. received from the result of an authorize call)
      #
      # This call does not allow any options to speak of.
      def capture(money, authorization, options = {})
        setup_address_hash(options)
        commit(build_capture_request(money, authorization, options), options)
      end

      # Allows for a combined authorize and capture.
      #
      # This call has the same requirements and options as authorize.
      def purchase(money, credit_card_or_token, options = {})
        # :order_id is always required. :email is only required if using a credit card, so we check
        # it in build_purchase_request instead of here.
        requires!(options, :order_id)
        setup_address_hash(options)
        commit(build_purchase_request(money, credit_card_or_token, options), options)
      end

      # Allows for a void of a previous transaction.
      #
      # This call requires:
      # - an authorization code (e.g. received from the result of an authorize call)
      #
      # This call does not allow any options to speak of.
      #-----
      # Note: in test mode, it appears that this request always fails with error code 246:
      # "The capture or credit is not voidable because the capture or credit information
      # has already been submitted to your processor"
      def void(identification, options = {})
        commit(build_void_request(identification, options), options)
      end

      # Allows for a credit of a previous transaction.
      #
      # This call requires:
      # - an amount of money (as a Money object or positive integer) to credit
      # - an authorization code (e.g. received from the result of an authorize call)
      # - required:
      #   - :token => a token from CyberSource (retrieved from the store API call)
      #   - :created_at => timestamp (used to determine if over the 60 day mark)
      #
      # This call does not allow any options to speak of.
      def credit(money, identification, options = {})
        requires!(options, :token, :created_at)
        token, created_at = options.delete(:token), options.delete(:created_at)
        if (Time.now - (created_at || Time.now)) >= SIXTY_DAYS_AGO
          target = build_standalone_credit_request(money, token, options)
        else
          target = build_credit_request(money, identification, options)
        end
        commit(target, options)
      end

      def standalone_credit(money, token, options={})
        commit(build_standalone_credit_request(money, token, options), options)
      end

      # Allows for storing credit card information. In CyberSource, this is done behind the scenes by
      # creating a Profile.
      #
      # This call requires:
      # - either
      #   - a valid CreditCard (storage of invalid cards is not allowed)
      #   - an address be specified in the options hash (as with authorize)
      # - or
      #   - an authorization code
      #
      # This call allows:
      # - a :currency in the options hash (3-letter currency code, per ISO 4217). Default: "USD".
      # - a :custom option in the options hash. This can be an Array of up to four items that will
      #   be sent to CyberSource for storage along with the rest of the customer Profile information.
      #   Note that each item in the Array will have to_s called on it, so plan for your own
      #   mapping/serialization carefully.
      # - an :order_id option in the options hash. Default: the current time, represented as an integer.
      def store(credit_card_or_authorization, options = {})
        options[:order_id] ||= default_order_id
        setup_address_hash(options)
        commit(build_store_request(credit_card_or_authorization, options), options)
      end

      # Allows for retrieving stored Profile information.
      #
      # This call requires:
      # - a token from CyberSource (retrieved when using store to create a Profile).
      #
      # This call does not allow any options to speak of.
      def retrieve(identification, options={})
        commit(build_retrieve_request(identification, options), options)
      end

      # Allows for updating stored Profile information.
      #
      # This call requires:
      # - a token from CyberSource (retrieved when using store to create a Profile).
      #
      # This call allows:
      # - a valid CreditCard object be specified in the options hash (as with the first
      #   parameter to store) as :credit_card
      # - an address be specified in the options hash (as with authorize)
      def update(identification, options={})
        setup_address_hash(options)
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
      #
      # This call does not allow any options to speak of.
      def unstore(identification, options={})
        commit(build_unstore_request(identification, options), options)
      end

      # Allows for calculating of tax based on line-item detail.
      #
      # This call requires:
      # - a valid CreditCard
      # - a :line_items option in the option hash that should look like the following:
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
      # If you do not have prices for each item or want to simplify the situation then pass in
      # one fake line item that costs the subtotal of the order.
      #
      # This functionality is only supported by this particular gateway may and be changed at
      # any time
      #
      # Note that the 'code' value is used to tell CyberSource what kind of item you are selling.
      def calculate_tax(credit_card, options)
        requires!(options,  :line_items)
        setup_address_hash(options)
        commit(build_tax_calculation_request(credit_card, options), options)
      end

    private

      # Create all address hash key value pairs so that we still function if we were only
      # provided with one or two of them
      def setup_address_hash(options)
        options[:billing_address] = options[:billing_address] || options[:address] || {}
        options[:shipping_address] = options[:shipping_address] || {}
      end

      def build_auth_request(money, credit_card_or_token, options)
        xml = Builder::XmlMarkup.new :indent => 2

        if credit_card_or_token.respond_to?(:display_number)
          requires!(options, :email)
          build_auth_request_from_credit_card(xml, money, credit_card_or_token, options)
        else
          build_auth_request_from_profile(xml, money, credit_card_or_token, options)
        end

        xml.target!
      end

      def build_auth_request_from_credit_card(xml, money, credit_card, options)
        add_address(xml, credit_card, options[:billing_address], options)
        add_purchase_data(xml, money, true, options)
        add_credit_card(xml, credit_card)
        add_store_information(xml) if options[:persist]
        add_auth_service(xml)
        add_create_service(xml) if options[:persist]
        add_business_rules_data(xml)
      end

      def build_auth_request_from_profile(xml, money, token, options)
        add_purchase_data(xml, money, true, options)
        add_recurring_subscription_info(xml, token)
        add_auth_service(xml)
      end

      def build_store_request(credit_card_or_authorization, options)
        xml = Builder::XmlMarkup.new :indent => 2

        if credit_card_or_authorization.is_a?(CreditCard)
          build_store_request_from_credit_card(xml, credit_card_or_authorization, options)
        else
          build_store_request_from_authorization(xml, credit_card_or_authorization, options)
        end

        add_business_rules_data(xml)
        xml.target!
      end

      def build_store_request_from_credit_card(xml, credit_card, options)
        add_address(xml, credit_card, options[:billing_address], options)
        add_purchase_data(xml, 0, false)
        add_credit_card(xml, credit_card)
        add_store_information(xml)
        add_custom_information(xml, options[:custom]) unless options[:custom].blank?
        add_create_service(xml)
      end

      def build_store_request_from_authorization(xml, authorization, options)
        add_store_information(xml, false)
        add_create_from_auth_service(xml, authorization)
      end

      def build_update_request(identification, options)
        xml = Builder::XmlMarkup.new :indent => 2
        add_address(xml, options[:credit_card], options[:billing_address], options) if options[:billing_address]
        add_credit_card(xml, options[:credit_card], false) if options[:credit_card]
        add_update_information(xml, identification)
        add_custom_information(xml, options[:custom]) unless options[:custom].blank?
        add_update_service(xml)
        xml.target!
      end

      def build_retrieve_request(identification, options)
        # CyberSource requires this (put into the XML as merchantReferenceCode) to be set to
        # *something*, although it doesn't care about its contents otherwise.
        options[:order_id] = default_order_id

        xml = Builder::XmlMarkup.new :indent => 2
        add_recurring_subscription_info(xml, identification)
        xml.tag! "paySubscriptionRetrieveService", { 'run' => 'true' }

        xml.target!
      end

      def build_unstore_request(identification, options)
        options[:order_id] = default_order_id

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

      def build_purchase_request(money, credit_card_or_token, options)
        xml = Builder::XmlMarkup.new :indent => 2

        if credit_card_or_token.respond_to?(:display_number)
          requires!(options, :email)
          build_purchase_request_from_credit_card(xml, money, credit_card_or_token, options)
        else
          build_purchase_request_from_profile(xml, money, credit_card_or_token, options)
        end
        xml.target!
      end

      def build_purchase_request_from_credit_card(xml, money, credit_card, options)
        add_address(xml, credit_card, options[:billing_address], options)
        add_purchase_data(xml, money, true, options)
        add_credit_card(xml, credit_card)
        add_store_information(xml) if options[:persist]
        add_purchase_service(xml)
        add_create_service(xml) if options[:persist]
        add_business_rules_data(xml)
      end

      def build_purchase_request_from_profile(xml, money, token, options)
        add_purchase_data(xml, money, true, options)
        add_recurring_subscription_info(xml, token)
        add_purchase_service(xml)
        add_business_rules_data(xml)
      end

      def build_void_request(identification, options)
        order_id, request_id, request_token = identification.split(";")
        options[:order_id] = order_id

        xml = Builder::XmlMarkup.new :indent => 2
        add_void_service(xml, request_id, request_token)
        xml.target!
      end

      def build_credit_request(money, identification, options)
        xml = Builder::XmlMarkup.new :indent => 2
        build_credit_request_from_authorization(xml, money, identification, options)
        xml.target!
      end

      def build_standalone_credit_request(money, token, options)
        xml = Builder::XmlMarkup.new :indent => 2
        build_credit_request_from_profile(xml, money, token)
        xml.target!
      end

      def build_credit_request_from_profile(xml, money, token)
        add_purchase_data(xml, money, true, { :order_id => default_order_id })
        add_recurring_subscription_info(xml, token)
        add_credit_service(xml, nil, nil)
      end

      def build_credit_request_from_authorization(xml, money, identification, options)
        order_id, request_id, request_token = identification.split(";")
        options[:order_id] = order_id

        add_purchase_data(xml, money, true, options)
        add_credit_service(xml, request_id, request_token)
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
        xml.tag! 'merchantReferenceCode', options[:order_id] || default_order_id
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
        currency_to_send = options[:currency].blank? ? currency(money) : options[:currency]
        
        xml.tag! 'purchaseTotals' do
          xml.tag! 'currency', currency_to_send
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

      def add_credit_card(xml, credit_card, include_account_number=true)
        xml.tag! 'card' do
          xml.tag! 'accountNumber', credit_card.number if include_account_number
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

      def add_store_information(xml, include_amount=true)
        xml.tag! "recurringSubscriptionInfo" do
          xml.tag! "amount", "0.00" if include_amount
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

      def add_create_from_auth_service(xml, authorization)
        order_id, request_id, request_token = authorization.split(";")

        xml.tag! "paySubscriptionCreateService", { 'run' => 'true' } do
          xml.tag! "paymentRequestID", request_id
          xml.tag! "paymentRequestToken", request_token
        end
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

      def add_purchase_service(xml)
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
          xml.tag! 'captureRequestID', request_id if request_id
          xml.tag! 'captureRequestToken', request_token if request_token
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

      # Contacts CyberSource, makes the SOAP request, and parses the reply into a
      # CyberSourceGateway::Response object
      def commit(request, options)
        response = parse(ssl_post(test? ? TEST_URL : LIVE_URL, build_request(request, options)))
        success = response[:decision] == "ACCEPT"
        message = @@response_codes[('r' + response[:reasonCode]).to_sym] rescue response[:message]
        authorization = success ? [ options[:order_id], response[:requestID], response[:requestToken] ].compact.join(";") : nil

        Response.new(success, message, response,
          :test => test?,
          :authorization => authorization,
          :avs_result => { :code => response[:avsCode] },
          :cvv_result => response[:cvCode]
        )
      end

      # Parses the SOAP response. Technique inspired by the Paypal Gateway.
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

      def default_order_id
        Time.now.to_i
      end
    end # CyberSourceGateway
  end   # Billing
end     # ActiveMerchant
