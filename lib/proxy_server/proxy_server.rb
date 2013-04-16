#encoding: utf-8
require 'rubygems'
require 'yaml'
require 'json'
require 'base64'
require 'proxy_server/stub_server'

#解决jruby下的一个bug
module EventMachine
  class Connection
    def close_connection after_writing = false
      EM.next_tick do
        EventMachine::close_connection @signature, after_writing
      end
    end
  end
end


module ProxyServer
#存放request和response的结构。data可人可读可写的数据，raw为真正在底层传输的数据
  class ProxyRequest
    attr_accessor :data
    attr_accessor :raw

    def initialize
      @data=''
      @raw=''
    end
  end

  class ProxyResponse
    attr_accessor :data
    attr_accessor :raw

    def initialize
      @data=''
      @raw=''
    end
  end


  class ProxyServer
    #config['host']  config['port'] config['forward_host'] config['forward_port']

    attr_accessor :em_run
    attr_accessor :server_run
    attr_accessor :proxy

    def initialize(config)
      @config=config
      @thread=nil
      @proxy=nil
      @stub=nil
      @mocks=[]
      @request=ProxyRequest.new
      @response=ProxyResponse.new
      @raw_req=nil
      @raw_res=nil
      @@em_run=false
    end

    #解码二进制，返回可读数据
    def decode_request(req)
      req.data=req.raw
    end

    #解码二进制，返回可读数据
    def decode_response(res)
      res.data=res.raw
    end

    #可读数据组装为二进制
    def encode_request(req)
      req.raw=req.data
    end

    def encode_response(res)
      res.raw=res.data
    end

    #提供用户机制干预结果。
    #可参考测试用例中的mock方法
    def mock_process(req, res)
      @mocks.each do |m|
        m.call(req, res)
      end
    end

    def mock(&blk)
      @mocks<< blk
    end

    def run(conn)
      #始终以代理的方式运行，如果没有设置转发，就自己自我转发
      if @config['forward_host']
        conn.server :forward, :host => @config['forward_host'], :port => @config['forward_port']||80
      else
        @stub=StubServer.new
        @stub.start
        conn.server :forward, :host => '127.0.0.1', :port => 65530
      end
      # modify / process request stream
      conn.on_data do |raw_req|
        @request.raw=raw_req
        self.decode_request(@request)
        self.encode_request(@request)
        #must return the raw data
        @request.raw
      end
      # modify / process response stream
      conn.on_response do |backend, raw_res|
        @response.raw=raw_res
        self.decode_response(@response)
        self.mock_process(@request, @response)
        self.encode_response(@response)

        #此处如果用于多转发时，需要增加多转发时候的请求销毁，暂未用到，所以保持现状
        #must return raw data
        @response.raw
      end

      # termination logic
      conn.on_finish do |backend, name|
        # terminate connection (in duplex mode, you can terminate when prod is done)
        # unbind if backend == :srv
      end
    end

    def start(debug=false)
      server=self
      #在后台启动，防止block进程
      Thread.new do
        EM.run do
          @proxy=EventMachine::start_server(@config['host'], @config['port'],
                                            EventMachine::ProxyServer::Connection, :debug => debug) do |conn|
            server.em_run=true
            server.run conn
          end
        end
      end
      sleep 2
      puts "#{self} server start on port #{@config['port']}"


    end

    #用于在EM.run中，这样可以启动多个server，将来可以考虑与start方法合并
    #can't work in jruby
    def start_in_em(debug=false)
      server=self
      Thread.new do
        p 'new'
        @proxy=EventMachine::start_server(@config['host'], @config['port'],
                                          EventMachine::ProxyServer::Connection, :debug => debug) do |conn|
          server.run conn
          server.em_run=true
        end
        p 'start'
      end
    end

    #停止服务运行
    def stop
      puts "Terminating ProxyServer"
      @thread.exit if @thread
      #jruby's bug stop_server would be stop em.run
      EventMachine.stop_server @proxy
      #EventMachine.stop_event_loop
      sleep 1
    end

    #保持服务运行
    def keep
      p @thread
      @thread.join
    end
  end
end


