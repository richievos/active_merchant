require File.join(File.dirname(__FILE__), '../../test_helper')

class CyberSourceTest < Test::Unit::TestCase
  def setup
    Base.gateway_mode = :test

    @gateway = CyberSourceGateway.new(:login => 'l', :password => 'p')

    @amount = 100
    @credit_card = credit_card('4111111111111111', :type => 'visa')
    @declined_card = credit_card('801111111111111', :type => 'visa')
    
    @options = {
               :token => "2611552700460008299530",
               :created_at => Time.now,
               :billing_address => { 
                  :address1 => '1234 My Street',
                  :address2 => 'Apt 1',
                  :company => 'Widgets Inc',
                  :city => 'Ottawa',
                  :state => 'ON',
                  :zip => 'K1C2N6',
                  :country => 'Canada',
                  :phone => '(555)555-5555'
               },

               :email => 'someguy1232@example.com',
               :order_id => '1000',
               :line_items => [
                   {
                      :declared_value => @amount,
                      :quantity => 2,
                      :code => 'default',
                      :description => 'Giant Walrus',
                      :sku => 'WA323232323232323'
                   },
                   {
                      :declared_value => @amount,
                      :quantity => 2,
                      :description => 'Marble Snowcone',
                      :sku => 'FAKE1232132113123'
                   }
                 ],
          :currency => 'USD'
    }
  end
  
  def test_successful_purchase
    @gateway.expects(:ssl_post).returns(successful_purchase_response)

    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'Successful transaction', response.message
    assert_success response
    assert_equal "#{@options[:order_id]};#{response.params['requestID']};#{response.params['requestToken']}", response.authorization
    assert response.test?
  end

  def test_unsuccessful_authorization
    @gateway.expects(:ssl_post).returns(unsuccessful_authorization_response)

    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_kind_of Response, response
    assert_failure response
  end
  
  def test_successful_auth_request
    @gateway.stubs(:ssl_post).returns(successful_authorization_response)
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_kind_of Response, response
    assert_success response
    assert response.test?
  end
  
  def test_successful_tax_request
    @gateway.stubs(:ssl_post).returns(successful_tax_response)
    assert response = @gateway.calculate_tax(@credit_card, @options)
    assert_kind_of Response, response
    assert_success response
    assert response.test?
  end

  def test_successful_capture_request
    @gateway.stubs(:ssl_post).returns(successful_authorization_response, successful_capture_response)
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert response.test?
    assert response_capture = @gateway.capture(@amount, response.authorization)
    assert_success response_capture
    assert response_capture.test?
  end

  def test_successful_purchase_request
    @gateway.stubs(:ssl_post).returns(successful_capture_response)
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert response.test?
  end

  def test_requires_error_on_purchase_without_order_id  
    @options.delete(:order_id)
    assert_raise(ArgumentError){ @gateway.purchase(@amount, @credit_card, @options) }
  end

  def test_requires_error_on_authorization_without_order_id
    @options.delete(:order_id)
    assert_raise(ArgumentError){ @gateway.authorize(@amount, @credit_card, @options) }
  end

  def test_requires_error_on_authorization_without_email
    @options.delete(:email)
    assert_raise(ArgumentError){ @gateway.authorize(@amount, @credit_card, @options) }
  end

  def test_requires_error_on_tax_calculation_without_line_items
    @options.delete(:line_items)
    assert_raise(ArgumentError){ @gateway.calculate_tax(@credit_card, @options) }
  end

  def test_default_currency
    assert_equal 'USD', CyberSourceGateway.default_currency
  end
  
  def test_avs_result
    @gateway.expects(:ssl_post).returns(successful_purchase_response)
    
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'Y', response.avs_result['code']
  end
  
  def test_cvv_result
    @gateway.expects(:ssl_post).returns(successful_purchase_response)
    
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_equal 'M', response.cvv_result['code']
  end

  def test_request_should_not_include_a_business_rules_element_if_neither_ignore_avs_nor_ignore_cvv_are_set
    assert_no_match(/businessRules/, auth_request)
  end

  def test_request_should_include_a_business_rules_element_if_ignore_avs_is_set
    @gateway.instance_eval { @options.merge! :ignore_avs => true }
    assert_match(/businessRules/, auth_request)
    assert_match(/ignoreAVSResult/, auth_request)
  end
  
  def test_request_should_include_a_business_rules_element_if_ignore_cvv_is_set
    @gateway.instance_eval { @options.merge! :ignore_cvv => true }
    assert_match(/businessRules/, auth_request)
    assert_match(/ignoreCVResult/, auth_request)
  end
  
  def test_successful_store_request
    @gateway.expects(:ssl_post).returns(successful_store_response)
    response = @gateway.store(@credit_card, @options)

    assert_success response
    assert response.test?

    assert_equal "2605496732830008402433", response.token
  end

  def test_unsuccessful_store_request
    @gateway.expects(:ssl_post).returns(unsuccessful_store_response)
    response = @gateway.store(@declined_card, @options)

    assert_failure response
    assert response.test?

    assert_nil response.token
    assert_equal "Invalid account number", response.message
  end
  
  def test_store_should_succeed_when_given_an_authorization_code
    @gateway.stubs(:ssl_post).returns(successful_authorization_response, successful_store_using_auth_response)
    response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert response.test?

    store_response = @gateway.store(response.authorization, {})
    assert_success response
    assert response.test?
  end
  
  def test_store_should_fail_when_given_a_fake_authorization_code
    @gateway.stubs(:ssl_post).returns(unsuccessful_store_using_auth_response)
    
    response = @gateway.store('fake-authorization-here', {})
    assert_failure response
    assert response.test?

    assert_equal "One or more fields contains invalid data", response.message
  end
  
  def test_successful_retrieve_request
    @gateway.expects(:ssl_post).returns(successful_retrieve_response)
    response = @gateway.retrieve("2605522582930008402433")
    
    assert_success response
    assert response.test?

    assert !response.params["email"].blank?
  end

  def test_unsuccessful_retrieve_request
    @gateway.expects(:ssl_post).returns(unsuccessful_retrieve_response)
    response = @gateway.retrieve("fake-token-here")
    
    assert_failure response
    assert response.test?

    assert_equal "One or more fields contains invalid data", response.message
    assert response.params["email"].blank?
  end
  
  def test_successful_update_request
    @gateway.expects(:ssl_post).returns(successful_update_response)
    response = @gateway.update("2605522582930008402433", @options.merge(:credit_card => @credit_card))

    assert_success response
    assert response.test?
  end
  
  def test_successful_update_request_includes_card_info_except_number
    @gateway.expects(:ssl_post).with do |arg1, request_body|
      request_body.include?('cvNumber') &&
      request_body.include?('expirationMonth') &&
      request_body.include?('expirationYear') &&
      request_body.include?('cardType') &&
      !request_body.include?('accountNumber')
    end
    response = @gateway.update("2605522582930008402433", @options.merge(:credit_card => @credit_card))
  end

  def test_unsuccessful_update_request
    @gateway.expects(:ssl_post).returns(unsuccessful_update_response)
    response = @gateway.update("2605522582930008402433", @options.merge(:credit_card => @declined_card))

    assert_failure response
    assert response.test?
    
    assert_equal "Invalid account number", response.message
  end

  def test_successful_unstore_request
    @gateway.expects(:ssl_post).returns(successful_unstore_response)
    response = @gateway.unstore("2605522582930008402433")

    assert_success response
    assert response.test?
  end

  def test_unsuccessful_unstore_request
    @gateway.expects(:ssl_post).returns(unsuccessful_unstore_response)
    response = @gateway.unstore("fake-token-here")

    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end
  
  def test_custom_values_should_be_returned_to_retrieve_as_an_array
    @gateway.expects(:ssl_post).returns(successful_retrieve_response)
    response = @gateway.retrieve("2605522582930008402433")
    
    assert_equal ["boo", "cry"], response.custom_values
  end
  
  def test_authorize_and_persist_should_parse_token_from_response
    @gateway.expects(:ssl_post).returns(successful_auth_and_create_profile_response)
    response = @gateway.authorize(@amount, @credit_card, @options.merge(:persist => true))
    assert_equal "2611513342530008402433", response.token
  end
  
  def test_purchase_and_persist_should_parse_token_from_response
    @gateway.expects(:ssl_post).returns(successful_purchase_and_create_profile_response)
    response = @gateway.purchase(@amount, @credit_card, @options.merge(:persist => true))
    assert_equal "2611552700460008299530", response.token
  end
  
  def test_authorize_using_token
    @gateway.expects(:ssl_post).returns(successful_authorize_using_token_response)
    response = @gateway.authorize(@amount, "2611552700460008299530", @options)
    assert_success response
    assert response.test?
  end

  def test_authorize_using_token_with_incorrect_token_should_fail
    @gateway.expects(:ssl_post).returns(unsuccessful_authorize_using_token_response)
    response = @gateway.authorize(@amount, "fake-token-here", @options)
    assert_failure response
    assert response.test?
  end
  
  def test_purchase_using_token
    @gateway.expects(:ssl_post).returns(successful_purchase_using_token_response)
    response = @gateway.purchase(@amount, "2611552700460008299530", @options)

    assert_success response
    assert response.test?
    
    assert !response.authorization.blank?
  end

  def test_purchase_using_token_with_incorrect_token_should_fail
    @gateway.expects(:ssl_post).returns(unsuccessful_purchase_using_token_response)
    response = @gateway.purchase(@amount, "fake-token-here", @options)

    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end

  #
  # Crediting
  #
  
  def test_credit_when_missing_token_option
    @gateway.stubs(:ssl_post)
    @options.delete(:token)
    assert_raise(ArgumentError, "Missing required parameter: token") do
      @gateway.credit(@amount, "123;456;78901234567890", @options)
    end
  end

  def test_credit_when_missing_created_at_option
    @gateway.stubs(:ssl_post)
    @options.delete(:created_at)
    assert_raise(ArgumentError, "Missing required parameter: created_at") do
      @gateway.credit(@amount, "123;456;78901234567890", @options)
    end
  end

  def test_successful_credit_request
    @gateway.stubs(:ssl_post).returns(successful_capture_response, successful_credit_response)
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert response.test?
    assert response_capture = @gateway.credit(@amount, response.authorization, @options)
    assert_success response_capture
    assert response_capture.test?
  end
  
  def test_standalone_credit_using_token
    @gateway.expects(:ssl_post).returns(successful_credit_using_token_response)
    response = @gateway.standalone_credit(@amount, "2611552700460008299530", @options)

    assert_success response
    assert response.test?
  end
  
  def test_successful_credit_using_authorization_code_but_is_older_than_60_days
    @options[:token] = "2611552700460008299530"
    @options[:created_at] = 61.days.ago
    @gateway.expects(:ssl_post).returns(successful_credit_using_token_response)
    response = @gateway.credit(@amount, "123;456;78901234567890", @options)
    
    assert_success response
    assert response.test?
  end
  
  def test_credit_using_token_with_incorrect_token_should_fail
    @gateway.expects(:ssl_post).returns(unsuccessful_credit_using_token_response)
    @options[:token] = "2611552700460008299530"
    @options[:created_at] = 1.day.ago
    response = @gateway.credit(@amount, "fake-token-here", @options)
    
    assert_failure response
    assert response.test?
    
    assert_equal "One or more fields contains invalid data", response.message
  end

  def test_credit_builds_merchant_reference_code_from_identification
    @options.delete(:order_id)
    @gateway.expects(:ssl_post).with() do |url, xml|
      xml =~ /<merchantReferenceCode>xyz<\/merchantReferenceCode>/
    end.returns(successful_credit_response)
    assert response = @gateway.credit(@amount, "xyz;123;def", @options)
  end

  def test_standalone_credit_adds_default_merchant_reference_code_when_order_id_is_missing
    @options.delete(:order_id)
    @gateway.expects(:ssl_post).with() do |url, xml|
      xml =~ /<merchantReferenceCode>\d+<\/merchantReferenceCode>/
    end.returns(successful_credit_response)
    assert response = @gateway.standalone_credit(@amount, "abc123zyx", @options)
  end

