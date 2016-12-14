module Adash
  class Config

    open("#{File.expand_path('../../../data', __FILE__)}/client", 'r') do |f|
      @@client_id = f.readline.chomp
      @@client_secret = f.readline.chomp
      @@redirect_port = f.readline.chomp.to_i
    end

    def self.client_id
      @@client_id
    end

    def self.client_secret
      @@client_secret
    end

    def self.redirect_port
      @@redirect_port
    end
  end
end