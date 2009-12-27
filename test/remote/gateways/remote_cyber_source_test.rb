require File.join(File.dirname(__FILE__), '../../test_helper')

class RemoteCyberSourceTest < Test::Unit::TestCase
  def setup
    Base.gateway_mode = :test

    @gateway = CyberSourceGateway.new(fixtures(:cyber_source))

    @credit_card = credit_card('4111111111111111', :type => 'visa')
    @declined_card = credit_card('801111111111111', :type => 'visa')
    
    @amount = 100
    
    @options = {
      :billing_address => address,

      :order_id => generate_unique_id,
      :line_items => [
        {
          :declared_value => 100,
          :quantity => 2,
          :code => 'default',
          :description => 'Giant Walrus',
          :sku => 'WA323232323232323'
        },
        {
          :declared_value => 100,
          :quantity => 2,
          :description => 'Marble Snowcone',
          :sku => 'FAKE1232132113123'
        }
      ],  
      :currency => 'USD',
      :email => 'someguy1232@example.com',
      :ignore_avs => 'true',
      :ignore_cvv => 'true'
    }

  end
  
  def test_successful_authorization
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_equal 'Successful transaction', response.message
    assert_success response
    assert response.test?
    assert !response.authorization.blank?
  end

  def test_unsuccessful_authorization
    assert response = @gateway.authorize(@amount, @declined_card, @options)
    assert response.test?
    assert_equal 'Invalid account number', response.message
    assert_failure response
  end

  def test_successful_tax_calculation
    assert response = @gateway.calculate_tax(@credit_card, @options)
    assert_equal 'Successful transaction', response.message
    assert response.params['totalTaxAmount']
    assert_not_equal "0", response.params['totalTaxAmount']
    assert_success response
    assert response.test?
  end

  def test_successful_tax_calculation_with_nexus
    total_line_items_value = @options[:line_items].inject(0) do |sum, item| 
                               sum += item[:declared_value] * item[:quantity]
                             end
    
    canada_gst_rate = 0.05
    ontario_pst_rate = 0.08
    
    
    total_pst = total_line_items_value.to_f * ontario_pst_rate / 100
    total_gst = total_line_items_value.to_f * canada_gst_rate / 100
    total_tax = total_pst + total_gst
    
    assert response = @gateway.calculate_tax(@credit_card, @options.merge(:nexus => 'ON'))
    assert_equal 'Successful transaction', response.message
    assert response.params['totalTaxAmount']
    assert_equal total_pst, response.params['totalCountyTaxAmount'].to_f
    assert_equal total_gst, response.params['totalStateTaxAmount'].to_f
    assert_equal total_tax, response.params['totalTaxAmount'].to_f
    assert_success response
    assert response.test?
  end

  def test_successful_purchase
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'Successful transaction', response.message
    assert_success response
    assert response.test?
  end

  def test_unsuccessful_purchase
    assert response = @gateway.purchase(@amount, @declined_card, @options)
    assert_equal 'Invalid account number', response.message
    assert_failure response
    assert response.test?
  end

  def test_authorize_and_capture
    assert auth = @gateway.authorize(@amount, @credit_card, @options)
    assert_success auth
    assert_equal 'Successful transaction', auth.message
  
    assert capture = @gateway.capture(@amount, auth.authorization)
    assert_success capture
  end
  
  def test_authorize_in_gbp_instead_of_the_default_usd
    auth = @gateway.authorize(@amount, @credit_card, @options.merge!(:currency => "GBP"))
    assert_success auth
    assert_equal 'Successful transaction', auth.message
  end
  
  def test_successful_authorization_and_failed_capture
    assert auth = @gateway.authorize(@amount, @credit_card, @options)
    assert_success auth
    assert_equal 'Successful transaction', auth.message

    assert capture = @gateway.capture(@amount + 10, auth.authorization, @options)
    assert_failure capture
    assert_equal "The requested amount exceeds the originally authorized amount",  capture.message
  end

  def test_failed_capture_bad_auth_info
    assert auth = @gateway.authorize(@amount, @credit_card, @options)
    assert capture = @gateway.capture(@amount, "a;b;c", @options)
    assert_failure capture
  end

  def test_invalid_login_should_raise_response_error
    gateway = CyberSourceGateway.new( :login => '', :password => '' )
    exception = assert_raise(ActiveMerchant::ResponseError) do
      gateway.purchase(@amount, @credit_card, @options)
    end
    assert_match /wsse:InvalidSecurity/, exception.response.body
  end
  
  def test_successful_credit
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'Successful transaction', response.message
    assert_success response
    assert response.test?
    assert response = @gateway.credit(@amount, response.authorization)
    assert_equal 'Successful transaction', response.message
    assert_success response
    assert response.test?       
  end
  
  def test_successful_store
    response = @gateway.store(@credit_card, @options)

    assert response.test?
    assert_success response
    assert_equal 'Successful transaction', response.message

    assert !response.token.blank?
  end
  
  def test_store_using_an_expired_card_should_fail
    response = @gateway.store(credit_card('4111111111111111', :year => '1999'), @options)
    assert_failure response
    assert response.test?

    assert_equal "Expired card", response.message
  end

  def test_unsuccessful_store
    response = @gateway.store(@declined_card, @options)

    assert response.test?
    assert_failure response
    assert_equal 'Invalid account number', response.message

    assert response.token.blank?
  end
  
  def test_store_should_succeed_when_given_an_authorization_code
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert response.test?

    store_response = @gateway.store(response.authorization, {})
    assert_success store_response
    assert store_response.test?
    
    retrieve_response = @gateway.retrieve(store_response.token, {})
    assert_stored_customer(retrieve_response, @credit_card, @options)
  end
  
  def test_store_should_fail_when_given_a_fake_authorization_code
    response = @gateway.store('fake;authorization;here', {})
    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end
  
  def test_successful_retrieve
    new_options = @options.merge(:email => "123fake@example.com")
    store_response = @gateway.store(@credit_card, new_options)
    response = @gateway.retrieve(store_response.token)
    
    assert response.test?
    assert_success response

    assert_stored_customer(response, @credit_card, new_options)
  end

  def test_unsuccessful_retrieve
    response = @gateway.retrieve("fake-subscription-id-here")
    
    assert_failure response
    assert response.test?

    assert_equal "One or more fields contains invalid data", response.message
    assert response.params["email"].blank?
  end
  
  def test_successful_update_request
    new_credit_card = credit_card("5555 5555 5555 4444", :type => :master)
    new_options = { :credit_card => new_credit_card, :email => "321contact@example.com" }

    store_response = @gateway.store(@credit_card, @options)
    retrieve_response = @gateway.retrieve(store_response.token)
    assert retrieve_response.params["cardAccountNumber"].starts_with?("4111")
    assert_not_equal "321contact@example.com", retrieve_response.params["email"]
    
    response = @gateway.update(store_response.token, @options.merge(new_options))
    assert_success response
    assert response.test?

    retrieve_response = @gateway.retrieve(store_response.token)
    assert_stored_customer(retrieve_response, new_credit_card, @options.merge(new_options))
  end
  
  def test_just_updating_address_should_be_successful
    new_options = { :billing_address => address(:address1 => "123 Fake St.") }
    
    store_response = @gateway.store(@credit_card, @options)
    response = @gateway.update(store_response.token, @options.merge(new_options))
    assert_success response
    assert response.test?
    
    retrieve_response = @gateway.retrieve(store_response.token)
    assert_equal "123 Fake St.", retrieve_response.params["street1"]
  end

  def test_unsuccessful_update_request
    store_response = @gateway.store(@credit_card, @options)
    response = @gateway.update(store_response.token, @options.merge(:credit_card => @declined_card))
  
    assert_failure response
    assert response.test?
    
    assert_equal "Invalid account number", response.message
  end
  
  def test_successful_unstore_request
    store_response = @gateway.store(@credit_card, @options)
    response = @gateway.unstore(store_response.token)

    assert_success response
    assert response.test?
    
    retrieve_response = @gateway.retrieve(store_response.token)
    assert_equal "CANCELED", retrieve_response.params["status"]
  end

  def test_unsuccessful_unstore_request
    response = @gateway.unstore("fake-identification-here")

    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end
  
  def test_should_be_able_to_store_custom_fields
    store_response = @gateway.store(@credit_card, @options.merge({ :custom => ['001', '555', '642', 'snap-crackle-pop', 'not stored'] }))
    response = @gateway.retrieve(store_response.token)

    assert_success response
    assert response.test?

    assert_equal ["001", "555", "642", "snap-crackle-pop"], response.custom_values
  end
  
  def test_should_be_able_update_custom_fields
    store_response = @gateway.store(@credit_card, @options.merge({ :custom => ['001', '555', '642', 'snap-crackle-pop', 'not stored'] }))
    update_respone = @gateway.update(store_response.token, @options.merge({ :custom => ['changed!'] }))

    response = @gateway.retrieve(store_response.token)
    assert_success response
    assert response.test?

    assert_equal ["changed!", "555", "642", "snap-crackle-pop"], response.custom_values
  end
  
  def test_authorize_and_persist_should_store_information
    response = @gateway.authorize(@amount, @credit_card, @options.merge(:persist => true))
    assert_success response
    assert response.test?
    
    assert !response.token.blank?
    retrieve_response = @gateway.retrieve(response.token)
    
    assert_equal response.token, retrieve_response.token
    assert_stored_customer(retrieve_response, @credit_card, @options)
  end
  
  def test_purchase_and_persist_should_store_information
    response = @gateway.purchase(@amount, @credit_card, @options.merge(:persist => true))
    assert_success response
    assert response.test?
    
    assert !response.token.blank?
    retrieve_response = @gateway.retrieve(response.token)
    
    assert_equal response.token, retrieve_response.token
    assert_stored_customer(retrieve_response, @credit_card, @options)
  end
  
  def test_authorize_using_token
    store_response = @gateway.store(@credit_card, @options)
    
    response = @gateway.authorize(@amount, store_response.token, { :order_id => Time.now.to_i })
    assert_success response
    assert response.test?
    
    assert_equal "1.00", response.params["amount"]
    assert_not_nil response.params["authorizationCode"]
  end

  def test_authorize_using_incorrect_token_should_fail
    response = @gateway.authorize(@amount, "fake-token-here", @options)
    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end
  
  def test_purchase_using_token
    store_response = @gateway.store(@credit_card, @options)
    response = @gateway.purchase(@amount, store_response.token, @options)

    assert_success response
    assert response.test?
    
    assert_equal "1.00", response.params["amount"]
  end

  def test_purchase_using_token_with_incorrect_token
    response = @gateway.purchase(@amount, "fake-token-here", @options)

    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end
  
  def test_credit_using_token
    store_response = @gateway.store(@credit_card, @options)
    
    response = @gateway.credit(@amount, store_response.token, @options)

    assert_success response
    assert response.test?
  end
  
  def test_credit_using_token_with_incorrect_token_should_fail
    response = @gateway.credit(@amount, "fake-token-here", @options)
    
    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end
  