private

  def auth_request
    @auth_request ||= @gateway.send :build_auth_request, @amount, @credit_card, @options
  end
  
  def successful_purchase_response
    <<-XML
<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
<soap:Header>
<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-2636690"><wsu:Created>2008-01-15T21:42:03.343Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.26"><c:merchantReferenceCode>b0a6cf9aa07f1a8495f89c364bbd6a9a</c:merchantReferenceCode><c:requestID>2004333231260008401927</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Afvvj7Ke2Fmsbq0wHFE2sM6R4GAptYZ0jwPSA+R9PhkyhFTb0KRjoE4+ynthZrG6tMBwjAtT</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccAuthReply><c:reasonCode>100</c:reasonCode><c:amount>1.00</c:amount><c:authorizationCode>123456</c:authorizationCode><c:avsCode>Y</c:avsCode><c:avsCodeRaw>Y</c:avsCodeRaw><c:cvCode>M</c:cvCode><c:cvCodeRaw>M</c:cvCodeRaw><c:authorizedDateTime>2008-01-15T21:42:03Z</c:authorizedDateTime><c:processorResponse>00</c:processorResponse><c:authFactorCode>U</c:authFactorCode></c:ccAuthReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end

  def successful_authorization_response
    <<-XML
<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
<soap:Header>
<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-32551101"><wsu:Created>2007-07-12T18:31:53.838Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.26"><c:merchantReferenceCode>TEST11111111111</c:merchantReferenceCode><c:requestID>1842651133440156177166</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>AP4JY+Or4xRonEAOERAyMzQzOTEzMEM0MFZaNUZCBgDH3fgJ8AEGAMfd+AnwAwzRpAAA7RT/</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccAuthReply><c:reasonCode>100</c:reasonCode><c:amount>1.00</c:amount><c:authorizationCode>004542</c:authorizationCode><c:avsCode>A</c:avsCode><c:avsCodeRaw>I7</c:avsCodeRaw><c:authorizedDateTime>2007-07-12T18:31:53Z</c:authorizedDateTime><c:processorResponse>100</c:processorResponse><c:reconciliationID>23439130C40VZ2FB</c:reconciliationID></c:ccAuthReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def unsuccessful_authorization_response
    <<-XML
