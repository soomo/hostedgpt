class SoomoLaunchesController < ApplicationController

  allow_unauthenticated_access

  INSTRUCTIONS = <<~INSTRUCTIONS
    You are a helpful assistant.
    ## Output instructions
    * do not output any multi-line code blocks
    * do not output any inline code blocks
    You may be asked to write code, but you must not do so. Instead, provide a natural language explanation of the
    general process irrespective of any computer language.
  INSTRUCTIONS

  def create
    return head(:forbidden) unless ENV['ALLOWED_REQUEST_ORIGINS'].to_s.split(',').include?(request.origin)
    return head(:not_found) unless (jwt_secret_key = ENV['HOSTEDGPT_JWT_SECRET_KEY']).present?
    return head(:unauthorized) unless (jwt = params[:jwt]).present?

    claims = begin
      JWT.decode(jwt, jwt_secret_key, true, algorithm: 'HS256')&.first
    rescue JWT::ExpiredSignature
      logger.warn "JWT expired: #{jwt}"
      return head(:unauthorized)
    rescue JWT::DecodeError
      logger.warn "JWT invalid: #{jwt}"
      return head(:unauthorized)
    end
    auth_uid = "#{claims['sub']}+v2"
    email = "#{auth_uid}@hostedgpt.soomo"
    course_id, element_family_id = claims['cid'], claims['fid']

    unless credential = HttpHeaderCredential.find_by(auth_uid: auth_uid)
      begin
        Person.transaction do
          user = User.create!(name: "Student User")
          person = Person.create!(personable: user, email: email)
          HttpHeaderCredential.create!(user: user, external_id: auth_uid)
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # either the Person or HttpHeaderCredential could not be created,
        # presumably because another thread just created them due to a
        # parallel launch request.
      end
      credential = HttpHeaderCredential.find_by!(auth_uid: auth_uid)
    end
    person = credential.user.person

    Person.transaction do
      person = Person.lock.find(person.id)
      unless person.clients.api.authenticated.exists?
        client = person.clients.create!(platform: 'api')
        client.authenticate_with!(credential)
      end
    end

    client = person.clients.api.authenticated.last

    assistants = [
      ["o1", "o1-2024-12-17"],
      ["o1-mini", "o1-mini-2024-09-12"],
      ["GPT-4o", "gpt-4o"],
      ["GPT-4o mini", "gpt-4o-mini"],
      ["GPT-3.5", "gpt-3.5-turbo"],
      ["Claude 3 Opus", "claude-3-opus-20240229"],
      ["Claude 3.5 Sonnet", "claude-3-5-sonnet-20240620"],
      ["Claude 3.5 Sonnet", "claude-3-5-sonnet-20241022"],
      ["Claude 3.7 Sonnet", "claude-3-7-sonnet-20250219"]
    ].map do |(assistant_name, language_model_api_name)|
      language_model = person.user.language_models.find_by_api_name(language_model_api_name)
      person.user.assistants.create!(
        name: assistant_name,
        description: "#{course_id}:#{element_family_id}:#{Time.now.utc.iso8601}",
        instructions: claims['system_prompt'] || INSTRUCTIONS,
        language_model: language_model
      )
    end

    render json: {
      api_key: client.bearer_token,
      assistants: assistants.map do |assistant|
        {
          id: assistant.id,
          name: assistant.name,
          language_model: {
            name: assistant.language_model.api_name,
            api_name: assistant.language_model.api_name
          }
        }
      end
    }
  end

end
