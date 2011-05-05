# The sinatra webapp
#
# Author::    Danijel Tasov (mailto:dt@korn.shell.la)
# Copyright:: Copyright (c) 2011 Danijel Tasov
# License::   Beerware
#

require 'jcifs'
require 'time'
require 'sinatra'
require 'sinatra/flash'
require 'haml'
require 'uri'
require 'configr'
require 'java'

#use Rack::Chunked
enable :sessions

configure do
    set :session_secret, 'XXhTTXqmjydf39duXE7rLJTXxNaYFK'
    set :views, File.dirname(__FILE__) + '/../views'
    set :public, File.dirname(__FILE__) + '/../public'

    configfile = Java::JavaLang::System.getProperty("smbbrowser.configfile")
    if configfile and File.readable?(configfile)
        set :config, Configr::Configuration.configure(configfile)
    else
        set :config, Configr::Configuration.configure {}
    end
end

get '/' do
    @session = session
    @config = settings.config
    haml :index
end

get '/get' do
    file = params[:file]
    begin
        if session[:pass] and !session[:pass].empty?
            @smbfile = CIFS::File.get(file, session[:domain], session[:user], session[:pass])
        else
            @smbfile = CIFS::File.get(file)
        end
    rescue java.net.MalformedURLException => e
        case file
        when %r(^\\\\)
            file.tr!('\\', '/')
            file = "smb:" + file
            retry
        when %r(^//)
            file = "smb:" + file
            retry
        end
        flash[:error] = e.message
        return redirect to('/')
    end
    redirect to('/get/' + CIFS.escape_uri(file))
end

get '/get/*' do
    file = params[:splat][0]
    begin
        if session[:pass] and !session[:pass].empty?
            @smbfile = CIFS::File.get(file, session[:domain], session[:user], session[:pass])
        else
            @smbfile = CIFS::File.get(file)
        end

        session[:file] = file

        if ! @smbfile.exists
            raise "File does not exist"
        end

        if @smbfile.isDirectory
            @dir = CIFS::DirReader.new(@smbfile)
            return haml :directory
        end

        if @smbfile.isFile and not request.env['HTTP_RANGE']
            fr = CIFS::FileReader.new(@smbfile)
            return fr.response
        end

        if @smbfile.isFile and request.env['HTTP_RANGE']
            fr = CIFS::RangeFileReader.new(@smbfile, request.env['HTTP_RANGE'])
            return fr.response
        end

        raise "W00t!??//11"
    rescue CIFS::SmbAuthException => e
        flash[:error] = e.message
        flash[:message] = "please supply valid credentials"
        return redirect to('/')
    rescue CIFS::RangeNotSatisfiableException => e
        return [ 416, { 'Content-Type' => 'text/plain' }, e.message ]
    rescue Exception => e
        if e.message.end_with?("must end with '/'") and ! file.end_with?('/')
            file += '/'
            retry
        end
        puts(e.message)
        puts(e.backtrace)
        flash[:error] = e.message
        return redirect to('/')
    end

end

post '/credentials/set' do
    [:user, :pass, :domain].each do |i|
        session[i] = params[i]
    end
    redirect to('/')
end

post '/credentials/remove' do
    [:user, :pass, :domain].each { |i| session.delete(i) }
    redirect to('/')
end
