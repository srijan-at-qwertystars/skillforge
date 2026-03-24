# Service Object Pattern Template
#
# Usage:
#   result = Users::RegistrationService.call(params)
#   if result.success?
#     # result.data contains the created user
#   else
#     # result.errors contains error messages
#   end
#
# Place in: app/services/<namespace>/<name>_service.rb

module Users
  class RegistrationService
    # ── Result object ───────────────────────────────────────────────────────
    Result = Struct.new(:success?, :data, :errors, keyword_init: true) do
      def failure? = !success?
    end

    # ── Class-level shortcut ────────────────────────────────────────────────
    def self.call(...) = new(...).call

    # ── Initialize with dependencies ────────────────────────────────────────
    def initialize(params, notifier: UserMailer)
      @params   = params
      @notifier = notifier
    end

    # ── Main entry point ────────────────────────────────────────────────────
    def call
      validate!
      user = create_user
      send_welcome_email(user)
      success(user)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages)
    rescue ValidationError => e
      failure([e.message])
    end

    private

    attr_reader :params, :notifier

    # ── Validation ──────────────────────────────────────────────────────────
    class ValidationError < StandardError; end

    def validate!
      raise ValidationError, "Email is required" if params[:email].blank?
      raise ValidationError, "Password is required" if params[:password].blank?
      raise ValidationError, "Email already taken" if User.exists?(email: params[:email])
    end

    # ── Business logic ──────────────────────────────────────────────────────
    def create_user
      ActiveRecord::Base.transaction do
        user = User.create!(
          email:    params[:email],
          password: params[:password],
          name:     params[:name]
        )
        user.create_profile!(bio: params[:bio]) if params[:bio].present?
        user
      end
    end

    def send_welcome_email(user)
      notifier.welcome(user).deliver_later
    end

    # ── Result helpers ──────────────────────────────────────────────────────
    def success(data)
      Result.new(success?: true, data: data, errors: [])
    end

    def failure(errors)
      Result.new(success?: false, data: nil, errors: Array(errors))
    end
  end
end
