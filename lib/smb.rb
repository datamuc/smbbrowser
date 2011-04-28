require 'time'
require 'sinatra'
require 'sinatra/flash'
require './lib/jcifs'
require 'uri'

enable :sessions
set :session_secret, 'XXhTTXqmjydf39duXE7rLJTXxNaYFK'
set :views, File.dirname(__FILE__) + '/../views'
set :public, File.dirname(__FILE__) + '/../public'

get '/' do
    @session = session
    haml :index
end

get '/get' do
    file = params[:file]
    redirect to('/get/' + URI.escape(file, /[^A-Za-z0-9\/]/))
end

get '/get/*' do
    file = params[:splat][0]
    session[:file] = file

    begin
        if session[:pass] and !session[:pass].empty?
            @smbfile = CIFS::File.get(file, session[:domain], session[:user], session[:pass])
        else
            @smbfile = CIFS::File.get(file)
        end

        if ! @smbfile.exists
            raise "File does not exist"
        end

        if @smbfile.isDirectory
            @dir = CIFS::DirReader.new(@smbfile)
            return haml :directory
        end

        if @smbfile.isFile
            fr = CIFS::FileReader.new(@smbfile)
            headers \
                'Last-Modified' => Time.at(@smbfile.getLastModified / 1000).httpdate,
                'Content-Length' => @smbfile.length.to_s,
                'Content-Type' => fr.mime_type.to_s,
                'Content-Disposition' => 'filename="%s"' % @smbfile.getName
            return fr
        end
    rescue CIFS::SmbAuthException => e
        flash[:error] = e.message
        flash[:message] = "please supply valid credentials"
        return redirect to('/')
    rescue Exception => e
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