private

  def assert_stored_customer(response, credit_card, options)
    assert_stored_address(response, options[:billing_address])
    assert_stored_credit_card(response, credit_card)
    assert_stored_personal_information(response, credit_card, options[:email])
    assert_equal "CURRENT", response.params["status"]
  end
  
  def assert_stored_address(response, billing_address)
    assert_equal billing_address[:city], response.params["city"]
    assert_equal billing_address[:address1], response.params["street1"]
    assert_equal billing_address[:address2], response.params["street2"]
    assert_equal billing_address[:country], response.params["country"]
    assert_equal billing_address[:state], response.params["state"]
    assert_equal billing_address[:zip], response.params["postalCode"]
  end
  
  def assert_stored_credit_card(response, credit_card)
    assert_equal credit_card.year.to_s, response.params["cardExpirationYear"]
    assert_equal sprintf("%02d", credit_card.month), response.params["cardExpirationMonth"]

    credit_card_code = CyberSourceGateway.credit_card_codes[credit_card.type.to_sym]
    assert_equal credit_card_code, response.params["cardType"]

    assert response.params["cardAccountNumber"].starts_with?(credit_card.number.to_s.first(4))
    assert response.params["cardAccountNumber"].ends_with?(credit_card.number.to_s.last(4))
  end
  
  def assert_stored_personal_information(response, credit_card, email)
    assert_equal email, response.params["email"]
    assert_equal credit_card.first_name.upcase, response.params["firstName"]
    assert_equal credit_card.last_name.upcase, response.params["lastName"]
    assert_equal "USD", response.params["currency"]
  end
end