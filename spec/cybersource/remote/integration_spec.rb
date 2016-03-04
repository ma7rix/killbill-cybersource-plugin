require 'spec_helper'

ActiveMerchant::Billing::Base.mode = :test

describe Killbill::Cybersource::PaymentPlugin do

  include ::Killbill::Plugin::ActiveMerchant::RSpec

  before(:each) do
    ::Killbill::Cybersource::CybersourcePaymentMethod.delete_all
    ::Killbill::Cybersource::CybersourceResponse.delete_all
    ::Killbill::Cybersource::CybersourceTransaction.delete_all

    @plugin = build_plugin(::Killbill::Cybersource::PaymentPlugin, 'cybersource')
    @plugin.start_plugin

    @call_context = build_call_context

    @properties = []
    @pm         = create_payment_method(::Killbill::Cybersource::CybersourcePaymentMethod, nil, @call_context.tenant_id, @properties)
    @amount     = BigDecimal.new('100')
    @currency   = 'USD'

    kb_payment_id = SecureRandom.uuid
    1.upto(6) do
      @kb_payment = @plugin.kb_apis.proxied_services[:payment_api].add_payment(kb_payment_id)
    end
  end

  after(:each) do
    @plugin.stop_plugin
  end

  let(:with_report_api) do
    @plugin.get_report_api(@call_context.tenant_id).present?
  end

  it 'should be able to charge a Credit Card directly and calls should be idempotent' do
    properties = build_pm_properties

    # We created the payment method, hence the rows
    Killbill::Cybersource::CybersourceResponse.all.size.should == 1
    Killbill::Cybersource::CybersourceTransaction.all.size.should == 0

    payment_response = @plugin.purchase_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == @amount
    payment_response.transaction_type.should == :PURCHASE
    payment_response.first_payment_reference_id.should_not be_nil
    payment_response.second_payment_reference_id.should_not be_nil
    payment_response.gateway_error_code.should_not be_nil

    responses = Killbill::Cybersource::CybersourceResponse.all
    responses.size.should == 2
    responses[0].api_call.should == 'add_payment_method'
    responses[0].message.should == 'Successful transaction'
    responses[1].api_call.should == 'purchase'
    responses[1].message.should == 'Successful transaction'
    transactions = Killbill::Cybersource::CybersourceTransaction.all
    transactions.size.should == 1
    transactions[0].api_call.should == 'purchase'

    # Skip the rest of the test if the report API isn't configured
    break unless with_report_api

    payment_response = @plugin.purchase_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    payment_response.amount.should == @amount
    payment_response.status.should == :PROCESSED
    payment_response.transaction_type.should == :PURCHASE
    # No extra data when handling dups - use the get API to retrieve the details (what Kill Bill does internally too)
    payment_response.first_payment_reference_id.should be_nil
    payment_response.second_payment_reference_id.should be_nil
    payment_response.gateway_error_code.should be_nil

    responses = Killbill::Cybersource::CybersourceResponse.all
    responses.size.should == 3
    responses[0].api_call.should == 'add_payment_method'
    responses[0].message.should == 'Successful transaction'
    responses[1].api_call.should == 'purchase'
    responses[1].message.should == 'Successful transaction'
    responses[2].api_call.should == 'purchase'
    responses[2].message.should == 'Skipped Gateway call'
    transactions = Killbill::Cybersource::CybersourceTransaction.all
    transactions.size.should == 2
    transactions[0].api_call.should == 'purchase'
    transactions[0].txn_id.should_not be_nil
    transactions[1].api_call.should == 'purchase'
    transactions[1].txn_id.should be_nil
  end

  it 'should be able to fix UNDEFINED payments' do
    payment_response = @plugin.purchase_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error

    # Force a transition to :UNDEFINED
    Killbill::Cybersource::CybersourceTransaction.last.delete
    response = Killbill::Cybersource::CybersourceResponse.last
    response.update(:message => {:payment_plugin_status => 'UNDEFINED'}.to_json)

    skip_gw = Killbill::Plugin::Model::PluginProperty.new
    skip_gw.key = 'skip_gw'
    skip_gw.value = 'true'
    properties_with_skip_gw = @properties.clone
    properties_with_skip_gw << skip_gw

    # Set skip_gw=true, to avoid calling the report API
    transaction_info_plugins = @plugin.get_payment_info(@pm.kb_account_id, @kb_payment.id, properties_with_skip_gw, @call_context)
    transaction_info_plugins.size.should == 1
    transaction_info_plugins.first.status.should eq(:UNDEFINED)

    # Skip if the report API isn't configured
    if with_report_api
      # Fix it
      transaction_info_plugins = @plugin.get_payment_info(@pm.kb_account_id, @kb_payment.id, @properties, @call_context)
      transaction_info_plugins.size.should == 1
      transaction_info_plugins.first.status.should eq(:PROCESSED)

      # Set skip_gw=true, to check the local state
      transaction_info_plugins = @plugin.get_payment_info(@pm.kb_account_id, @kb_payment.id, properties_with_skip_gw, @call_context)
      transaction_info_plugins.size.should == 1
      transaction_info_plugins.first.status.should eq(:PROCESSED)
    end

    # Compare the state of the old and new response
    new_response = Killbill::Cybersource::CybersourceResponse.last
    new_response.id.should == response.id
    new_response.api_call.should == 'purchase'
    new_response.kb_tenant_id.should == @call_context.tenant_id
    new_response.kb_account_id.should == @pm.kb_account_id
    new_response.kb_payment_id.should == @kb_payment.id
    new_response.kb_payment_transaction_id.should == @kb_payment.transactions[0].id
    new_response.transaction_type.should == 'PURCHASE'
    new_response.payment_processor_account_id.should == 'default'
    # The report API doesn't give us the token
    new_response.authorization.split(';')[0..1].should == response.authorization.split(';')[0..1]
    new_response.test.should be_true
    new_response.params_merchant_reference_code.should == response.params_merchant_reference_code
    new_response.params_decision.should == response.params_decision
    new_response.params_request_token.should == response.params_request_token
    new_response.params_currency.should == response.params_currency
    new_response.params_amount.should == response.params_amount
    new_response.params_authorization_code.should == response.params_authorization_code
    new_response.params_avs_code.should == response.params_avs_code
    new_response.params_avs_code_raw.should == response.params_avs_code_raw
    new_response.params_reconciliation_id.should == response.params_reconciliation_id
    new_response.success.should be_true
    new_response.message.should == (with_report_api ? 'Request was processed successfully.' : '{"payment_plugin_status":"UNDEFINED"}')
  end

  it 'should be able to charge and refund' do
    payment_response = @plugin.purchase_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == @amount
    payment_response.transaction_type.should == :PURCHASE

    # Try a full refund
    refund_response = @plugin.refund_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[1].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    refund_response.status.should eq(:PROCESSED), refund_response.gateway_error
    refund_response.amount.should == @amount
    refund_response.transaction_type.should == :REFUND
  end

  it 'should be able to auth, capture and refund' do
    payment_response = @plugin.authorize_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == @amount
    payment_response.transaction_type.should == :AUTHORIZE

    # Try multiple partial captures
    partial_capture_amount = BigDecimal.new('10')
    1.upto(3) do |i|
      payment_response = @plugin.capture_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[i].id, @pm.kb_payment_method_id, partial_capture_amount, @currency, @properties, @call_context)
      payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
      payment_response.amount.should == partial_capture_amount
      payment_response.transaction_type.should == :CAPTURE
    end

    # Try a partial refund
    refund_response = @plugin.refund_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[4].id, @pm.kb_payment_method_id, partial_capture_amount, @currency, @properties, @call_context)
    refund_response.status.should eq(:PROCESSED), refund_response.gateway_error
    refund_response.amount.should == partial_capture_amount
    refund_response.transaction_type.should == :REFUND

    # Try to capture again
    payment_response = @plugin.capture_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[5].id, @pm.kb_payment_method_id, partial_capture_amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == partial_capture_amount
    payment_response.transaction_type.should == :CAPTURE
  end

  it 'should be able to auth and void' do
    payment_response = @plugin.authorize_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == @amount
    payment_response.transaction_type.should == :AUTHORIZE

    payment_response = @plugin.void_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[1].id, @pm.kb_payment_method_id, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.transaction_type.should == :VOID
  end

  it 'should be able to auth, partial capture and void' do
    payment_response = @plugin.authorize_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == @amount
    payment_response.transaction_type.should == :AUTHORIZE

    partial_capture_amount = BigDecimal.new('10')
    payment_response       = @plugin.capture_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[1].id, @pm.kb_payment_method_id, partial_capture_amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == partial_capture_amount
    payment_response.transaction_type.should == :CAPTURE

    payment_response = @plugin.void_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[2].id, @pm.kb_payment_method_id, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.transaction_type.should == :VOID
    Killbill::Cybersource::CybersourceResponse.last.params_amount.should == '10.00'

    # From the CyberSource documentation:
    # When you void a capture, a hold remains on the unused credit card funds. If you are not going to re-capture the authorization as described in "Capture After Void," page 71, and if
    # your processor supports authorization reversal after void as described in "Authorization Reversal After Void," page 39, CyberSource recommends that you request an authorization reversal
    # to release the hold on the unused credit card funds.
    payment_response = @plugin.void_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[3].id, @pm.kb_payment_method_id, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.transaction_type.should == :VOID
    Killbill::Cybersource::CybersourceResponse.last.params_amount.should == '100.00'
  end

  it 'should be able to credit' do
    payment_response = @plugin.credit_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, @pm.kb_payment_method_id, @amount, @currency, @properties, @call_context)
    payment_response.status.should eq(:PROCESSED), payment_response.gateway_error
    payment_response.amount.should == @amount
    payment_response.transaction_type.should == :CREDIT
  end

  # See https://github.com/killbill/killbill-cybersource-plugin/issues/4
  it 'handles errors gracefully' do
    properties_with_no_expiration_year = build_pm_properties
    cc_exp_year = properties_with_no_expiration_year.find { |prop| prop.key == 'ccExpirationYear' }
    cc_exp_year.value = nil

    payment_response = @plugin.purchase_payment(@pm.kb_account_id, @kb_payment.id, @kb_payment.transactions[0].id, SecureRandom.uuid, @amount, @currency, properties_with_no_expiration_year, @call_context)
    payment_response.status.should eq(:ERROR), payment_response.gateway_error
  end
end
