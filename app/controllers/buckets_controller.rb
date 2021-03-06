class BucketsController < ApplicationController
  include ActionController::Live

  respond_to :html, :json

  skip_before_action :verify_authenticity_token, only: %i[record create]

  before_action :check_ownership!, only: %i[clear destroy]

  def requests_count
    response.headers['Content-Type'] = 'text/event-stream'
    sse = SSE.new(response.stream, event: 'emails_count')

    emails = bucket.emails.gte(updated_at: 6.seconds.ago).to_a.map do |email|
      SimpleEmailSerializer.new(email)
    end

    begin
      sse.write(emails_count: bucket.emails.count, emails: emails)
    rescue ClientDisconnected
    ensure
      sse.close
    end
  end

  def create
    bucket = Bucket.create(
      owner_token: owner_token,
      user_id: current_user&.id,
      token: params[:token]
    )

    redirect_to bucket_path(bucket.token)
  end

  def clear
    bucket.clear_history

    redirect_to bucket_path(bucket.token)
  end

  def destroy
    bucket.destroy

    redirect_to root_path
  end

  def show
    @emails = bucket.emails.page(params[:page]).per(50)

    respond_to do |format|
      format.html { render }
      format.json { render json: @emails }
    end
  end

  def record
    email_params = params.slice('headers', 'subject', 'text', 'html')

    charsets = JSON.parse(params['charsets'])

    # http://stackoverflow.com/a/14011481
    from = encode_body(params, 'from', charsets)

    return head :ok unless from.valid_encoding?

    from = from.match(/(?:"?([^"]*)"?\s)?(?:<?(.+@[^>]+)>?)/)

    email_params['from_name']  = from[1]
    email_params['from_email'] = from[2]

    envelope = JSON.parse(params['envelope'])
    email_params['to']    = envelope['to'].to_a.dup
    email_params['email'] = envelope['to'].select { |to| to.downcase.end_with? '@parse.mailingbox.tech' }.first

    email_params['attachments'] = JSON.parse(params['attachment-info']).values if params['attachment-info'].present?

    email_params['text'] = encode_body(email_params, 'text', charsets)
    email_params['html'] = encode_body(email_params, 'html', charsets)

    return head :ok if !email_params['text'].to_s.valid_encoding? || !email_params['html'].to_s.valid_encoding?

    email_params = email_params.permit(
      :headers,
      :from_email,
      :from_name,
      :subject,
      :text,
      :html,
      :subject,
      :email,
      :charsets,
      to: [],
      attachments: %i[filename name type]
    )

    # See https://rollbar.com/putsbox/putsbox/items/15
    # request.POST.charsets  {"to":"UTF-8","html":"us-ascii","subject":"UTF-8","from":"UTF-8","text":"us-ascii"}
    RecordEmail.call!(
      token: email_params['email'].gsub(/\@.*/, ''),
      email: Email.new(email_params),
      request: request
    )

    head :ok
  end

  def encode_body(params, key, charsets)
    return params[key] if params[key].nil? || charsets[key].nil?

    params[key].to_s.encode('UTF-8', charsets[key], invalid: :replace, undef: :replace, replace: '')
  end
end