<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
<soap:Header>
<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-28121162"><wsu:Created>2008-01-15T21:50:41.580Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.26"><c:merchantReferenceCode>a1efca956703a2a5037178a8a28f7357</c:merchantReferenceCode><c:requestID>2004338415330008402434</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>231</c:reasonCode><c:requestToken>Afvvj7KfIgU12gooCFE2/DanQIApt+G1OgTSA+R9PTnyhFTb0KRjgFY+ynyIFNdoKKAghwgx</c:requestToken><c:ccAuthReply><c:reasonCode>231</c:reasonCode></c:ccAuthReply></c:replyMessage></soap:Body></soap:Envelope>    
    XML
  end
   
  def successful_tax_response
    <<-XML
<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
<soap:Header>
<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-21248497"><wsu:Created>2007-07-11T18:27:56.314Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.26"><c:merchantReferenceCode>TEST11111111111</c:merchantReferenceCode><c:requestID>1841784762620176127166</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>AMYJY9fl62i+vx2OEQYAx9zv/9UBZAAA5h5D</c:requestToken><c:taxReply><c:reasonCode>100</c:reasonCode><c:grandTotalAmount>1.00</c:grandTotalAmount><c:totalCityTaxAmount>0</c:totalCityTaxAmount><c:city>Madison</c:city><c:totalCountyTaxAmount>0</c:totalCountyTaxAmount><c:totalDistrictTaxAmount>0</c:totalDistrictTaxAmount><c:totalStateTaxAmount>0</c:totalStateTaxAmount><c:state>WI</c:state><c:totalTaxAmount>0</c:totalTaxAmount><c:postalCode>53717</c:postalCode><c:item id="0"><c:totalTaxAmount>0</c:totalTaxAmount></c:item></c:taxReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end


  def successful_capture_response
    <<-XML
