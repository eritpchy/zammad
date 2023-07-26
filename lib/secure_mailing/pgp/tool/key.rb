# Copyright (C) 2012-2023 Zammad Foundation, https://zammad-foundation.org/

module SecureMailing::PGP::Tool::Key
  extend ActiveSupport::Concern

  include SecureMailing::PGP::Tool::Exec

  included do

    def import(key)
      gpg('import', stdin: key)
    end

    def export(fingerprint, passphrase = nil, secret: false)
      options = %w[
        --export-options export-minimal
        --armor
      ]
      command = secret ? 'export-secret-key' : 'export'

      result = gpg(command, options: options, arguments: [fingerprint], passphrase: passphrase)
      return result if result.stdout.present?

      error_export!(result.stderr, secret)
    end

    def passphrase(fingerprint, passphrase)
      options = %w[--dry-run]

      result = gpg('passwd', options: options, arguments: [fingerprint], passphrase: passphrase)
      return result if result.stderr.blank?

      error_passphrase!(result.stderr)
    end
  end
end
