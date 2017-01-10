require 'adash/version'
require 'adash/config'
require 'adash/wait_indefinitely'
require 'readline'
require 'fileutils'
require 'yaml'
require 'amazon-drs'

# TODO: Use each class for return
module Adash
  class Manager
    def initialize
    end

    def sub_init(name, device_model, is_test)
      serial = generate_serial(device_model)
      credentials = get_credentials
      authorized_devices = credentials['authorized_devices']
      hit = authorized_devices&.find_index { |d| d['device_model'] == device_model }
      if hit
        puts "Adash knows device what is #{device_model}."
        return 3
      end
      hit = authorized_devices&.find_index { |d| d['name'] == name }
      if hit
        puts "Adash knows device what is named #{name}."
        return 4
      end
      wi = Adash::WaitIndefinitely.new(device_model, serial)
      Signal.trap(:INT){ wi.shutdown }
      code = wi.get_code
      FileUtils.mkdir_p(File.expand_path('..', Adash::Config.credentials_path))
      new_device = {
        'name' => name,
        'device_model' => device_model,
        'serial' => serial,
        'authorization_code' => code,
        'redirect_uri' => wi.redirect_uri
      }
      new_device['is_test'] = true if is_test
      credentials['authorized_devices'] << new_device
      save_credentials(credentials)
      client = create_client_from_device(new_device)
      client.get_token
      0
    end

    def sub_list
      credentials = get_credentials
      credentials['authorized_devices'].each do |device|
        puts "---- name: #{device['name']}"
        puts "* device_model: #{device['device_model']}"
        puts "  serial: #{device['serial']}"
        puts '  THIS DEVICE IS TEST PURCHASE MODE' if device['is_test']
      end
      0
    end

    def sub_deregistrate(name)
      device = get_device_by_name(name)
      unless device
        puts "Device #{name} not found"
        return 5
      end
      client = create_client_from_device(device)
      resp = client.deregistrate_device
      save_credentials_without_device_model(device['device_model'])
      0
    end

    def sub_list_slot(name)
      device = get_device_by_name(name)
      unless device
        puts "Device #{name} not found"
        return 5
      end
      client = create_client_from_device(device)
      resp = client.subscription_info
      index = 0
      resp.slots.each do |slot_id, available|
        puts "---- #{index}"
        puts "* slot_id: #{slot_id}"
        puts "  available: #{available}"
        index =+ 1
      end
      0
    end

    def sub_replenish(name, slot_id)
      device = get_device_by_name(name)
      unless device
        puts "Device #{name} not found"
        return 5
      end
      client = create_client_from_device(device)
      slot_id = select_slot_prompt(client) unless slot_id
      resp = client.replenish(slot_id)
      if resp.json['message']
        puts "ERROR: #{resp.json['message']}"
      else
        case resp.json['detailCode']
        when 'STANDARD_ORDER_PLACED'
          puts 'Succeeded to order.'
        when 'ORDER_INPROGRESS'
          puts 'The order is in progress.'
        end
      end
      0
    end

    def generate_serial(device_model)
      orig = [('a'..'z'), ('A'..'Z'), ('0'..'9')].map { |i| i.to_a }.flatten
      random_suffix = (0...16).map { orig[rand(orig.size)] }.join
      "#{device_model}_#{Time.now.to_i}_#{random_suffix}"
    end
    private :generate_serial

    def get_credentials
      if File.exist?(Adash::Config.credentials_path)
        credentials = YAML.load_file(Adash::Config.credentials_path)
      else
        { 'authorized_devices' => [] }
      end
    end
    private :get_credentials

    def save_credentials(credentials)
      open(Adash::Config.credentials_path, 'w') do |f|
        f.write(credentials.to_yaml)
      end
    end
    private :save_credentials

    def get_device_from_credentials(credentials, device_model)
      i = credentials['authorized_devices'].find_index { |d| d['device_model'] == device_model }
      if i
        credentials['authorized_devices'][i]
      else
        nil
      end
    end
    private :get_device_from_credentials

    def save_credentials_with_device(credentials, device)
      i = credentials['authorized_devices'].find_index { |d| d['device_model'] == device['device_model'] }
      if i
        credentials['authorized_devices'][i] = device
      else
        credentials['authorized_devices'] << device
      end
      save_credentials(credentials)
    end
    private :save_credentials_with_device

    def save_credentials_without_device_model(device_model)
      credentials = get_credentials
      credentials['authorized_devices'] = credentials['authorized_devices'].delete_if { |d| d['device_model'] == device_model }
      save_credentials(credentials)
    end
    private :save_credentials_without_device_model

    def create_client_from_device(device)
      AmazonDrs::Client.new(device['device_model']) do |c|
        c.authorization_code = device['authorization_code']
        c.serial = device['serial']
        c.redirect_uri = device['redirect_uri']
        c.access_token = device['access_token']
        c.refresh_token = device['refresh_token']
        c.client_id = Adash::Config.client_id
        c.client_secret = Adash::Config.client_secret
        c.redirect_uri = "http://localhost:#{Adash::Config.redirect_port}/"
        c.on_new_token = proc { |access_token, refresh_token|
          credentials = get_credentials
          updated_device = get_device_from_credentials(credentials, device['device_model'])
          updated_device['access_token'] = access_token
          updated_device['refresh_token'] = refresh_token
          save_credentials_with_device(credentials, updated_device)
          device['device_model']
        }
      end
    end
    private :create_client_from_device

    def get_device_by_name(name)
      credentials = get_credentials
      hit = credentials['authorized_devices'].find_index { |d| d['name'] == name }
      if hit
        device = credentials['authorized_devices'][hit]
      else
        nil
      end
    end
    private :get_device_by_name

    def show_slots(slots)
      index = 0
      slots.each do |slot_id, available|
        puts
        puts "---- number: #{index}"
        puts "* slot_id: #{slot_id}"
        puts "  available: #{available}"
        puts
        index =+ 1
      end
    end
    private :show_slots

    def select_slot_prompt(client)
      resp = client.subscription_info
      slots = resp.json['slotsSubscriptionStatus'].select{ |k, v| v }
      if slots.size == 1
        return slots.keys.first
      end
      loop do
        show_slots(slots)
        slot_num = Readline.readline('Select slot number> ')
        if (0..(slots.size - 1)).member?(slot_num.to_i)
          break slots.keys[slot_num.to_i]
        else
          puts "ERROR: #{slot_num} is out of Range"
        end
      end
    end
    private :select_slot_prompt
  end
end