<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"> <soap:Header> <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-6000655"><wsu:Created>2007-07-17T17:15:32.642Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.26"><c:merchantReferenceCode>test1111111111111111</c:merchantReferenceCode><c:requestID>1846925324700976124593</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>AP4JZB883WKS/34BEZAzMTE1OTI5MVQzWE0wQjEzBTUt3wbOAQUy3D7oDgMMmvQAnQgl</c:requestToken><c:purchaseTotals><c:currency>GBP</c:currency></c:purchaseTotals><c:ccCaptureReply><c:reasonCode>100</c:reasonCode><c:requestDateTime>2007-07-17T17:15:32Z</c:requestDateTime><c:amount>1.00</c:amount><c:reconciliationID>31159291T3XM2B13</c:reconciliationID></c:ccCaptureReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end

  def successful_credit_response
    <<-XML
<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
<soap:Header>
<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-5589339"><wsu:Created>2008-01-21T16:00:38.927Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.32"><c:merchantReferenceCode>TEST11111111111</c:merchantReferenceCode><c:requestID>2009312387810008401927</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Af/vj7OzPmut/eogHFCrBiwYsWTJy1r127CpCn0KdOgyTZnzKwVYCmzPmVgr9ID5H1WGTSTKuj0i30IE4+zsz2d/QNzwBwAACCPA</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccCreditReply><c:reasonCode>100</c:reasonCode><c:requestDateTime>2008-01-21T16:00:38Z</c:requestDateTime><c:amount>1.00</c:amount><c:reconciliationID>010112295WW70TBOPSSP2</c:reconciliationID></c:ccCreditReply></c:replyMessage></soap:Body></soap:Envelope>  
    XML
  end
  
  def successful_store_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-26088371"><wsu:Created>2009-12-11T16:41:13.825Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2605496732830008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahj/7wSRGn0Pw/27AcQCIkGzlgzbs2TmsysR4zaZKTZJe5vuICmyS9zfcdIASQMMmkmVdHpKgmwJyI0+h+H+3YDiAQAA7SbN</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccAuthReply><c:reasonCode>100</c:reasonCode><c:amount>0.00</c:amount><c:authorizationCode>888888</c:authorizationCode><c:avsCode>X</c:avsCode><c:avsCodeRaw>I1</c:avsCodeRaw><c:authorizedDateTime>2009-12-11T16:41:13Z</c:authorizedDateTime><c:processorResponse>100</c:processorResponse><c:reconciliationID>69037329V2XGF6LJ</c:reconciliationID></c:ccAuthReply><c:paySubscriptionCreateReply><c:reasonCode>100</c:reasonCode><c:subscriptionID>2605496732830008402433</c:subscriptionID></c:paySubscriptionCreateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end

  def unsuccessful_store_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-3113717"><wsu:Created>2009-12-11T17:13:26.296Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2605516062390008430595</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>231</c:reasonCode><c:requestToken>Ahj77wSRGn2ZHEGF8IAGIpu5p2fa8BTdzTs+1+kAJIFOfSTKuj0lQTQFZEafZkcQYXwgAYAAtiU2</c:requestToken><c:ccAuthReply><c:reasonCode>231</c:reasonCode></c:ccAuthReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_retrieve_response
    <<-XML
      <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
      <soap:Header>
      <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-19066339"><wsu:Created>2009-12-11T17:51:54.978Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2605539149490008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>AhjzbwSRGn49J3I6uVQCIgKbJL3PYO0gBJAwyaSZV0ekqCaAaAAA8AMX</c:requestToken><c:paySubscriptionRetrieveReply><c:reasonCode>100</c:reasonCode><c:approvalRequired>false</c:approvalRequired><c:automaticRenew>true</c:automaticRenew><c:cardAccountNumber>411111XXXXXX1111</c:cardAccountNumber><c:cardExpirationMonth>12</c:cardExpirationMonth><c:cardExpirationYear>2020</c:cardExpirationYear><c:cardType>001</c:cardType><c:city>Mountain View</c:city><c:country>US</c:country><c:currency>USD</c:currency><c:email>null@cybersource.com</c:email><c:endDate>99991231</c:endDate><c:firstName>JOHNNY</c:firstName><c:frequency>on-demand</c:frequency><c:lastName>DOE</c:lastName><c:paymentMethod>credit card</c:paymentMethod><c:paymentsRemaining>0</c:paymentsRemaining><c:postalCode>94043</c:postalCode><c:startDate>20091212</c:startDate><c:state>CA</c:state><c:status>CANCELED</c:status><c:street1>1295 Charleston Road</c:street1><c:subscriptionID>2605522582930008402433</c:subscriptionID><c:totalPayments>0</c:totalPayments><c:merchantDefinedDataField1>boo</c:merchantDefinedDataField1><c:merchantDefinedDataField2>cry</c:merchantDefinedDataField2></c:paySubscriptionRetrieveReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def unsuccessful_retrieve_response
    <<-XML
      <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
      <soap:Header>
      <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-26828169"><wsu:Created>2009-12-11T21:04:00.367Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2605654403410008299530</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>102</c:reasonCode><c:requestToken>AhijLwSRGoFwFRr72rAUIpve8BjDsBJAozaSZV0ekqCaAAAAYgJy</c:requestToken><c:paySubscriptionRetrieveReply><c:reasonCode>102</c:reasonCode></c:paySubscriptionRetrieveReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_update_response
    <<-XML
      <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
      <soap:Header>
      <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-14541536"><wsu:Created>2009-12-14T17:46:31.838Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2608127916010008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>AhjzbwSRGsYXclB4xbQCIgKbJL4YVP0gBJCQyaSZV0ekqCaAmAAA7AFT</c:requestToken><c:paySubscriptionUpdateReply><c:reasonCode>100</c:reasonCode><c:subscriptionID>2605522582930008402433</c:subscriptionID></c:paySubscriptionUpdateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def unsuccessful_update_response
    <<-XML
      <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
      <soap:Header>
      <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-1477803"><wsu:Created>2009-12-14T17:47:36.047Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2608128559980008402433</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>231</c:reasonCode><c:requestToken>AhjzbwSRGsYcBbBe9twCIgKbJL4YWM0gBJCJz6SZV0ekqCaAqAAASwIo</c:requestToken><c:paySubscriptionUpdateReply><c:reasonCode>231</c:reasonCode></c:paySubscriptionUpdateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_unstore_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-20639837"><wsu:Created>2009-12-15T00:42:50.901Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>CANCELLED</c:merchantReferenceCode><c:requestID>2608377708580008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>AhijLwSRGs0GVFotiTwCIpskvigfoBJCQyaSZV0ekqCaAAAA4gDN</c:requestToken><c:paySubscriptionUpdateReply><c:reasonCode>100</c:reasonCode><c:subscriptionID>2608325603560008299530</c:subscriptionID></c:paySubscriptionUpdateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def unsuccessful_unstore_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-11837645"><wsu:Created>2009-12-15T00:43:17.804Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>CANCELLED</c:merchantReferenceCode><c:requestID>2608377977790008299530</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>102</c:reasonCode><c:requestToken>AhijLwSRGs0IPgraXSAUIpve8Dq1wBJCIzaSZV0ekqCaAAAA8AEd</c:requestToken><c:paySubscriptionUpdateReply><c:reasonCode>102</c:reasonCode></c:paySubscriptionUpdateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_auth_and_create_profile_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-611388"><wsu:Created>2009-12-18T15:48:54.340Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123499</c:merchantReferenceCode><c:requestID>2611513342530008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahj/7wSRGyQOWUfcWJQCIkGzlk5atmzKszcS4LdtTTZJ+02NgCmyT9psbNII4agkiIZNJMq6PSVBNgTkRskDllH3FiUAgAAA1gre</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccAuthReply><c:reasonCode>100</c:reasonCode><c:amount>1000.00</c:amount><c:authorizationCode>888888</c:authorizationCode><c:avsCode>X</c:avsCode><c:avsCodeRaw>I1</c:avsCodeRaw><c:authorizedDateTime>2009-12-18T15:48:54Z</c:authorizedDateTime><c:processorResponse>100</c:processorResponse><c:reconciliationID>69295662V38KA76S</c:reconciliationID></c:ccAuthReply><c:paySubscriptionCreateReply><c:reasonCode>100</c:reasonCode><c:subscriptionID>2611513342530008402433</c:subscriptionID></c:paySubscriptionCreateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_purchase_and_create_profile_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-10631959"><wsu:Created>2009-12-18T16:54:30.205Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123499</c:merchantReferenceCode><c:requestID>2611552700460008299530</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahj//wSRGyUmAPA10rgUIkGzlk5aMWrOOzcSqseq5Te+gd4GoCm99A7wNdII4agkiIZNJMq6PSVBNDAnIjZKTAHga6VwKAAA9QzY</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccAuthReply><c:reasonCode>100</c:reasonCode><c:amount>1000.00</c:amount><c:authorizationCode>888888</c:authorizationCode><c:avsCode>X</c:avsCode><c:avsCodeRaw>I1</c:avsCodeRaw><c:authorizedDateTime>2009-12-18T16:54:30Z</c:authorizedDateTime><c:processorResponse>100</c:processorResponse><c:reconciliationID>69294153G38JUGU9</c:reconciliationID></c:ccAuthReply><c:ccCaptureReply><c:reasonCode>100</c:reasonCode><c:requestDateTime>2009-12-18T16:54:30Z</c:requestDateTime><c:amount>1000.00</c:amount><c:reconciliationID>69294153G38JUGU9</c:reconciliationID></c:ccCaptureReply><c:paySubscriptionCreateReply><c:reasonCode>100</c:reasonCode><c:subscriptionID>2611552700460008299530</c:subscriptionID></c:paySubscriptionCreateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_authorize_using_token_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-5198340"><wsu:Created>2009-12-22T15:06:17.187Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123499</c:merchantReferenceCode><c:requestID>2614943771330008299530</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahj/7wSRG4NFAuri33AUIkGzlozbNGLmOzcSq06GxTe+gkaA4Cm99BI0B9IITiBJGQyaSZV0ekqCbAnIjcGigXVxb7gKAAAA8QdL</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccAuthReply><c:reasonCode>100</c:reasonCode><c:amount>400.00</c:amount><c:authorizationCode>888888</c:authorizationCode><c:avsCode>X</c:avsCode><c:avsCodeRaw>I1</c:avsCodeRaw><c:authorizedDateTime>2009-12-22T15:06:17Z</c:authorizedDateTime><c:processorResponse>100</c:processorResponse><c:reconciliationID>69436419G38JVNC1</c:reconciliationID></c:ccAuthReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def unsuccessful_authorize_using_token_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-8877718"><wsu:Created>2009-12-22T15:05:10.643Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:requestID>2614943105590008299530</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>102</c:reasonCode><c:requestToken>AhhBLwSRG4NAR/GKcoAVpEkYjNpJlXR6SoJozgZz</c:requestToken></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_purchase_using_token_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-28957907"><wsu:Created>2009-12-22T16:09:05.787Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123499</c:merchantReferenceCode><c:requestID>2614981452600008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahj//wSRG4RQwL+U9MwCIkGzlozbOWLGszcS4jSJBTZJ/GIYQCmyT+MQwtIITiBJGQyaSZV0ekqCaGBORG4RQwL+U9MwCAAA9wyG</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccAuthReply><c:reasonCode>100</c:reasonCode><c:amount>400.00</c:amount><c:authorizationCode>888888</c:authorizationCode><c:avsCode>X</c:avsCode><c:avsCodeRaw>I1</c:avsCodeRaw><c:authorizedDateTime>2009-12-22T16:09:05Z</c:authorizedDateTime><c:processorResponse>100</c:processorResponse><c:reconciliationID>69436911V38KD4DA</c:reconciliationID></c:ccAuthReply><c:ccCaptureReply><c:reasonCode>100</c:reasonCode><c:requestDateTime>2009-12-22T16:09:05Z</c:requestDateTime><c:amount>400.00</c:amount><c:reconciliationID>69436911V38KD4DA</c:reconciliationID></c:ccCaptureReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def unsuccessful_purchase_using_token_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-5569932"><wsu:Created>2009-12-22T16:09:37.092Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:requestID>2614981770500008402433</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>102</c:reasonCode><c:requestToken>AhhBLwSRG4RTAwFOGrwDpEkYjNpJlXR6SoJozAZz</c:requestToken></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_credit_using_token_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-33319815"><wsu:Created>2009-12-22T16:25:43.057Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2614991427750008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahj/fwSRG4SXoXDFnmQCIkGzlozbtGLSszcS4jSXSTZJ/GMQoCmyT+MYhdIFfRJGQyaSZV0ekqCaUBMAP0J0</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccCreditReply><c:reasonCode>100</c:reasonCode><c:requestDateTime>2009-12-22T16:25:42Z</c:requestDateTime><c:amount>10.00</c:amount><c:reconciliationID>69437414V38KD4KR</c:reconciliationID></c:ccCreditReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end

  def successful_credit_using_authorization_response_like_a_token_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-33319815"><wsu:Created>2009-12-22T16:25:43.057Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>123;456;78901234567890</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahj/fwSRG4SXoXDFnmQCIkGzlozbtGLSszcS4jSXSTZJ/GMQoCmyT+MYhdIFfRJGQyaSZV0ekqCaUBMAP0J0</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals><c:ccCreditReply><c:reasonCode>100</c:reasonCode><c:requestDateTime>2009-12-22T16:25:42Z</c:requestDateTime><c:amount>10.00</c:amount><c:reconciliationID>69437414V38KD4KR</c:reconciliationID></c:ccCreditReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end

  def unsuccessful_credit_using_token_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-14315492"><wsu:Created>2009-12-22T16:26:25.861Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:requestID>2614991858240008402433</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>102</c:reasonCode><c:requestToken>AhhBLwSRG4SasH9MrWwDpEkYjNpJlXR6SoJoSAZc</c:requestToken></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def successful_store_using_auth_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-6035221"><wsu:Created>2009-12-27T14:36:53.852Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:merchantReferenceCode>MRC-123456</c:merchantReferenceCode><c:requestID>2619246131100008402433</c:requestID><c:decision>ACCEPT</c:decision><c:reasonCode>100</c:reasonCode><c:requestToken>Ahjv7wSRG/qvHb/YcpwCIkGzlszcNnDZqzcSp9q1WTd0ASmlibJP73zy0gBJIwyaSZV0ekqCbAnIjf1WCKpDblwDAAAAaxOo</c:requestToken><c:paySubscriptionCreateReply><c:reasonCode>100</c:reasonCode><c:subscriptionID>2619246131100008402433</c:subscriptionID></c:paySubscriptionCreateReply></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
  
  def unsuccessful_store_using_auth_response
    <<-XML
    <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    <soap:Header>
    <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><wsu:Timestamp xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" wsu:Id="Timestamp-6006228"><wsu:Created>2009-12-27T14:35:25.411Z</wsu:Created></wsu:Timestamp></wsse:Security></soap:Header><soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.28"><c:requestID>2619245248280008402433</c:requestID><c:decision>REJECT</c:decision><c:reasonCode>102</c:reasonCode><c:invalidField>c:paySubscriptionCreateService/c:paymentRequestID</c:invalidField><c:requestToken>AhgBLwSRG/qo1+i/ckwDJIozaSZV0ekqCaAAIS6W</c:requestToken></c:replyMessage></soap:Body></soap:Envelope>
    XML
  end
end