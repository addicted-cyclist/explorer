class ApplicationMailer < ActionMailer::Base
  # Devise's configured sender ("no-reply@expl.pro", MAILER_FROM in
  # production). A hard-coded from here would silently override
  # config.action_mailer.default_options and mail from the wrong address.
  default from: Devise.mailer_sender
  layout "mailer"
end
