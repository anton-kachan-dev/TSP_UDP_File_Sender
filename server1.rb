require 'socket'
require 'colorize'
require './command'
require 'pry'
require './send_file_manager'
require './recv_file_manager'

class Server
  #include Socket::Constants
  include Command
  F_SETOWN = 8   # set manual as not defined in Fcntl

  def initialize(ip_address: 'localhost', port: '3002',package_size: 60)
    @ip_address = ip_address
    @port = port
    @package_size = package_size
    @header_size = 40
    @oob_char = '?'
    open_server
    @clients = []
    wait_clients
  end

  def open_server
    @server = Socket.new Socket::AF_INET, Socket::SOCK_STREAM, 0
    @server.bind( Socket.sockaddr_in(@port, @ip_address) )
    @server.listen(5)

    @server_udp = Socket.new Socket::AF_INET, Socket::SOCK_DGRAM, 0
    @server_udp.bind( Socket.sockaddr_in(@port, @ip_address) )
    puts 'Server is running!'
  end

  def wait_clients
    puts "Waiting clients"
    loop do
      if (soket =  @server.accept)
        @client, @client_address = soket
        puts "Connected client with ip: #{address}"
        check_client
        listen_client
      end
    end
  end

  def check_client
    if current_client && (current_client[:download_file_name] || current_client[:upload_file_name])
      continue_downloading if current_client[:download_file_name]
      continue_uploading if current_client[:upload_file_name]
    else
      @client.send "Welcome to server\r\nYou can enter commands: ls <dir> | cd <dir> | echo <> | time |shutdown\r\n", 0
      save_client(address)
    end
  end

  def continue_downloading
    message = 'download_continue ' + current_client[:download_file_name].to_s + ' ' + current_client[:download_file_size].to_s
    @client.send(message, 0)
    get_file(file_name: current_client[:download_file_name], file_mode: 'a')
  end

  def continue_uploading
    message = 'upload_continue ' + current_client[:upload_file_name].to_s
    @client.send(message, 0)
    file_downloaded_size = @client.recv(50)
    send_file(file_name: current_client[:upload_file_name], file_position: file_downloaded_size)
  end

  def current_client
    @clients.select {|client| client[:address] == address}.first
  end

  def address
    @client_address.ip_address
  end

  def save_client address
    client = {}
    client[:address] = address
    client[:upload_file_name] = nil
    client[:upload_file_size] = nil
    client[:download_file_name] = nil
    client[:download_file_size] = nil
    @clients.push(client) unless @clients.include?(client)

  end

  def save_download_information file_name, file_size
    @clients.each do  |client|
      if client[:address] == address
        client[:download_file_name] =  file_name
        client[:download_file_size] =  file_size
      end
    end
  end

  def save_upload_information file_name
    @clients.each do  |client|
      if client[:address] == address
        client[:upload_file_name] =  file_name
      end
    end
  end

  def listen_client
    loop do
      inputs = @client.recv(50)
      cmd, *arg = inputs.split
      case cmd
        when "ls" then @client.send(Command.ls, 0)
        when "cd" then @client.send(Command.cd(arg[0]), 0)
        when "shutdown", 'close', 'exit', 'quit' then @client.close; return
        when "echo" then  @client.puts arg[0]
        when "time" then  @client.send(Command.time, 0)
        when 'download' then send_file(file_name: arg[0], protocol: arg[1])
        when 'upload' then get_file(file_name: arg[0], protocol: arg[1], file_mode: arg[2] || 'wb')
        else
          @client.send("Invalid Command!\n\r", 0)
          print inputs
      end
    end
  rescue Errno::ENOENT
    STDERR.puts 'No such file! Use the <ls> command'
  rescue Errno::EPIPE
    STDERR.puts "Connection broke!"
    @client.close
    wait_clients
  rescue Errno::ECONNRESET
    STDERR.puts "Connection reset by peer!"
    @client.close
    wait_clients
  rescue  IOError
    STDERR.puts "Closed stream!"  
    retry
  end

  def send_file(file_name: nil, file_position: 0, protocol: 'tcp')
    if protocol == 'udp'
      package, addr = @server_udp.recvfrom(20)
      sender = SendFileManager.new(@server_udp, addr)
      result = sender.send_file_udp(file_name, file_position)
    else
      sender = SendFileManager.new(@client)
      result = sender.send_file(file_name, file_position)

      if result
        save_upload_information(nil)
      else
        save_upload_information(file_name)
        @client.close
        wait_clients
      end
    end
  rescue Errno::EPIPE, Errno::ECONNRESET
    STDERR.puts "Connection broke or reset by peer!"
    save_upload_information(file_name)
    @client.close
    wait_clients
  end

  def get_file(file_name: nil, file_mode: 'wb', protocol: 'tcp')
    if protocol == 'udp'
      recver = RecvFileManager.new(@server_udp)
      result = recver.get_file_udp(file_name, file_mode)
    else
      puts 'tcp'
      recver = RecvFileManager.new(@client)
      result = recver.get_file(file_name, file_mode)
    end
    if result
      save_download_information(nil, nil)
    else
      file = open("server/#{file_name}", 'rb')
      save_download_information(file_name, file.size)
    end
  end
end
